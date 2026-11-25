#!/usr/bin/env bash

# Manages the optional infrastructure metric collectors: Telegraf containers that run on the
# appliance and write to the Performance bucket.
#
#   go-euc-collector.sh <type> apply [--no-wait]   (re)create the container from saved settings
#   go-euc-collector.sh <type> disable             stop/remove the container, keep settings
#   go-euc-collector.sh <type> status              settings (no password), state and recent log
#   go-euc-collector.sh <type> is-enabled          exit 0 when the collector is enabled
#   go-euc-collector.sh all apply-enabled          refresh every enabled collector (used by upgrades)
#
# Types:
#   vsphere   VMware vCenter (inputs.vsphere)                       container: telegraf-vsphere
#   nutanix   Nutanix Prism Element (cluster address, not Prism Central),
#             v2.0 hosts API (inputs.http/json_v2)                   container: telegraf-nutanix
#   proxmox   Proxmox VE API (inputs.proxmox + inputs.http/json_v2) container: telegraf-proxmox
#             COLLECTOR_USERNAME = API token ID (user@realm!tokenname),
#             COLLECTOR_PASSWORD = API token secret. Nodes are discovered at apply time and
#             the config is rendered with one section per node.
#
# Settings are saved by the appliance web page (POST /api/collectors/<type>/configure) in
# /etc/go-euc/collector-<type>.env: COLLECTOR_URL, COLLECTOR_USERNAME, COLLECTOR_PASSWORD,
# COLLECTOR_INSECURE_SKIP_VERIFY, COLLECTOR_ENABLED.

set -euo pipefail

COLLECTOR_TYPES=(vsphere nutanix proxmox)
CREDENTIALS_FILE="/opt/influx-grafana/credentials.env"
CONFIG_DIR="/opt/go-euc-installer/collectors"
# Configs rendered at apply time (no secrets; mounted read-only into the container).
RENDERED_DIR="/opt/influx-grafana/collectors"
NETWORK_NAME="monitoring_net"
# Pinned Telegraf image for all collectors (minor-version tag, receives patch releases).
TELEGRAF_IMAGE="telegraf:1.40"
# Long enough for discovery plus the first collection to log any connection/auth errors.
STARTUP_WAIT_SECONDS="${COLLECTOR_STARTUP_WAIT_SECONDS:-45}"

log() {
  echo "[collector:${COLLECTOR_TYPE:-all}] $*"
}

select_type() {
  local requested="$1"
  local known=""
  for known in "${COLLECTOR_TYPES[@]}"; do
    if [[ "${requested}" == "${known}" ]]; then
      COLLECTOR_TYPE="${requested}"
      SETTINGS_FILE="/etc/go-euc/collector-${COLLECTOR_TYPE}.env"
      RUNTIME_ENV_FILE="/etc/go-euc/telegraf-${COLLECTOR_TYPE}.env"
      TELEGRAF_CONFIG="${CONFIG_DIR}/telegraf-${COLLECTOR_TYPE}.conf"
      CONTAINER_NAME="telegraf-${COLLECTOR_TYPE}"
      return 0
    fi
  done
  echo "Unknown collector type '${requested}'. Known: ${COLLECTOR_TYPES[*]}" >&2
  exit 64
}

load_settings() {
  if [[ ! -f "${SETTINGS_FILE}" ]]; then
    log "Not configured: ${SETTINGS_FILE} does not exist. Configure the collector from the appliance web page." >&2
    exit 1
  fi
  COLLECTOR_URL=""
  COLLECTOR_USERNAME=""
  COLLECTOR_PASSWORD=""
  COLLECTOR_INSECURE_SKIP_VERIFY="true"
  # shellcheck source=/dev/null
  source "${SETTINGS_FILE}"
  local missing=""
  [[ -n "${COLLECTOR_URL}" ]] || missing+=" COLLECTOR_URL"
  [[ -n "${COLLECTOR_USERNAME}" ]] || missing+=" COLLECTOR_USERNAME"
  [[ -n "${COLLECTOR_PASSWORD}" ]] || missing+=" COLLECTOR_PASSWORD"
  if [[ -n "${missing}" ]]; then
    log "Missing settings in ${SETTINGS_FILE}:${missing}" >&2
    exit 1
  fi
  if [[ "${COLLECTOR_INSECURE_SKIP_VERIFY}" != "false" ]]; then
    COLLECTOR_INSECURE_SKIP_VERIFY="true"
  fi
}

set_enabled() {
  local value="$1"
  [[ -f "${SETTINGS_FILE}" ]] || return 0
  if grep -q '^COLLECTOR_ENABLED=' "${SETTINGS_FILE}"; then
    sed -i "s/^COLLECTOR_ENABLED=.*/COLLECTOR_ENABLED=${value}/" "${SETTINGS_FILE}"
  else
    printf 'COLLECTOR_ENABLED=%s\n' "${value}" >> "${SETTINGS_FILE}"
  fi
  chmod 600 "${SETTINGS_FILE}"
}

