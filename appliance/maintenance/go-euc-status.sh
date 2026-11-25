#!/usr/bin/env bash
# GO-EUC appliance status: one command for "is it working, and if not, where do I look?"
#
#   sudo go-euc-status
#
# Shows setup state, network, services, containers, infrastructure collectors, endpoint
# health, recent errors and log locations. Read-only; prints no passwords or tokens.

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

set -u
INSTALL_ROOT="/opt/influx-grafana"
LOG_FILE="/var/log/go-euc-install.log"
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; R=""; Y=""; B=""; N=""; fi
ok()   { printf '  %s%-6s%s %s\n' "${G}" "OK" "${N}" "$*"; }
bad()  { printf '  %s%-6s%s %s\n' "${R}" "PROBLEM" "${N}" "$*"; }
warn() { printf '  %s%-6s%s %s\n' "${Y}" "NOTE" "${N}" "$*"; }
section() { printf '\n%s%s%s\n' "${B}" "$*" "${N}"; }

section "Setup"
banner="$(head -1 /etc/issue 2>/dev/null)"
case "${banner}" in
  *COMPLETE*) ok "${banner}" ;;
  *FAILED*) bad "${banner}"; sed -n '/^Deployment status:/,/^$/p' /etc/issue | sed -n '2p' | sed 's/^ */           /' ;;
  *) warn "${banner:-no banner}" ;;
esac
[[ -f /var/lib/go-euc/console-config.done ]] && ok "console wizard completed" || warn "console wizard not completed yet: log in on the VM console to run it"
[[ -f /var/lib/go-euc/.installed ]] && ok "first boot finished ($(cat /var/lib/go-euc/.installed))" || warn "first boot has not finished"
fb="$(systemctl show -p ActiveState,Result --value go-euc-firstboot.service | tr '\n' ' ')"
[[ "${fb}" == *failed* ]] && bad "go-euc-firstboot.service: ${fb}" || ok "go-euc-firstboot.service: ${fb}"

section "Network"
ip4="$(ip -4 -o addr show scope global | awk '$2 != "docker0" && $2 !~ /^(br-|veth)/ {print $2 " " $4}' | tr '\n' ' ')"
gw="$(ip route | awk '/^default/ {print $3; exit}')"
dns="$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2 != "" {print $2}' | tr '\n' ' ')"
echo "  hostname $(hostname) | ${ip4:-no IPv4} | gateway ${gw:-none} | DNS ${dns:-unknown}"
[[ -n "${gw}" ]] && ok "default gateway ${gw}" || bad "no default gateway"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 https://registry-1.docker.io/v2/ 2>/dev/null)"
[[ "${code}" =~ ^[1-5] ]] && ok "internet reachable (Docker Hub answered ${code})" || warn "internet not reachable (needed for updates and image pulls)"

section "Services"
for unit in docker go-euc-webfiles; do
  st="$(systemctl is-active "${unit}" 2>/dev/null)"
  [[ "${st}" == active ]] && ok "${unit}: active" || bad "${unit}: ${st}"
done
systemctl is-enabled go-euc-upgrade.timer >/dev/null 2>&1 && ok "daily upgrade timer enabled" || warn "daily upgrade timer disabled (AUTO_UPGRADE_ENABLED=true in config.env enables it)"

section "Containers"
if command -v docker >/dev/null 2>&1; then
  for c in goeuc-nginx influxdb grafana portainer goeucweb; do
    st="$(docker inspect -f '{{.State.Status}} (restarts {{.RestartCount}}) {{.Config.Image}}' "$c" 2>/dev/null)"
    [[ "${st}" == running* ]] && ok "${c}: ${st}" || bad "${c}: ${st:-missing}   ->  docker logs ${c}"
  done
else
  bad "docker is not installed (first boot did not get that far)"
fi

section "Infrastructure collectors"
any=""
# Count collector errors from the last 10 minutes, but not from the first 2 minutes after
# InfluxDB (re)started: writes fail briefly while it restarts (updates, reboots) and Telegraf
# buffers and retries them, so those errors are expected and lose no data.
since=$(( $(date +%s) - 600 ))
influx_started="$(date -d "$(docker inspect -f '{{.State.StartedAt}}' influxdb 2>/dev/null)" +%s 2>/dev/null || echo 0)"
(( influx_started + 120 > since )) && since=$(( influx_started + 120 ))
for t in vsphere nutanix proxmox; do
  f="/etc/go-euc/collector-${t}.env"
  [[ -f "$f" ]] || continue
  any=1
  enabled="$(grep -q '^COLLECTOR_ENABLED=true$' "$f" && echo enabled || echo stopped)"
  st="$(docker inspect -f '{{.State.Status}}' "telegraf-${t}" 2>/dev/null || echo not-created)"
  errs=0
  (( since < $(date +%s) )) && errs="$(docker logs --since "${since}" "telegraf-${t}" 2>&1 | grep -c ' E! ')"
  if [[ "${enabled}" == enabled && "${st}" == running && "${errs}" == 0 ]]; then
    ok "${t}: running, no recent errors"
  elif [[ "${enabled}" == stopped ]]; then
    warn "${t}: stopped"
  else
    bad "${t}: ${enabled}, container ${st}, ${errs} recent error(s)   ->  sudo go-euc-collector.sh ${t} status"
  fi
done
[[ -n "${any}" ]] || warn "none configured (landing page > Infrastructure collectors)"

section "Endpoints (from the appliance itself)"
probe() {
  local desc="$1" want="$2" url="$3" got
  got="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "${url}")"
  [[ "${got}" =~ ^(${want})$ ]] && ok "${desc} (${got})" || bad "${desc}: got ${got}, expected ${want}   ${url}"
}
probe "landing page asks for login" "401" "https://127.0.0.1/"
probe "Grafana" "200|302" "https://127.0.0.1/grafana/"
probe "InfluxDB API via /influx" "200" "https://127.0.0.1/influx/health"
probe "InfluxDB UI/API on :8086" "200" "https://127.0.0.1:8086/health"
probe "Portainer" "200" "https://127.0.0.1/portainer/"
probe "GO-EUC Web" "200" "https://127.0.0.1/goeucweb/"
probe "landing page API backend" "200" "http://127.0.0.1:18080/api/collectors/nutanix/status"

section "Recent errors"
if [[ -f "${LOG_FILE}" ]]; then
  n="$(grep -ciE 'error|failed' "${LOG_FILE}")"
  [[ "${n}" == 0 ]] && ok "install log: no errors" || warn "install log: ${n} line(s) mention error/failed (sudo grep -iE 'error|failed' ${LOG_FILE})"
fi
j="$(journalctl -u go-euc-webfiles.service --since -1h -p err --no-pager -q 2>/dev/null | wc -l | tr -d ' ')"
[[ "${j}" == 0 ]] && ok "API backend: no errors in the last hour" || warn "API backend: ${j} error line(s) in the last hour (journalctl -u go-euc-webfiles.service)"

section "Where to look"
cat <<EOF
  First boot / install      sudo journalctl -u go-euc-firstboot.service --no-pager | tail -100
                            sudo tail -100 ${LOG_FILE}
  Full appliance update     sudo tail -100 /var/log/go-euc-appliance-update.log
  A container               sudo docker logs --tail 100 <goeuc-nginx|influxdb|grafana|portainer|goeucweb>
  A collector               sudo go-euc-collector.sh <vsphere|nutanix|proxmox> status
  Credentials               sudo cat ${INSTALL_ROOT}/install-summary.txt   (or ${INSTALL_ROOT}/public/config.txt)
  Break-glass account       sudo cat /etc/go-euc/break-glass.env
EOF
