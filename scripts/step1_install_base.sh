#!/usr/bin/env bash

# Re-exec under bash if launched via sh/dash.
if [ -z "${BASH_VERSION:-}" ]; then
  SCRIPT_PATH="$0"
  case "${SCRIPT_PATH}" in
    /*) ;;
    *) SCRIPT_PATH="$(pwd)/${SCRIPT_PATH}" ;;
  esac
  exec /usr/bin/env bash "${SCRIPT_PATH}" "$@"
fi

set -euo pipefail

# Installer:
# - Install Docker Engine + Compose plugin on Ubuntu
# - Install and run Portainer CE
# - Create a shared Docker network for the monitoring stack
# - Create a docker-compose stack with InfluxDB + Grafana
# - Bootstrap Influx and Grafana configuration/provisioning

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (or with sudo)." >&2
  exit 1
fi

echo "==> Starting installer"

if [[ ! -f /etc/os-release ]]; then
  echo "Cannot detect OS. /etc/os-release is missing." >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
  echo "This script currently supports Ubuntu only. Detected: ${ID}" >&2
  exit 1
fi

INSTALL_ROOT="/opt/influx-grafana"
STACK_DIR="${INSTALL_ROOT}/stack"
NETWORK_NAME="monitoring_net"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
NGINX_CONF_DIR="${INSTALL_ROOT}/nginx/conf.d"
NGINX_CERT_DIR="${INSTALL_ROOT}/nginx/certs"
NGINX_ACME_WEBROOT="${INSTALL_ROOT}/nginx/acme"
NGINX_AUTH_DIR="${INSTALL_ROOT}/nginx/auth"
# Unix socket directory shared by the API backend (go-euc-webfiles.py) and the nginx container.
API_SOCKET_DIR="${INSTALL_ROOT}/run"
DASHBOARD_URL_CONFIG_FILE="/etc/go-euc/dashboard-url"
DEFAULT_DASHBOARDS_ZIP_URL="https://goeucartifacts4hiu9i.blob.core.windows.net/files/Dashboards.zip"

# Pinned container images (bump deliberately; Grafana/Portainer cannot be downgraded safely).
INFLUXDB_IMAGE="influxdb:2.7"
GRAFANA_IMAGE="grafana/grafana:13.3"
PORTAINER_IMAGE="portainer/portainer-ce:2.45.4"
GOEUCWEB_IMAGE="goeuc/webserver:2004.01"
NGINX_IMAGE="nginx:1.27-alpine"

# Load previously generated credentials/settings so reruns are stable.
if [[ -f "${CREDENTIALS_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CREDENTIALS_FILE}"
fi

# Generate alphanumeric secrets from a cryptographically secure source.
generate_secret() {
  local length="${1:-20}"
  python3 -c 'import secrets, string, sys
alphabet = string.ascii_letters + string.digits
sys.stdout.write("".join(secrets.choice(alphabet) for _ in range(int(sys.argv[1]))))' "${length}"
}

PORTAINER_ADMIN_USER="${PORTAINER_ADMIN_USER:-${SAVED_PORTAINER_ADMIN_USER:-admin}}"
PORTAINER_ADMIN_PASSWORD="${PORTAINER_ADMIN_PASSWORD:-${SAVED_PORTAINER_ADMIN_PASSWORD:-$(generate_secret 20)}}"
INFLUX_ADMIN_USER="${INFLUX_ADMIN_USER:-${SAVED_INFLUX_ADMIN_USER:-influxadmin}}"
INFLUX_ADMIN_PASSWORD="${INFLUX_ADMIN_PASSWORD:-${SAVED_INFLUX_ADMIN_PASSWORD:-$(generate_secret 20)}}"
INFLUX_ADMIN_ORG="${INFLUX_ADMIN_ORG:-${SAVED_INFLUX_ADMIN_ORG:-monitoring}}"
INFLUX_INIT_BUCKET="${INFLUX_INIT_BUCKET:-${SAVED_INFLUX_INIT_BUCKET:-bootstrap}}"
INFLUX_ADMIN_TOKEN="${INFLUX_ADMIN_TOKEN:-${SAVED_INFLUX_ADMIN_TOKEN:-$(generate_secret 40)}}"
INFLUX_BUCKET_PERFORMANCE="${INFLUX_BUCKET_PERFORMANCE:-Performance}"
INFLUX_BUCKET_TESTS="${INFLUX_BUCKET_TESTS:-Tests}"
INFLUX_BUCKET_PROXMOX="${INFLUX_BUCKET_PROXMOX:-Proxmox}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-${SAVED_GRAFANA_ADMIN_USER:-admin}}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-${SAVED_GRAFANA_ADMIN_PASSWORD:-$(generate_secret 20)}}"
# Write-only token handed to Telegraf clients (created after InfluxDB is up).
TELEGRAF_WRITE_TOKEN="${SAVED_TELEGRAF_WRITE_TOKEN:-}"
# Write-only token for Proxmox VE's built-in Metric Server (pushes to the Proxmox bucket).
PROXMOX_WRITE_TOKEN="${SAVED_PROXMOX_WRITE_TOKEN:-}"
# Dashboard bundle URL: explicit env override > appliance config > default artifact location.
if [[ -z "${DASHBOARDS_ZIP_URL:-}" && -s "${DASHBOARD_URL_CONFIG_FILE}" ]]; then
  DASHBOARDS_ZIP_URL="$(tr -d '\r\n' < "${DASHBOARD_URL_CONFIG_FILE}")"
fi
DASHBOARDS_ZIP_URL="${DASHBOARDS_ZIP_URL:-${DEFAULT_DASHBOARDS_ZIP_URL}}"
GRAFANA_DATASOURCE_NAME="DS_GO"
GRAFANA_DATASOURCE_UID="DS_GO"
# Web server ports (go-euc-set-ports: standard 80/443, alternative 8080/4443).
config_port() { sed -n "s/^$1=//p" /etc/go-euc/config.env 2>/dev/null | tail -1; }
NGINX_HTTP_PORT="${APPLIANCE_HTTP_PORT:-$(config_port APPLIANCE_HTTP_PORT)}"; NGINX_HTTP_PORT="${NGINX_HTTP_PORT:-80}"
NGINX_HTTPS_PORT="${APPLIANCE_HTTPS_PORT:-$(config_port APPLIANCE_HTTPS_PORT)}"; NGINX_HTTPS_PORT="${NGINX_HTTPS_PORT:-443}"
# Grafana's own URL for the links it generates: the Let's Encrypt domain once a certificate is
# active (go-euc-grafana-url.sh), otherwise Grafana's default.
GRAFANA_ROOT_URL='%(protocol)s://%(domain)s/grafana/'
if [[ -x /usr/local/bin/go-euc-grafana-url.sh ]]; then
  GRAFANA_ROOT_URL="$(/usr/local/bin/go-euc-grafana-url.sh --print 2>/dev/null || echo "${GRAFANA_ROOT_URL}")"
fi

# Persist resolved values for idempotent reruns and easier troubleshooting.
# Values are shell-quoted with %q so any characters survive being sourced.
write_credentials_file() {
  mkdir -p "${INSTALL_ROOT}"
  (
    umask 077
    {
      printf 'SAVED_PORTAINER_ADMIN_USER=%q\n' "${PORTAINER_ADMIN_USER}"
      printf 'SAVED_PORTAINER_ADMIN_PASSWORD=%q\n' "${PORTAINER_ADMIN_PASSWORD}"
      printf 'SAVED_INFLUX_ADMIN_USER=%q\n' "${INFLUX_ADMIN_USER}"
      printf 'SAVED_INFLUX_ADMIN_PASSWORD=%q\n' "${INFLUX_ADMIN_PASSWORD}"
      printf 'SAVED_INFLUX_ADMIN_ORG=%q\n' "${INFLUX_ADMIN_ORG}"
      printf 'SAVED_INFLUX_INIT_BUCKET=%q\n' "${INFLUX_INIT_BUCKET}"
      printf 'SAVED_INFLUX_ADMIN_TOKEN=%q\n' "${INFLUX_ADMIN_TOKEN}"
      printf 'SAVED_TELEGRAF_WRITE_TOKEN=%q\n' "${TELEGRAF_WRITE_TOKEN}"
      printf 'SAVED_PROXMOX_WRITE_TOKEN=%q\n' "${PROXMOX_WRITE_TOKEN}"
      printf 'SAVED_GRAFANA_ADMIN_USER=%q\n' "${GRAFANA_ADMIN_USER}"
      printf 'SAVED_GRAFANA_ADMIN_PASSWORD=%q\n' "${GRAFANA_ADMIN_PASSWORD}"
    } > "${CREDENTIALS_FILE}"
  )
  chmod 600 "${CREDENTIALS_FILE}"
}
write_credentials_file

PORTAINER_CREDS_STATUS="configured"
PORTAINER_PASSWORD_DISPLAY="${PORTAINER_ADMIN_PASSWORD}"
INFLUX_STATUS="unknown"
GRAFANA_STATUS="unknown"
DASHBOARD_IMPORT_STATUS="not-configured"
DASHBOARD_JSON_COUNT="0"
GRAFANA_DATASOURCE_STATUS="unknown"
GOEUCWEB_STATUS="not-started"
TELEGRAF_TOKEN_STATUS="not-created"
PROXMOX_TOKEN_STATUS="not-created"

# Wait until InfluxDB's API answers (influx ping checks /health inside the container).
wait_for_influx() {
  local retries="${1:-90}"
  local sleep_seconds="${2:-2}"
  local _i
  for _i in $(seq 1 "${retries}"); do
    if docker exec influxdb influx ping >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done
  return 1
}

# Poll an HTTP endpoint until an expected status code is returned.
wait_for_http() {
  local url="$1"
  local expected="$2"
  local retries="${3:-60}"
  local sleep_seconds="${4:-2}"
  local code=""
  local _i

  for _i in $(seq 1 "${retries}"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${url}" || true)"
    if [[ "${code}" == "${expected}" ]]; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done
  return 1
}

ensure_influx_bucket() {
  local bucket_name="$1"
  # If bucket already exists, do nothing.
  if docker exec influxdb influx bucket find \
    --name "${bucket_name}" \
    --org "${INFLUX_ADMIN_ORG}" \
    --token "${INFLUX_ADMIN_TOKEN}" >/dev/null 2>&1; then
    return 0
  fi

  docker exec influxdb influx bucket create \
    --name "${bucket_name}" \
    --org "${INFLUX_ADMIN_ORG}" \
    --token "${INFLUX_ADMIN_TOKEN}" >/dev/null
}

# ensure_bucket_write_token <bucket> <description> <existing-token>
# Ensures a write-only token scoped to <bucket> exists, so the all-access admin token never
# has to be distributed. Reuses <existing-token> while it is still active. Sets ENSURED_TOKEN
# (empty on failure) and ENSURED_STATUS (exists|created|bucket-lookup-failed|create-failed).
ensure_bucket_write_token() {
  local bucket_name="$1"
  local description="$2"
  local existing_token="$3"
  local auth_json=""
  local bucket_id=""
  local new_token=""

  ENSURED_TOKEN=""
  if [[ -n "${existing_token}" ]]; then
    auth_json="$(docker exec influxdb influx auth list --org "${INFLUX_ADMIN_ORG}" --token "${INFLUX_ADMIN_TOKEN}" --json 2>/dev/null || true)"
    if printf '%s' "${auth_json}" | python3 -c 'import json, sys
token = sys.argv[1]
auths = json.load(sys.stdin)
sys.exit(0 if any(a.get("token") == token and a.get("status", "active") == "active" for a in auths) else 1)' "${existing_token}" 2>/dev/null; then
      ENSURED_TOKEN="${existing_token}"
      ENSURED_STATUS="exists"
      return 0
    fi
  fi

  bucket_id="$(
    docker exec influxdb influx bucket list \
      --name "${bucket_name}" \
      --org "${INFLUX_ADMIN_ORG}" \
      --token "${INFLUX_ADMIN_TOKEN}" \
      --json 2>/dev/null \
      | python3 -c 'import json, sys
buckets = json.load(sys.stdin)
print(buckets[0]["id"] if buckets else "")' 2>/dev/null || true
  )"
  if [[ -z "${bucket_id}" ]]; then
    ENSURED_STATUS="bucket-lookup-failed"
    return 1
  fi

  new_token="$(
    docker exec influxdb influx auth create \
      --org "${INFLUX_ADMIN_ORG}" \
      --token "${INFLUX_ADMIN_TOKEN}" \
      --write-bucket "${bucket_id}" \
      --description "${description}" \
      --json 2>/dev/null \
      | python3 -c 'import json, sys
auth = json.load(sys.stdin)
if isinstance(auth, list):
    auth = auth[0] if auth else {}
print(auth.get("token", ""))' 2>/dev/null || true
  )"
  if [[ -z "${new_token}" ]]; then
    ENSURED_STATUS="create-failed"
    return 1
  fi

  ENSURED_TOKEN="${new_token}"
  ENSURED_STATUS="created"
}

# Telegraf clients and the appliance collectors write to the Performance bucket.
ensure_telegraf_write_token() {
  ensure_bucket_write_token "${INFLUX_BUCKET_PERFORMANCE}" \
    "GO-EUC Telegraf write-only (${INFLUX_BUCKET_PERFORMANCE})" "${TELEGRAF_WRITE_TOKEN}" || true
  TELEGRAF_TOKEN_STATUS="${ENSURED_STATUS}"
  if [[ -n "${ENSURED_TOKEN}" && "${ENSURED_TOKEN}" != "${TELEGRAF_WRITE_TOKEN}" ]]; then
    TELEGRAF_WRITE_TOKEN="${ENSURED_TOKEN}"
    write_credentials_file
  fi
}

# Proxmox VE's built-in Metric Server pushes to its own bucket: its measurement names
# (system, cpustat, memory, ...) would otherwise collide with the Windows Telegraf data.
ensure_proxmox_push_token() {
  ensure_bucket_write_token "${INFLUX_BUCKET_PROXMOX}" \
    "GO-EUC Proxmox Metric Server write-only (${INFLUX_BUCKET_PROXMOX})" "${PROXMOX_WRITE_TOKEN}" || true
  PROXMOX_TOKEN_STATUS="${ENSURED_STATUS}"
  if [[ -n "${ENSURED_TOKEN}" && "${ENSURED_TOKEN}" != "${PROXMOX_WRITE_TOKEN}" ]]; then
    PROXMOX_WRITE_TOKEN="${ENSURED_TOKEN}"
    write_credentials_file
  fi
}

# Download dashboard ZIP, extract it, and normalize known datasource placeholders.
download_dashboards_zip() {
  local url="$1"
  local tmp_zip=""
  shopt -s globstar nullglob

  tmp_zip="$(mktemp /tmp/grafana-dashboards-XXXXXX.zip)"
  # Fetch dashboard artifact from the configured URL.
  if ! curl -fsSL "${url}" -o "${tmp_zip}"; then
    rm -f "${tmp_zip}"
    DASHBOARD_IMPORT_STATUS="download-failed"
    shopt -u globstar nullglob
    return 1
  fi

  # Replace previously extracted dashboards with the latest bundle contents.
  # macOS metadata (__MACOSX/, ._*) is skipped so Grafana only sees real dashboards.
  rm -rf "${STACK_DIR}/grafana/dashboards/"*
  if ! unzip -oq "${tmp_zip}" -d "${STACK_DIR}/grafana/dashboards" -x '__MACOSX/*' '._*' '*/._*'; then
    rm -f "${tmp_zip}"
    DASHBOARD_IMPORT_STATUS="extract-failed"
    shopt -u globstar nullglob
    return 1
  fi
  rm -f "${tmp_zip}"
  # Grafana (uid 472) must be able to read every file, whatever permissions the zip recorded.
  chmod -R a+rX "${STACK_DIR}/grafana/dashboards"

  local dashboard_files=("${STACK_DIR}"/grafana/dashboards/**/*.json)
  DASHBOARD_JSON_COUNT="${#dashboard_files[@]}"
  if [[ "${DASHBOARD_JSON_COUNT}" -gt 0 ]]; then
    for dashboard in "${dashboard_files[@]}"; do
      # Resolve common exported Grafana datasource placeholders.
      sed -i \
        -e 's/"\${DS_GO}"/"DS_GO"/g' \
        -e 's/"{DS_GO}"/"DS_GO"/g' \
        -e 's/\${DS_GO}/DS_GO/g' \
        -e 's/{DS_GO}/DS_GO/g' \
        "${dashboard}" || true
    done
    # Wrap bare Grafana v2 dashboard specs so file provisioning accepts them (appliance tool).
    if [[ -x /usr/local/bin/go-euc-grafana-dashboards.py ]]; then
      /usr/local/bin/go-euc-grafana-dashboards.py "${STACK_DIR}/grafana/dashboards" || true
    fi
    DASHBOARD_IMPORT_STATUS="import-ready"
  else
    DASHBOARD_IMPORT_STATUS="no-json-found"
  fi
  shopt -u globstar nullglob
  return 0
}