# Write the docker --env-file read by the container. docker reads env-file values literally
# (no quoting or $ expansion), and Telegraf (strict environment handling, the default since
# 1.38) inserts them verbatim into the quoted strings that reference them. So values are
# written raw: escaping them would put literal backslashes into passwords. Booleans are not
# substituted by Telegraf outside quotes; render_config writes those into the config instead.
write_runtime_env() {
  local influx_org=""
  local influx_token=""

  if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
    log "Credentials file not found: ${CREDENTIALS_FILE}" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${CREDENTIALS_FILE}"
  influx_org="${SAVED_INFLUX_ADMIN_ORG:?SAVED_INFLUX_ADMIN_ORG missing from ${CREDENTIALS_FILE}}"
  influx_token="${SAVED_TELEGRAF_WRITE_TOKEN:-}"
  if [[ -z "${influx_token}" ]]; then
    log "WARN: no Telegraf write-only token found; using the InfluxDB admin token." >&2
    influx_token="${SAVED_INFLUX_ADMIN_TOKEN:?SAVED_INFLUX_ADMIN_TOKEN missing from ${CREDENTIALS_FILE}}"
  fi

  GOEUC_URL="${COLLECTOR_URL}" \
  GOEUC_USERNAME="${COLLECTOR_USERNAME}" \
  GOEUC_PASSWORD="${COLLECTOR_PASSWORD}" \
  GOEUC_INFLUX_ORG="${influx_org}" \
  GOEUC_INFLUX_TOKEN="${influx_token}" \
  python3 - "${RUNTIME_ENV_FILE}" <<'PY'
import os
import sys

env = os.environ
values = {
    "COLLECTOR_URL": env["GOEUC_URL"],
    "COLLECTOR_USERNAME": env["GOEUC_USERNAME"],
    "COLLECTOR_PASSWORD": env["GOEUC_PASSWORD"],
    "INFLUX_ORG": env["GOEUC_INFLUX_ORG"],
    "INFLUX_TOKEN": env["GOEUC_INFLUX_TOKEN"],
}
for key, value in values.items():
    # docker env-files are line-based: a newline or other control character cannot be represented.
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        sys.exit(f"{key} contains a control character; it cannot be passed to the collector.")
lines = [f"{key}={value}" for key, value in values.items()]
path = sys.argv[1]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
os.chmod(path, 0o600)
PY
}

# Proxmox: list the cluster's nodes through the API (also validates address, token and TLS).
discover_proxmox_nodes() {
  GOEUC_URL="${COLLECTOR_URL}" \
  GOEUC_TOKEN_ID="${COLLECTOR_USERNAME}" \
  GOEUC_TOKEN_SECRET="${COLLECTOR_PASSWORD}" \
  GOEUC_INSECURE="${COLLECTOR_INSECURE_SKIP_VERIFY}" \
  python3 - <<'PY'
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request

url = os.environ["GOEUC_URL"] + "/api2/json/nodes"
context = ssl.create_default_context()
if os.environ["GOEUC_INSECURE"] != "false":
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
request = urllib.request.Request(url, headers={
    "Authorization": f"PVEAPIToken={os.environ['GOEUC_TOKEN_ID']}={os.environ['GOEUC_TOKEN_SECRET']}",
})
try:
    with urllib.request.urlopen(request, context=context, timeout=20) as response:
        payload = json.load(response)
except urllib.error.HTTPError as exc:
    print(f"Proxmox API returned HTTP {exc.code} ({exc.reason}) for {url}. "
          "Check the API token ID and secret, and that the token has the PVEAuditor role on /.", file=sys.stderr)
    sys.exit(1)
except Exception as exc:  # connection, TLS or JSON errors
    print(f"Cannot query the Proxmox API at {url}: {exc}", file=sys.stderr)
    sys.exit(1)

nodes = sorted({str(item.get("node", "")) for item in payload.get("data", [])})
nodes = [n for n in nodes if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,62}", n)]
if not nodes:
    print("The Proxmox API returned no nodes visible to this token (needs PVEAuditor on /).", file=sys.stderr)
    sys.exit(1)
print("\n".join(nodes))
PY
}

