#!/usr/bin/env bash
# GO-EUC appliance web-port checks, run from a client machine (see testing/README.md):
# switch nginx to the alternative ports (8080/4443) through the landing page API, check every
# route and the files that carry the address, then switch back to standard (80/443) over SSH
# with go-euc-set-ports and check again. Leaves the appliance on the standard ports.
#
#   testing/checks/ports_checks.sh <appliance-ip>
#
# Reads goeucadmin.password and id_goeuc_test from $GOEUC_TEST_DIR (default ~/.goeuc-test).

set -u
IP="${1:?usage: $0 <appliance-ip>}"
DIR="${GOEUC_TEST_DIR:-$HOME/.goeuc-test}"
pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }

AUTH_CFG="$(mktemp)"; BODY="$(mktemp)"
trap 'rm -f "${AUTH_CFG}" "${BODY}"' EXIT
( umask 077; printf 'user = "goeucadmin:%s"\n' "$(tr -d '\r\n' < "${DIR}/goeucadmin.password")" > "${AUTH_CFG}" )
SSH=(ssh -i "${DIR}/id_goeuc_test" -o UserKnownHostsFile="${DIR}/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 "goeucadmin@${IP}")

code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$@"; }
expect() {  # expect <description> <wanted-regex> <curl args...>
  local desc="$1" want="$2" got; shift 2
  got="$(code "$@")"
  [[ "${got}" =~ ^(${want})$ ]] && ok "${desc} -> ${got}" || bad "${desc} -> ${got} (expected ${want})"
}
wait_for() {  # wait_for <url>: until nginx answers there (max 60 s)
  for _ in $(seq 1 30); do
    [[ "$(code "$1")" =~ ^(200|301|302|401)$ ]] && return 0
    sleep 2
  done
  return 1
}

check_ports() {  # check_ports <http> <https>
  local http="$1" https="$2" web suffix=""
  [[ "${https}" != 443 ]] && suffix=":${https}"
  web="https://${IP}${suffix}"
  wait_for "${web}/" && ok "nginx answers on ${https}" || { bad "nginx not answering on ${https}"; return; }
  expect "landing page asks for login on ${https}" 401 "${web}/"
  expect "landing page with login on ${https}" 200 -K "${AUTH_CFG}" "${web}/"
  expect "Grafana on ${https}" "200|302" "${web}/grafana/"
  expect "InfluxDB API /influx on ${https}" 200 "${web}/influx/health"
  expect "/api/v2 root on ${https} without token" 401 -X POST "${web}/api/v2/write?org=x&bucket=y"
  expect "Portainer on ${https}" 200 "${web}/portainer/"
  expect "InfluxDB :8086 unchanged" 200 "https://${IP}:8086/health"
  local loc
  loc="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 8 "http://${IP}:${http}/grafana/")"
  [[ "${loc}" == "https://${IP}${suffix}/grafana/" ]] && ok "HTTP ${http} redirects to ${loc}" || bad "HTTP ${http} redirects to '${loc}', expected https://${IP}${suffix}/grafana/"
  [[ "$(curl -sk -K "${AUTH_CFG}" --max-time 8 "${web}/api/ports")" == *"\"https\": ${https}"* ]] && ok "/api/ports reports ${https}" || bad "/api/ports does not report ${https}"
  local remote
  remote="$("${SSH[@]}" "sudo grep -c 'https://${IP}${suffix}/influx' /opt/influx-grafana/public/telegraf/telegraf.conf; \
    sudo grep -c '^HTTPSPort=${https}\$' /opt/influx-grafana/public/config.txt 2>/dev/null; \
    sudo grep -c '^APPLIANCE_HTTPS_PORT=${https}\$' /etc/go-euc/config.env; \
    sudo grep -c '\"${http}:80\"' /opt/influx-grafana/stack/docker-compose.yml; \
    sudo go-euc-status 2>&1 | grep -c PROBLEM" 2>/dev/null | tr '\n' ' ')"
  read -r t c e s f <<<"${remote}"
  [[ "${t:-0}" -ge 1 ]] && ok "Telegraf config points at ${web}/influx" || bad "Telegraf config not updated (${t:-?})"
  [[ "${c:-0}" -ge 1 ]] && ok "config.txt has HTTPSPort=${https}" || bad "config.txt HTTPSPort not ${https}"
  [[ "${e:-0}" -ge 1 ]] && ok "config.env has APPLIANCE_HTTPS_PORT=${https}" || bad "config.env not updated"
  [[ "${s:-0}" -ge 1 ]] && ok "compose publishes ${http}:80" || bad "compose port mapping not updated"
  [[ "${f:-1}" -eq 0 ]] && ok "go-euc-status has no failures" || bad "go-euc-status reports ${f:-?} failure(s)"
  [[ "${https}" != 443 ]] && { expect "old port 443 closed" "000" "https://${IP}/"; }
}

echo "===== Starting point: standard ports"
check_ports 80 443

echo "===== Switch to alternative (landing page API)"
resp="$(curl -sk -K "${AUTH_CFG}" --max-time 15 -H 'Content-Type: application/json' -d '{"profile":"alternative"}' "https://${IP}/api/ports")"
[[ "${resp}" == *'"changed": true'* ]] && ok "POST /api/ports alternative accepted" || bad "POST /api/ports alternative: ${resp}"
sleep 8
check_ports 8080 4443

echo "===== Unknown profile is refused"
expect "POST /api/ports bogus" 400 -K "${AUTH_CFG}" -H 'Content-Type: application/json' -d '{"profile":"bogus"}' "https://${IP}:4443/api/ports"

echo "===== Back to standard (go-euc-set-ports over SSH)"
"${SSH[@]}" "sudo go-euc-set-ports standard" && ok "go-euc-set-ports standard" || bad "go-euc-set-ports standard failed"
check_ports 80 443

echo
echo "ports checks: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