# Ensure Grafana has the expected datasource, with API fallback if file provisioning misses it.
ensure_grafana_datasource_via_api() {
  local get_code=""
  local post_code=""
  local payload_file=""
  local datasource_name_encoded=""

  datasource_name_encoded="${GRAFANA_DATASOURCE_NAME// /%20}"
  # Check whether datasource already exists in Grafana.
  get_code="$(
    curl -s -o /tmp/grafana-datasource-check.json -w '%{http_code}' \
      -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      "http://localhost:3000/api/datasources/name/${datasource_name_encoded}" || true
  )"

  if [[ "${get_code}" == "200" ]]; then
    GRAFANA_DATASOURCE_STATUS="exists"
    return 0
  fi

  # Build datasource payload that matches the provisioned Influx settings.
  payload_file="$(mktemp /tmp/grafana-datasource-payload-XXXXXX.json)"
  cat > "${payload_file}" <<JSON
{
  "name": "${GRAFANA_DATASOURCE_NAME}",
  "uid": "${GRAFANA_DATASOURCE_UID}",
  "type": "influxdb",
  "url": "http://influxdb:8086",
  "access": "proxy",
  "isDefault": true,
  "jsonData": {
    "version": "Flux",
    "organization": "${INFLUX_ADMIN_ORG}",
    "defaultBucket": "${INFLUX_INIT_BUCKET}"
  },
  "secureJsonData": {
    "token": "${INFLUX_ADMIN_TOKEN}"
  }
}
JSON

  post_code="$(
    curl -s -o /tmp/grafana-datasource-create.json -w '%{http_code}' \
      -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      -H "Content-Type: application/json" \
      -X POST "http://localhost:3000/api/datasources" \
      --data-binary "@${payload_file}" || true
  )"

  rm -f "${payload_file}"

  # Treat 409 as success-like because datasource already exists.
  case "${post_code}" in
    200)
      GRAFANA_DATASOURCE_STATUS="created-via-api"
      ;;
    409)
      GRAFANA_DATASOURCE_STATUS="already-exists"
      ;;
    *)
      GRAFANA_DATASOURCE_STATUS="api-create-failed"
      ;;
  esac
}

