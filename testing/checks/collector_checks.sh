#!/usr/bin/env bash
# GO-EUC appliance infrastructure collector checks, run from a client machine (see testing/README.md).
#
#   testing/checks/collector_checks.sh <appliance-ip>
#
# Uses the appliance API (as the landing page does) plus SSH for InfluxDB queries.
# Reads from $GOEUC_TEST_DIR (default ~/.goeuc-test):
#   goeucadmin.password, id_goeuc_test (SSH key), nutanix.env:
#     NUTANIX_COLLECTOR_ADDRESS (optional; defaults to PRISM_HOST) - Prism Element address
#     PRISM_VIEWER_USER / PRISM_VIEWER_PASSWORD                    - account for the collector
# Unreachable TEST-NET addresses (192.0.2.x) are used for the negative vSphere/Proxmox tests.

set -u
IP="${1:?usage: $0 <appliance-ip>}"
DIR="${GOEUC_TEST_DIR:-$HOME/.goeuc-test}"
BASE="https://${IP}"
pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
info() { echo "INFO  $*"; }

AUTH_CFG="$(mktemp)"; BODY="$(mktemp)"; REQ="$(mktemp)"
trap 'rm -f "${AUTH_CFG}" "${BODY}" "${REQ}"' EXIT
chmod 600 "${REQ}"
( umask 077; printf 'user = "goeucadmin:%s"\n' "$(tr -d '\r\n' < "${DIR}/goeucadmin.password")" > "${AUTH_CFG}" )
SSH=(ssh -i "${DIR}/id_goeuc_test" -o UserKnownHostsFile="${DIR}/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "goeucadmin@${IP}")

api() { curl -sk -K "${AUTH_CFG}" -o "${BODY}" -w '%{http_code}' --max-time 700 "$@"; }
field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], ""))' "${BODY}" "$1" 2>/dev/null; }
show_output() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join("      | " + l for l in (d.get("output") or d.get("message") or "").splitlines()[-int(sys.argv[2]):]))' "${BODY}" "${1:-8}" 2>/dev/null; }

# configure <type> <json-file>
configure() { api -X POST -H 'Content-Type: application/json' --data-binary "@$2" "${BASE}/api/collectors/$1/configure"; }

# Flux query on the appliance with the admin token; prints CSV.
flux() {
  "${SSH[@]}" "sudo bash -c 'source /opt/influx-grafana/credentials.env; docker exec influxdb influx query --org \"\${SAVED_INFLUX_ADMIN_ORG}\" --token \"\${SAVED_INFLUX_ADMIN_TOKEN}\" --raw \"\$(cat)\"'" <<<"$1"
}

echo "===== Nutanix Prism Element collector (real target)"
python3 - "${DIR}/nutanix.env" "${REQ}" <<'PY'
import json, shlex, sys
env = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = shlex.split(line, comments=True)
    if parts and "=" in parts[0]:
        k, v = parts[0].split("=", 1)
        env[k] = v
json.dump({
    "address": env.get("NUTANIX_COLLECTOR_ADDRESS") or env["PRISM_HOST"],
    "username": env["PRISM_VIEWER_USER"],
    "password": env["PRISM_VIEWER_PASSWORD"],
    "verify_tls": False,
}, open(sys.argv[2], "w"))
PY
c="$(configure nutanix "${REQ}")"
[[ "$c" == 200 && "$(field ok)" == "True" ]] && ok "Nutanix collector started: $(field message)" || { bad "Nutanix configure -> ${c}: $(field message)"; show_output 15; }
api "${BASE}/api/collectors/nutanix/status" >/dev/null
[[ "$(field container_status)" == running ]] && ok "telegraf-nutanix running ($(field address))" || bad "telegraf-nutanix status: $(field container_status)"
info "waiting 30s for more Nutanix samples"; sleep 30
csv="$(flux 'from(bucket:"Performance") |> range(start:-3m) |> filter(fn:(r) => r._measurement == "nutanix_host") |> group(columns:["host","_field"]) |> last() |> keep(columns:["host","_field","_value"])')"
hosts="$(grep -E ',cpu_usage_pct,' <<<"${csv}" | awk -F, '{print $NF}' | sort -u | wc -l | tr -d ' ')"
for f in cpu_usage_pct memory_usage_pct hypervisor_iops controller_io_latency_us storage_capacity_bytes storage_usage_pct network_receive_Bps vm_count; do
  line="$(grep -E ",${f}," <<<"${csv}" | head -1)"
  [[ -n "${line}" ]] && ok "nutanix_host.${f} = $(cut -d, -f4- <<<"${line}" | cut -c1-60)" || bad "nutanix_host.${f} missing"
