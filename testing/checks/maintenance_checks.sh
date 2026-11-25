#!/usr/bin/env bash
# GO-EUC appliance maintenance checks, run from a client machine (see testing/README.md):
# Telegraf refresh, Run Full Appliance Update, then a reboot with the on-box checks re-run.
#
#   testing/checks/maintenance_checks.sh <appliance-ip> [expected-hostname]
#
# Reads goeucadmin.password and id_goeuc_test from $GOEUC_TEST_DIR (default ~/.goeuc-test).
# The full update upgrades Ubuntu packages and can take a long time.

set -u
IP="${1:?usage: $0 <appliance-ip> [expected-hostname]}"
HOST_NAME="${2:-}"
DIR="${GOEUC_TEST_DIR:-$HOME/.goeuc-test}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="https://${IP}"
pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
info() { echo "INFO  $*"; }

AUTH_CFG="$(mktemp)"; BODY="$(mktemp)"
trap 'rm -f "${AUTH_CFG}" "${BODY}"' EXIT
( umask 077; printf 'user = "goeucadmin:%s"\n' "$(tr -d '\r\n' < "${DIR}/goeucadmin.password")" > "${AUTH_CFG}" )
SSH=(ssh -i "${DIR}/id_goeuc_test" -o UserKnownHostsFile="${DIR}/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 "goeucadmin@${IP}")
post() { curl -sk -K "${AUTH_CFG}" -o "${BODY}" -w '%{http_code}' --max-time "$2" -X POST "${BASE}$1"; }

echo "===== Fetch latest Telegraf package"
c="$(post /api/refresh-telegraf 600)"
[[ "$c" == 200 ]] && ok "refresh-telegraf -> 200 ($(grep -m1 -o 'telegraf-[0-9.]*_windows_amd64.zip' "${BODY}"))" || { bad "refresh-telegraf -> ${c}"; tail -5 "${BODY}"; }

echo "===== Run Full Appliance Update"
before="$("${SSH[@]}" "docker inspect -f '{{.Created}}' telegraf-nutanix 2>/dev/null")"
start=$(date +%s)
c="$(post /api/full-update 7300)"
info "full update took $(( $(date +%s) - start ))s"
[[ "$c" == 200 ]] && ok "full-update -> 200" || { bad "full-update -> ${c}"; tail -15 "${BODY}"; }
grep -q "Legacy compose detected" "${BODY}" && bad "full update re-ran the installer migration (compose detection)" || ok "full update did not re-run the installer"
grep -q "Updating enabled infrastructure collectors" "${BODY}" && ok "full update refreshed collectors" || bad "full update did not refresh collectors"
grep -q "/config.txt readable without login from" "${BODY}" && ok "full update refreshed the config.txt subnet list" || bad "local access list not refreshed"
grep -q "Re-publishing Telegraf configs" "${BODY}" && ok "full update re-published Telegraf configs" || bad "Telegraf configs not re-published"
after="$("${SSH[@]}" "docker inspect -f '{{.Created}}' telegraf-nutanix 2>/dev/null")"
[[ -z "${before}" || "${before}" != "${after}" ]] && ok "telegraf-nutanix recreated by the update" || bad "telegraf-nutanix not recreated"

echo "===== Reboot"
"${SSH[@]}" "sudo systemctl reboot" >/dev/null 2>&1
sleep 20
for _ in $(seq 1 60); do "${SSH[@]}" true >/dev/null 2>&1 && break; sleep 10; done
"${SSH[@]}" true >/dev/null 2>&1 && ok "appliance back after reboot" || { bad "appliance not reachable after reboot"; echo "===== result: ${pass} passed, ${fail} failed"; exit 1; }
info "waiting 90s for containers to settle"; sleep 90
c="$("${SSH[@]}" "systemctl show -p ActiveState --value go-euc-firstboot.service")"
info "go-euc-firstboot.service after reboot: ${c} (condition skip expected: marker present)"
"${SSH[@]}" "docker inspect -f '{{.State.Status}}' telegraf-nutanix" 2>/dev/null | grep -q running && ok "telegraf-nutanix running after reboot" || bad "telegraf-nutanix not running after reboot"
echo "----- on-box checks after reboot"
"${SSH[@]}" "sudo EXPECTED_IP=${IP} EXPECTED_HOST=${HOST_NAME} bash -s" < "${HERE}/remote_checks.sh" | tee /dev/stderr | grep -q '^FAIL' && bad "on-box checks after reboot have failures (see above)" || ok "on-box checks after reboot all pass"

echo "===== result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