# --- Base package and Docker installation ---
echo "==> Installing Docker prerequisites"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https unzip

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

echo "==> Installing Docker Engine and Compose plugin"
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker

# --- Networking and Portainer setup ---
echo "==> Creating shared Docker network (${NETWORK_NAME})"
if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  docker network create "${NETWORK_NAME}" >/dev/null
fi

echo "==> Installing Portainer CE"
docker volume create portainer_data >/dev/null
if ! docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
  docker run -d \
    --name portainer \
    --restart=always \
    --network "${NETWORK_NAME}" \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    "${PORTAINER_IMAGE}" \
    --base-url /portainer >/dev/null
fi

if ! docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s " $k}}{{end}}' portainer 2>/dev/null | grep -q "${NETWORK_NAME}"; then
  echo "==> Recreating Portainer to attach ${NETWORK_NAME}"
  docker rm -f portainer >/dev/null 2>&1 || true
  docker run -d \
    --name portainer \
    --restart=always \
    --network "${NETWORK_NAME}" \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    "${PORTAINER_IMAGE}" \
    --base-url /portainer >/dev/null
fi

# Wait for Portainer API before attempting admin user initialization.
echo "==> Initializing Portainer admin credentials"
PORTAINER_READY=0
for _ in $(seq 1 60); do
  if curl -sk --max-time 2 "https://localhost:9443/api/status" >/dev/null || curl -sk --max-time 2 "https://localhost:9443/portainer/api/status" >/dev/null; then
    PORTAINER_READY=1
    break
  fi
  sleep 2