done
types="$(flux 'import "types"
from(bucket:"Performance") |> range(start:-3m) |> filter(fn:(r) => r._measurement == "nutanix_host" and r._field == "cpu_usage_ppm") |> last() |> map(fn:(r) => ({r with t: if types.isType(v: r._value, type: "float") then "float" else "other"})) |> keep(columns:["t"])')"
grep -q float <<<"${types}" && ok "nutanix_host.cpu_usage_ppm stored as float (string conversion works)" || bad "nutanix_host.cpu_usage_ppm type: ${types//$'\n'/ }"
info "nutanix hosts reporting: ${hosts}"

echo "===== vSphere collector (unreachable vCenter -> clean failure)"
echo '{"address":"192.0.2.10","username":"test@vsphere.local","password":"not-a-real-password","verify_tls":false}' > "${REQ}"
c="$(configure vsphere "${REQ}")"
[[ "$c" == 500 && "$(field ok)" == "False" ]] && ok "vSphere failure reported: $(field message)" || bad "vSphere configure -> ${c}: $(field message)"
show_output 4
api -X POST "${BASE}/api/collectors/vsphere/disable" >/dev/null
[[ "$(field ok)" == "True" ]] && ok "vSphere collector stopped" || bad "vSphere disable: $(field message)"
api "${BASE}/api/collectors/vsphere/status" >/dev/null
[[ "$(field container_status)" == not-created && "$(field enabled)" == False ]] && ok "vSphere container removed, settings kept (configured=$(field configured))" || bad "vSphere status after stop: $(field container_status) enabled=$(field enabled)"

echo "===== Proxmox VE collector (unreachable API -> clean failure, no container)"
echo '{"address":"192.0.2.11","username":"telegraf@pve!monitoring","password":"8f2c1e2a-1111-2222-3333-444455556666","verify_tls":false}' > "${REQ}"
c="$(configure proxmox "${REQ}")"
[[ "$c" == 500 && "$(field ok)" == "False" ]] && ok "Proxmox failure reported: $(field message)" || bad "Proxmox configure -> ${c}: $(field message)"
show_output 3
api "${BASE}/api/collectors/proxmox/status" >/dev/null
[[ "$(field container_status)" == not-created ]] && ok "no telegraf-proxmox container after failed discovery" || bad "telegraf-proxmox status: $(field container_status)"
# Clean up: the deliberately broken Proxmox settings stay "enabled" (saved intent) until stopped,
# and updates would keep retrying them.
api -X POST "${BASE}/api/collectors/proxmox/disable" >/dev/null
[[ "$(field ok)" == "True" ]] && ok "Proxmox test collector stopped (cleanup)" || bad "Proxmox disable: $(field message)"

echo "===== password keep-on-blank"
python3 - "${DIR}/nutanix.env" "${REQ}" <<'PY'
import json, shlex, sys
env = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = shlex.split(line, comments=True)
    if parts and "=" in parts[0]:
        k, v = parts[0].split("=", 1)
        env[k] = v
json.dump({"address": env.get("NUTANIX_COLLECTOR_ADDRESS") or env["PRISM_HOST"],
           "username": env["PRISM_VIEWER_USER"], "password": "", "verify_tls": False}, open(sys.argv[2], "w"))
PY
c="$(configure nutanix "${REQ}")"
[[ "$c" == 200 && "$(field ok)" == "True" ]] && ok "Nutanix re-saved with blank password (saved password kept)" || bad "Nutanix re-save -> ${c}: $(field message)"

echo "===== result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