# Pre-flight: prove the target is reachable (and, where possible, that the credentials work)
# before starting the container. Telegraf plugins only connect on their first collection and
# can wait out a long timeout, so without this an unreachable vCenter would look healthy.
#   vsphere: GET /sdk/vimServiceVersions.xml (unauthenticated): address + TLS
#   nutanix: GET /api/nutanix/v2.0/cluster with the credentials: address + TLS + login
#   proxmox: node discovery (render_config) does the same with the API token
preflight_check() {
  [[ "${COLLECTOR_TYPE}" == "proxmox" ]] && return 0
  log "Checking ${COLLECTOR_URL}..."
  if ! GOEUC_TYPE="${COLLECTOR_TYPE}" \
      GOEUC_URL="${COLLECTOR_URL}" \
      GOEUC_USERNAME="${COLLECTOR_USERNAME}" \
      GOEUC_PASSWORD="${COLLECTOR_PASSWORD}" \
      GOEUC_INSECURE="${COLLECTOR_INSECURE_SKIP_VERIFY}" \
      python3 - <<'PY'
import base64
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

kind = os.environ["GOEUC_TYPE"]
base = os.environ["GOEUC_URL"]
context = ssl.create_default_context()
if os.environ["GOEUC_INSECURE"] != "false":
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
if kind == "vsphere":
    parts = urllib.parse.urlsplit(base)
    url = f"{parts.scheme}://{parts.netloc}/sdk/vimServiceVersions.xml"
    headers = {}
else:
    url = base + "/api/nutanix/v2.0/cluster"
    token = base64.b64encode(f"{os.environ['GOEUC_USERNAME']}:{os.environ['GOEUC_PASSWORD']}".encode()).decode()
    headers = {"Authorization": "Basic " + token, "Accept": "application/json"}
try:
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), context=context, timeout=15) as resp:
        resp.read(4096)
except urllib.error.HTTPError as exc:
    if exc.code in (401, 403):
        print(f"{url}: HTTP {exc.code} - the username or password was rejected.", file=sys.stderr)
    else:
        print(f"{url}: HTTP {exc.code} {exc.reason} - is this the right address?", file=sys.stderr)
    sys.exit(1)
except ssl.SSLError as exc:
    print(f"{url}: TLS error ({exc.reason}). Untick 'Verify ... TLS certificate' for self-signed certificates.", file=sys.stderr)
    sys.exit(1)
except Exception as exc:  # DNS, connection refused, timeout
    reason = getattr(exc, "reason", exc)
    print(f"Cannot reach {url}: {reason}", file=sys.stderr)
    sys.exit(1)
print("reachable")
PY
  then
    log "ERROR: pre-flight check failed (see message above); collector not started." >&2
    exit 1
  fi
}

# Render the collector's config into RENDERED_DIR: fill in @@INSECURE_SKIP_VERIFY@@ (a boolean,
# which Telegraf will not substitute from the environment) and, for Proxmox, repeat the per-node
# section for every discovered node. The result holds no secrets.
render_config() {
  local nodes=""
  local rendered="${RENDERED_DIR}/telegraf-${COLLECTOR_TYPE}.conf"
  local part="${CONFIG_DIR}/telegraf-${COLLECTOR_TYPE}-node.conf.part"

  if [[ "${COLLECTOR_TYPE}" == "proxmox" ]]; then
    log "Discovering Proxmox nodes..."
    if ! nodes="$(discover_proxmox_nodes)"; then
      log "ERROR: node discovery failed (see message above)." >&2
      exit 1
    fi
    log "Nodes: $(tr '\n' ' ' <<<"${nodes}")"
  fi

  mkdir -p "${RENDERED_DIR}"
  GOEUC_NODES="${nodes}" GOEUC_INSECURE="${COLLECTOR_INSECURE_SKIP_VERIFY}" \
    python3 - "${TELEGRAF_CONFIG}" "${part}" "${rendered}.tmp" <<'PY'
import os
import sys

base_path, part_path, out_path = sys.argv[1:4]
text = open(base_path, encoding="utf-8").read()
marker = "# @@PER_NODE_INPUTS@@"
if marker in text:
    nodes = [n for n in os.environ["GOEUC_NODES"].split("\n") if n]
    part = open(part_path, encoding="utf-8").read()
    if text.count(marker) != 1 or not nodes:
        sys.exit(f"{base_path}: expected one '{marker}' line and at least one node")
    text = text.replace(marker, "".join(part.replace("@@NODE@@", node) for node in nodes))
text = text.replace("@@INSECURE_SKIP_VERIFY@@", "false" if os.environ["GOEUC_INSECURE"] == "false" else "true")
if "@@" in text:
    sys.exit(f"{base_path}: unrendered placeholder left in config")
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY
  chmod 644 "${rendered}.tmp"
  mv -f "${rendered}.tmp" "${rendered}"
  TELEGRAF_CONFIG="${rendered}"
}

remove_container() {
  docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
}