done

# Portainer >= 2.45 only allows the first admin to be created with the one-time setup token it
# prints in its log ("setup_token=..."), and locks itself if no admin exists ~5 minutes after start.
portainer_setup_token() {
  docker logs portainer 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'setup_token=[A-Za-z0-9._-]+' | tail -1 | cut -d= -f2
}

portainer_admin_exists() {
  # 204 = an admin user exists, 404 = not yet.
  [[ "$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:9443/api/users/admin/check")" == "204" ]]
}

portainer_init_admin() {
  local token="" body_file="" code="000" _i
  body_file="$(mktemp)"
  chmod 600 "${body_file}"
  python3 -c 'import json, sys; print(json.dumps({"Username": sys.argv[1], "Password": sys.argv[2]}))' \
    "${PORTAINER_ADMIN_USER}" "${PORTAINER_ADMIN_PASSWORD}" > "${body_file}"
  for _i in $(seq 1 15); do
    token="$(portainer_setup_token)"
    code="$(
      curl -sk -o /tmp/portainer-init.json -w '%{http_code}' \
        -H "Content-Type: application/json" \
        ${token:+-H "X-Setup-Token: ${token}"} \
        -X POST "https://localhost:9443/api/users/admin/init" \
        --data-binary "@${body_file}"
    )"
    [[ "${code}" == "200" || "${code}" == "409" ]] && break
    sleep 4
  done
  rm -f "${body_file}" /tmp/portainer-init.json
  printf '%s' "${code}"
}

