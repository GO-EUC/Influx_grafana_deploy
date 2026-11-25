#!/usr/bin/env bash
# GO-EUC appliance checks through its public host name (router forward or reverse proxy, see
# docs/external-access.md), run from a client machine:
#
#   testing/checks/public_checks.sh <public-host-name> <appliance-ip>
#
# Checks the public certificate, the logins, every proxied service, that /config.txt and
# :8086 aren't reachable, that a 20 MB write isn't refused for its size, and that a point
# written through the public name lands in this appliance's InfluxDB (proving the name
# reaches this appliance). Reads goeucadmin.password and id_goeuc_test from $GOEUC_TEST_DIR
# (default ~/.goeuc-test). Tokens are fetched over SSH into a temporary file, never printed.
# If the router has no NAT loopback, run this from outside the network.

set -u
HOST="${1:?usage: $0 <public-host-name> <appliance-ip>}"
IP="${2:?usage: $0 <public-host-name> <appliance-ip>}"
DIR="${GOEUC_TEST_DIR:-$HOME/.goeuc-test}"
WEB="https://${HOST}"
pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
info() { echo "INFO  $*"; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
( umask 077; printf 'user = "goeucadmin:%s"\n' "$(tr -d '\r\n' < "${DIR}/goeucadmin.password")" > "${TMP}/auth" )
SSH=(ssh -i "${DIR}/id_goeuc_test" -o UserKnownHostsFile="${DIR}/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 "goeucadmin@${IP}")

code() { curl -s -o "${TMP}/body" -w '%{http_code}' --max-time 20 "$@"; }
expect() {  # expect <description> <wanted-regex> <curl args...>
  local desc="$1" want="$2" got; shift 2
  got="$(code "$@")"
  [[ "${got}" =~ ^(${want})$ ]] && ok "${desc} -> ${got}" || bad "${desc} -> ${got} (expected ${want})"
}

echo "===== Name and certificate"
info "${HOST} resolves to $(dig +short "${HOST}" @1.1.1.1 | tail -1)"
v="$(curl -s -o /dev/null -w '%{ssl_verify_result}' --max-time 15 "${WEB}/")"
[[ "${v}" == 0 ]] && ok "certificate verifies for ${HOST}" || bad "certificate does not verify (ssl_verify_result=${v})"
issuer="$(echo | openssl s_client -connect "${HOST}:443" -servername "${HOST}" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
info "certificate ${issuer:-unknown issuer}"
loc="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 "http://${HOST}/grafana/")"
[[ "${loc}" == "https://${HOST}/grafana/" ]] && ok "HTTP redirects to HTTPS (${loc})" || bad "HTTP redirect -> '${loc}'"

echo "===== Logins and services"
expect "landing page asks for login" 401 "${WEB}/"
expect "landing page with login" 200 -K "${TMP}/auth" "${WEB}/"
grep -q "GO-EUC Appliance" "${TMP}/body" && ok "landing page content" || bad "landing page content missing"
expect "/telegraf/ asks for login" 401 "${WEB}/telegraf/"
expect "/telegraf/ with login" 200 -K "${TMP}/auth" "${WEB}/telegraf/"
expect "/api/ asks for login" 401 "${WEB}/api/ports"
expect "/api/ports with login" 200 -K "${TMP}/auth" "${WEB}/api/ports"
expect "Grafana" "200|302" "${WEB}/grafana/"
expect "Grafana login page" 200 "${WEB}/grafana/login"
expect "InfluxDB API /influx/health" 200 "${WEB}/influx/health"
expect "Portainer" 200 "${WEB}/portainer/"
expect "Portainer API status" 200 "${WEB}/portainer/api/status"
expect "GO-EUC Web" 200 "${WEB}/goeucweb/"
expect "/config.txt refused from outside the subnet" 403 "${WEB}/config.txt"
expect "/api/v2 write without token" 401 -X POST "${WEB}/api/v2/write?org=x&bucket=y"
grep -q '"code":"unauthorized"' "${TMP}/body" && ok "/api/v2 answered by InfluxDB" || bad "/api/v2 not answered by InfluxDB"
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "https://${HOST}:8086/health")"
[[ "${c}" == 000 ]] && ok ":8086 not reachable through the public name" || info ":8086 answered ${c} through the public name"

echo "===== Upload size (20 MB write without a token: 401 = passed through, 413 = proxy limit)"
head -c 20000000 /dev/zero | tr '\0' 'a' > "${TMP}/big"
expect "20 MB body to /influx/api/v2/write" 401 -X POST --data-binary @"${TMP}/big" "${WEB}/influx/api/v2/write?org=x&bucket=y"

echo "===== WebSocket upgrade (Portainer consoles)"
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${WEB}/portainer/api/websocket/exec?id=x&endpointId=1")"
[[ "${c}" =~ ^(101|400|401|403)$ ]] && ok "WebSocket request reaches Portainer (${c}, not a proxy error)" || bad "WebSocket request -> ${c}"

echo "===== A write through the public name lands in this appliance"
"${SSH[@]}" "sudo bash -c '. /opt/influx-grafana/credentials.env; printf \"%s\n%s\n%s\n\" \"\$SAVED_INFLUX_ADMIN_ORG\" \"\$SAVED_TELEGRAF_WRITE_TOKEN\" \"\$SAVED_INFLUX_ADMIN_TOKEN\"'" > "${TMP}/tok" 2>/dev/null
ORG="$(sed -n 1p "${TMP}/tok")"
( umask 077; printf 'header = "Authorization: Token %s"\n' "$(sed -n 2p "${TMP}/tok")" > "${TMP}/wcfg" )
marker="public_$(date +%s)"
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -K "${TMP}/wcfg" -X POST \
  "${WEB}/influx/api/v2/write?org=${ORG}&bucket=Performance&precision=s" --data-binary "goeuc_selftest,check=${marker} value=1i")"
[[ "${c}" == 204 ]] && ok "write via ${WEB}/influx with the Telegraf token -> 204" || bad "write via ${WEB}/influx -> ${c} (401 = the name reaches another appliance)"
c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -K "${TMP}/wcfg" -X POST \
  "${WEB}/api/v2/write?org=${ORG}&bucket=Performance&precision=s" --data-binary "goeuc_selftest,check=${marker}_root value=1i")"
[[ "${c}" == 204 ]] && ok "write via ${WEB}/api/v2 -> 204" || bad "write via ${WEB}/api/v2 -> ${c}"
sleep 2
n="$("${SSH[@]}" "sudo bash -c '. /opt/influx-grafana/credentials.env; docker exec influxdb influx query --org \"\$SAVED_INFLUX_ADMIN_ORG\" --token \"\$SAVED_INFLUX_ADMIN_TOKEN\" --raw \"from(bucket:\\\"Performance\\\") |> range(start:-10m) |> filter(fn:(r)=> r._measurement==\\\"goeuc_selftest\\\" and r.check=~/^${marker}/)\" | grep -c ${marker}'" 2>/dev/null)"
[[ "${n:-0}" -ge 2 ]] && ok "both points found in ${IP}'s InfluxDB" || bad "points not found in ${IP}'s InfluxDB (${n:-0})"

echo
echo "public checks: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