cmd_apply() {
  local wait_for_startup="true"
  local started_at=""
  local running=""
  local logs=""

  if [[ "${1:-}" == "--no-wait" ]]; then
    wait_for_startup="false"
  fi

  load_settings
  if [[ ! -f "${TELEGRAF_CONFIG}" ]]; then
    log "Telegraf config not found: ${TELEGRAF_CONFIG}" >&2
    exit 1
  fi
  preflight_check
  write_runtime_env
  render_config

  log "Pulling ${TELEGRAF_IMAGE}..."
  if ! docker pull "${TELEGRAF_IMAGE}" >/dev/null; then
    log "WARN: pull failed; using a local copy of ${TELEGRAF_IMAGE} if present."
  fi

  log "Starting ${CONTAINER_NAME} for ${COLLECTOR_URL} (insecure_skip_verify=${COLLECTOR_INSECURE_SKIP_VERIFY})..."
  remove_container
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --label "go-euc.collector=${COLLECTOR_TYPE}" \
    --restart unless-stopped \
    --network "${NETWORK_NAME}" \
    --env-file "${RUNTIME_ENV_FILE}" \
    -v "${TELEGRAF_CONFIG}:/etc/telegraf/telegraf.conf:ro" \
    "${TELEGRAF_IMAGE}" >/dev/null
  set_enabled true

  if [[ "${wait_for_startup}" != "true" ]]; then
    log "Started."
    return 0
  fi

  log "Waiting ${STARTUP_WAIT_SECONDS}s for the first collection..."
  sleep "${STARTUP_WAIT_SECONDS}"
  running="$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null || echo false)"
  logs="$(docker logs --since "${started_at}" "${CONTAINER_NAME}" 2>&1 | tail -n 40 || true)"

  echo "----- ${CONTAINER_NAME} log -----"
  echo "${logs}"
  echo "---------------------------------"

  if [[ "${running}" != "true" ]]; then
    log "ERROR: the collector container is not running (see log above)." >&2
    exit 1
  fi
  if grep -q ' E! ' <<<"${logs}"; then
    log "ERROR: the collector is running but reported errors. Check the address, credentials and TLS setting." >&2
    exit 2
  fi
  log "Collector is running with no errors so far. Metrics are written to the Performance bucket."
}

cmd_disable() {
  remove_container
  set_enabled false
  log "Collector stopped and removed (settings kept in ${SETTINGS_FILE})."
}

cmd_status() {
  local state=""
  if [[ -f "${SETTINGS_FILE}" ]]; then
    COLLECTOR_URL=""
    COLLECTOR_USERNAME=""
    COLLECTOR_INSECURE_SKIP_VERIFY="true"
    COLLECTOR_ENABLED="false"
    # shellcheck source=/dev/null
    source "${SETTINGS_FILE}"
    echo "Address:    ${COLLECTOR_URL:-<not set>}"
    echo "Username:   ${COLLECTOR_USERNAME:-<not set>}"
    echo "Verify TLS: $([[ "${COLLECTOR_INSECURE_SKIP_VERIFY}" == "false" ]] && echo yes || echo no)"
    echo "Enabled:    ${COLLECTOR_ENABLED}"
  else
    echo "Not configured."
  fi
  state="$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo not-created)"
  echo "Container:  ${CONTAINER_NAME} (${state})"
  if [[ "${state}" != "not-created" ]]; then
    echo "----- last 25 log lines -----"
    docker logs --tail 25 "${CONTAINER_NAME}" 2>&1 || true
  fi
}

cmd_is_enabled() {
  [[ -f "${SETTINGS_FILE}" ]] || return 1
  grep -q '^COLLECTOR_ENABLED=true$' "${SETTINGS_FILE}"
}

cmd_apply_enabled() {
  local collector_type=""
  local failures=0
  for collector_type in "${COLLECTOR_TYPES[@]}"; do
    # Separate process per collector: one failing collector must not stop the others.
    if "${BASH_SOURCE[0]}" "${collector_type}" is-enabled; then
      "${BASH_SOURCE[0]}" "${collector_type}" apply --no-wait \
        || { echo "[collector:${collector_type}] WARN: refresh failed."; failures=$((failures + 1)); }
    fi
  done
  [[ "${failures}" -eq 0 ]]
}

usage() {
  echo "Usage: $0 {$(IFS='|'; echo "${COLLECTOR_TYPES[*]}")} {apply [--no-wait]|disable|status|is-enabled}" >&2
  echo "       $0 all apply-enabled" >&2
  exit 64
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

[[ $# -ge 2 ]] || usage

if [[ "$1" == "all" ]]; then
  [[ "$2" == "apply-enabled" ]] || usage
  cmd_apply_enabled
  exit $?
fi

select_type "$1"
case "$2" in
  apply) shift 2; cmd_apply "$@" ;;
  disable) cmd_disable ;;
  status) cmd_status ;;
  is-enabled) cmd_is_enabled ;;
  *) usage ;;
esac