if [[ "${PORTAINER_READY}" -eq 1 ]]; then
  if portainer_admin_exists; then
    PORTAINER_INIT_CODE="409"
  else
    PORTAINER_INIT_CODE="$(portainer_init_admin)"
    if [[ "${PORTAINER_INIT_CODE}" != "200" ]] && ! portainer_admin_exists; then
      # Possibly locked by its 5-minute security timeout: a restart re-opens the setup window
      # (and prints a new setup token).
      echo "==> Portainer admin init returned ${PORTAINER_INIT_CODE}; restarting Portainer and retrying"
      docker restart portainer >/dev/null 2>&1 || true
      sleep 10
      PORTAINER_INIT_CODE="$(portainer_init_admin)"
    fi
  fi

  case "${PORTAINER_INIT_CODE}" in
    200)
      PORTAINER_CREDS_STATUS="configured"
      ;;
    409|422)
      PORTAINER_CREDS_STATUS="already-initialized"
      PORTAINER_PASSWORD_DISPLAY="<already-set>"
      ;;
    *)
      PORTAINER_CREDS_STATUS="init-failed"
      PORTAINER_PASSWORD_DISPLAY="<unknown>"
      ;;
  esac
else
  PORTAINER_CREDS_STATUS="portainer-unreachable"
  PORTAINER_PASSWORD_DISPLAY="<unknown>"
fi

# --- Generate stack files and provisioning definitions ---
echo "==> Creating stack layout under ${INSTALL_ROOT}"
mkdir -p "${STACK_DIR}"/{grafana,influxdb}
mkdir -p "${STACK_DIR}/grafana/data" "${STACK_DIR}/influxdb/data" "${STACK_DIR}/influxdb/config"
mkdir -p "${STACK_DIR}/grafana/provisioning/datasources"
mkdir -p "${STACK_DIR}/grafana/provisioning/dashboards" "${STACK_DIR}/grafana/dashboards"
mkdir -p "${NGINX_CONF_DIR}" "${NGINX_CERT_DIR}" "${NGINX_ACME_WEBROOT}" "${NGINX_AUTH_DIR}" "${API_SOCKET_DIR}"
chown -R 472:472 "${STACK_DIR}/grafana/data" || true

# Grafana datasource provisioning file (InfluxDB/Flux).
cat > "${STACK_DIR}/grafana/provisioning/datasources/influxdb.yml" <<YAML
apiVersion: 1
prune: true

datasources:
  - name: "${GRAFANA_DATASOURCE_NAME}"
    uid: "${GRAFANA_DATASOURCE_UID}"
    type: influxdb
    access: proxy
    url: "http://influxdb:8086"
    isDefault: true
    editable: true
    jsonData:
      version: Flux
      organization: "${INFLUX_ADMIN_ORG}"
      defaultBucket: "${INFLUX_INIT_BUCKET}"
    secureJsonData:
      token: "${INFLUX_ADMIN_TOKEN}"
YAML

# Grafana dashboard provider config to load JSON files from mounted path.
cat > "${STACK_DIR}/grafana/provisioning/dashboards/dashboards.yml" <<'YAML'
apiVersion: 1

providers:
  - name: default
    orgId: 1
    folder: Imported
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
YAML

# Dashboard bundle ingestion (optional if URL is blank).
if [[ -n "${DASHBOARDS_ZIP_URL}" ]]; then
  echo "==> Downloading dashboards from ZIP URL"
  download_dashboards_zip "${DASHBOARDS_ZIP_URL}" || true
else
  DASHBOARD_IMPORT_STATUS="not-configured"
fi

# Docker Compose definition for InfluxDB and Grafana services.
# InfluxDB is not published on the host: nginx serves it over TLS on :8086 (UI + API) and under
# /influx/ (API). Grafana is bound to localhost; remote access goes through nginx HTTPS.
cat > "${STACK_DIR}/docker-compose.yml" <<YAML
services:
  influxdb:
    image: ${INFLUXDB_IMAGE}
    container_name: influxdb
    restart: unless-stopped
    volumes:
      - ./influxdb/data:/var/lib/influxdb2
      - ./influxdb/config:/etc/influxdb2
    environment:
      DOCKER_INFLUXDB_INIT_MODE: "setup"
      DOCKER_INFLUXDB_INIT_USERNAME: "${INFLUX_ADMIN_USER}"
      DOCKER_INFLUXDB_INIT_PASSWORD: "${INFLUX_ADMIN_PASSWORD}"
      DOCKER_INFLUXDB_INIT_ORG: "${INFLUX_ADMIN_ORG}"
      DOCKER_INFLUXDB_INIT_BUCKET: "${INFLUX_INIT_BUCKET}"
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: "${INFLUX_ADMIN_TOKEN}"
    networks:
      - monitoring_net

  grafana:
    image: ${GRAFANA_IMAGE}
    container_name: grafana
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - ./grafana/data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    environment:
      GF_SECURITY_ADMIN_USER: "${GRAFANA_ADMIN_USER}"
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD}"
      GF_SERVER_ROOT_URL: "${GRAFANA_ROOT_URL}"
      GF_SERVER_SERVE_FROM_SUB_PATH: "true"
    networks:
      - monitoring_net
    depends_on:
      - influxdb

  goeucweb:
    image: ${GOEUCWEB_IMAGE}
    container_name: goeucweb
    restart: unless-stopped
    networks:
      - monitoring_net

  nginx:
    image: ${NGINX_IMAGE}
    container_name: goeuc-nginx
    restart: unless-stopped
    ports:
      - "${NGINX_HTTP_PORT}:80"
      - "${NGINX_HTTPS_PORT}:443"
      - "8086:8086"
    volumes:
      - ${INSTALL_ROOT}/public:/usr/share/nginx/html:ro
      - ${NGINX_CONF_DIR}/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ${NGINX_CERT_DIR}:/etc/nginx/certs:ro
      - ${NGINX_ACME_WEBROOT}:/var/www/acme:rw
      - ${NGINX_AUTH_DIR}:/etc/nginx/auth:ro
      - ${API_SOCKET_DIR}:/run/go-euc
    networks:
      - monitoring_net
    depends_on:
      - influxdb
      - grafana

networks:
  monitoring_net:
    external: true
    name: monitoring_net
YAML

# --- Start services and apply readiness checks ---
echo "==> Starting core stack (influxdb + grafana + nginx)"
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d influxdb grafana nginx
# Restart Grafana once to ensure provisioning mounts are fully applied.
docker compose -f "${STACK_DIR}/docker-compose.yml" restart grafana >/dev/null 2>&1 || true

echo "==> Starting GO-EUC web container (best effort)"
for _ in 1 2 3; do
  if docker compose -f "${STACK_DIR}/docker-compose.yml" up -d goeucweb; then
    GOEUCWEB_STATUS="ready"
    break
  fi
  GOEUCWEB_STATUS="pull-or-start-failed"
  sleep 5
done

echo "==> Waiting for InfluxDB and Grafana readiness"
if wait_for_influx 90 2; then
  INFLUX_STATUS="ready"
  # Ensure required business buckets exist every run.
  echo "==> Ensuring required Influx buckets exist"
  ensure_influx_bucket "${INFLUX_BUCKET_PERFORMANCE}"
  ensure_influx_bucket "${INFLUX_BUCKET_TESTS}"
  ensure_influx_bucket "${INFLUX_BUCKET_PROXMOX}"
  echo "==> Ensuring write-only tokens exist (Telegraf, Proxmox Metric Server)"
  ensure_telegraf_write_token
  ensure_proxmox_push_token
else
  INFLUX_STATUS="not-ready"
fi

if wait_for_http "http://localhost:3000/api/health" "200" 90 2; then
  GRAFANA_STATUS="ready"
  # Double-check datasource through API in case provisioning order/race issues occur.
  echo "==> Verifying Grafana datasource (${GRAFANA_DATASOURCE_NAME})"
  ensure_grafana_datasource_via_api || true
else
  GRAFANA_STATUS="not-ready"
  GRAFANA_DATASOURCE_STATUS="grafana-not-ready"
fi

# --- Final summary and operator-facing output ---
echo
echo "Install complete."
echo "- Web UI (HTTPS): https://<vm-ip>/"
echo "- Grafana: https://<vm-ip>/grafana/"
echo "- InfluxDB: https://<vm-ip>:8086/ (API also at https://<vm-ip>/influx)"
echo "- Portainer: https://<vm-ip>/portainer/"
echo "- GO-EUC Web: https://<vm-ip>/goeucweb/"
echo "  - status:   ${GOEUCWEB_STATUS}"
echo "- Portainer direct: https://<vm-ip>:9443 (InfluxDB/Grafana direct ports are localhost-only)"
echo "  - username: ${PORTAINER_ADMIN_USER}"
echo "  - password: ${PORTAINER_PASSWORD_DISPLAY}"
echo "  - status:   ${PORTAINER_CREDS_STATUS}"
echo "- InfluxDB: https://<vm-ip>:8086/ (API also at https://<vm-ip>/influx)"
echo "  - username: ${INFLUX_ADMIN_USER}"
echo "  - password: ${INFLUX_ADMIN_PASSWORD}"
echo "  - org:      ${INFLUX_ADMIN_ORG}"
echo "  - buckets:  ${INFLUX_BUCKET_PERFORMANCE}, ${INFLUX_BUCKET_TESTS}, ${INFLUX_BUCKET_PROXMOX}"
echo "  - admin token: stored in ${CREDENTIALS_FILE}"
echo "  - telegraf write token: ${TELEGRAF_TOKEN_STATUS}"
echo "  - proxmox metric server token: ${PROXMOX_TOKEN_STATUS}"
echo "  - status:   ${INFLUX_STATUS}"
echo "- Grafana: https://<vm-ip>/grafana/"
echo "  - username: ${GRAFANA_ADMIN_USER}"
echo "  - password: ${GRAFANA_ADMIN_PASSWORD}"
echo "  - dashboard ZIP URL: ${DASHBOARDS_ZIP_URL:-<not-set>}"
echo "  - dashboards JSON count: ${DASHBOARD_JSON_COUNT}"
echo "  - dashboard import status: ${DASHBOARD_IMPORT_STATUS}"
echo "  - datasource status: ${GRAFANA_DATASOURCE_STATUS}"
echo "  - status:   ${GRAFANA_STATUS}"
echo
if [[ "${GRAFANA_STATUS}" != "ready" ]]; then
  echo "Grafana did not become ready in time. Check:"
  echo "- docker ps"
  echo "- docker logs grafana"
  echo "- sudo ss -ltnp | grep ':3000'"
fi
echo
echo "Credentials file: ${CREDENTIALS_FILE}"
