#!/usr/bin/env bash
# GO-EUC appliance on-box checks (see testing/README.md).
# Run as root on the appliance: ssh ... 'sudo EXPECTED_IP=<ip> EXPECTED_HOST=<name> bash -s' < remote_checks.sh
# Prints PASS/FAIL/INFO lines; never prints passwords or tokens.

set -u
EXPECTED_IP="${EXPECTED_IP:-192.168.102.130}"
EXPECTED_HOST="${EXPECTED_HOST:-}"
pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
info() { echo "INFO  $*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "${desc}"; else bad "${desc}"; fi; }
mode_of() { stat -c '%a %U:%G' "$1" 2>/dev/null; }
mode_num() { stat -c '%a %u:%g' "$1" 2>/dev/null; }
expect_mode() { local f="$1" want="$2" got; got="$(mode_of "$f")"; [[ "$got" == "$want" ]] && ok "perms ${f} = ${want}" || bad "perms ${f}: got '${got}', want '${want}'"; }

echo "===== provisioning"
check "first-boot marker /var/lib/go-euc/.installed" test -f /var/lib/go-euc/.installed
fb_result="$(systemctl show -p Result --value go-euc-firstboot.service)"
[[ "${fb_result}" == "success" ]] && ok "go-euc-firstboot.service result=success" || bad "go-euc-firstboot.service result=${fb_result}"
head -1 /etc/issue | grep -q "GO-EUC APPLIANCE - COMPLETE" && ok "/etc/issue banner COMPLETE" || bad "/etc/issue banner: $(head -1 /etc/issue)"
grep -q "password:" /etc/issue && bad "/etc/issue still shows a password after COMPLETE" || ok "/etc/issue shows no password after COMPLETE"
grep -qi "error\|traceback" /var/log/go-euc-install.log && info "install log mentions error/traceback: $(grep -ci 'error\|traceback' /var/log/go-euc-install.log) line(s)" || ok "install log has no error/traceback lines"
[[ -z "${EXPECTED_HOST}" || "$(hostname)" == "${EXPECTED_HOST}" ]] && ok "hostname $(hostname)" || bad "hostname $(hostname) != ${EXPECTED_HOST}"
ip -4 -o addr show | grep -q " ${EXPECTED_IP}/" && ok "static IP ${EXPECTED_IP} configured" || bad "static IP ${EXPECTED_IP} missing: $(ip -4 -o addr show | awk '{print $2, $4}' | tr '\n' ' ')"
ip route | grep -q '^default' && ok "default route: $(ip route | awk '/^default/ {print $3; exit}')" || bad "no default route"

echo "===== credentials and file permissions"
expect_mode /var/log/go-euc-install.log "600 root:root"
expect_mode /opt/influx-grafana/credentials.env "600 root:root"
expect_mode /opt/influx-grafana/appliance-login.env "600 root:root"
expect_mode /opt/influx-grafana/install-summary.txt "600 root:root"
expect_mode /etc/go-euc/break-glass.env "600 root:root"
expect_mode /etc/go-euc/config.env "600 root:root"
# group 101 = nginx workers inside the container (the host may name that gid differently)
m="$(mode_num /opt/influx-grafana/public/config.txt)"; [[ "$m" == "640 0:101" ]] && ok "perms config.txt = 640 root:101" || bad "perms config.txt: ${m}"
m="$(mode_num /opt/influx-grafana/run/api.sock)"; [[ "$m" == "660 0:101" ]] && ok "API socket api.sock = 660 root:101" || bad "API socket: ${m:-missing}"
grep -q '^BREAK_GLASS_ROTATED=true$' /etc/go-euc/break-glass.env && ok "break-glass password rotated per VM" || bad "break-glass not rotated"
grep -q 'Recover-ChangeMe-Now' /etc/go-euc/break-glass.env /opt/influx-grafana/appliance-login.env && bad "legacy default break-glass password present" || ok "no legacy default break-glass password"
# shellcheck source=/dev/null
source /opt/influx-grafana/credentials.env
for v in SAVED_INFLUX_ADMIN_TOKEN SAVED_TELEGRAF_WRITE_TOKEN SAVED_PROXMOX_WRITE_TOKEN SAVED_GRAFANA_ADMIN_PASSWORD SAVED_PORTAINER_ADMIN_PASSWORD; do
  [[ -n "${!v:-}" ]] && ok "${v} set" || bad "${v} empty"
done
[[ "${SAVED_TELEGRAF_WRITE_TOKEN:-x}" != "${SAVED_INFLUX_ADMIN_TOKEN:-y}" ]] && ok "Telegraf token differs from admin token" || bad "Telegraf token equals admin token"
for k in "Password=" "AdminToken=" "ProxmoxMetricServer" "InfluxToken="; do
  grep -q "${k}" /opt/influx-grafana/public/config.txt && ok "config.txt contains ${k}" || bad "config.txt missing ${k}"
done
grep -q "allow 192.168.102.0/24;" /opt/influx-grafana/nginx/auth/local-subnets.conf && ok "local-subnets.conf allows 192.168.102.0/24" || bad "local-subnets.conf: $(grep allow /opt/influx-grafana/nginx/auth/local-subnets.conf | tr '\n' ' ')"
grep -Eq 'allow 172\.' /opt/influx-grafana/nginx/auth/local-subnets.conf && bad "local-subnets.conf allows a Docker network" || ok "local-subnets.conf excludes Docker networks"
check "htpasswd present (SHA-512)" grep -q '^goeucadmin:\$6\$' /opt/influx-grafana/nginx/auth/htpasswd

echo "===== containers and ports"
for c in influxdb grafana goeuc-nginx goeucweb portainer; do
  st="$(docker inspect -f '{{.State.Status}} {{.Config.Image}}' "$c" 2>/dev/null)"
  [[ "${st}" == running* ]] && ok "container ${c}: ${st}" || bad "container ${c}: ${st:-missing}"
done
listen() { ss -ltnH "sport = :$1" | awk '{print $4}' | tr '\n' ' '; }
l="$(listen 3000)"; [[ -n "$l" && "$l" != *0.0.0.0* && "$l" != *"[::]"* && "$l" != *"*:"* ]] && ok "port 3000 (Grafana) localhost-only (${l})" || bad "port 3000 listeners: ${l:-none}"
[[ -z "$(docker port influxdb 2>/dev/null)" ]] && ok "InfluxDB container not published on the host" || bad "InfluxDB container published: $(docker port influxdb | tr '\n' ' ')"
[[ "$(docker port goeuc-nginx 8086/tcp 2>/dev/null)" == *8086* ]] && ok "port 8086 served by nginx (TLS)" || bad "nginx does not publish 8086"
for p in 80 443 8086 9443; do l="$(listen $p)"; [[ -n "$l" ]] && ok "port ${p} listening (${l})" || bad "port ${p} not listening"; done
[[ -z "$(listen 8000)" ]] && ok "port 8000 (Portainer edge) closed" || bad "port 8000 listening: $(listen 8000)"
l="$(listen 18080)"; [[ "$l" == "127.0.0.1:18080 " ]] && ok "API backend localhost-only (${l})" || bad "API backend listeners: ${l:-none}"
docker exec goeuc-nginx nginx -t >/dev/null 2>&1 && ok "nginx -t" || bad "nginx -t: $(docker exec goeuc-nginx nginx -t 2>&1 | tail -2 | tr '\n' ' ')"
check "go-euc-webfiles.service active" systemctl is-active go-euc-webfiles.service
systemctl is-enabled go-euc-upgrade.timer >/dev/null 2>&1 && info "upgrade timer enabled" || ok "upgrade timer disabled by default (AUTO_UPGRADE_ENABLED unset)"

echo "===== Portainer"
[[ "$(curl -sk -o /dev/null -w '%{http_code}' https://localhost:9443/api/users/admin/check)" == 204 ]] && ok "Portainer admin account exists" || bad "Portainer has no admin account (it locks itself after ~5 minutes)"
pl="$(python3 -c 'import json,sys; print(json.dumps({"Username": sys.argv[1], "Password": sys.argv[2]}))' "${SAVED_PORTAINER_ADMIN_USER}" "${SAVED_PORTAINER_ADMIN_PASSWORD}" | curl -sk -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -X POST https://localhost:9443/api/auth --data-binary @-)"
[[ "${pl}" == 200 ]] && ok "Portainer login with saved credentials" || bad "Portainer login -> ${pl}"
grep -q 'status:   init-failed' /var/log/go-euc-install.log && bad "install log: Portainer init-failed" || ok "install log: Portainer admin initialised"

echo "===== SSH"
[[ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication/ {print $2}')" == yes ]] && ok "SSH password login enabled (effective sshd config)" || bad "SSH password login disabled in the effective sshd config"

echo "===== go-euc-status"
if command -v go-euc-status >/dev/null 2>&1; then
  st="$(go-euc-status 2>&1)"
  n="$(grep -c 'PROBLEM' <<<"${st}")"
  [[ "${n}" == 0 ]] && ok "go-euc-status reports no problems" || bad "go-euc-status reports ${n} problem(s): $(grep PROBLEM <<<"${st}" | head -3 | tr -s ' ' | tr '\n' ';')"
else
  bad "go-euc-status command missing"
fi

echo "===== InfluxDB buckets and token scopes"
for b in Performance Tests Proxmox; do
  docker exec influxdb influx bucket find --name "$b" --org "${SAVED_INFLUX_ADMIN_ORG}" --token "${SAVED_INFLUX_ADMIN_TOKEN}" >/dev/null 2>&1 && ok "bucket ${b}" || bad "bucket ${b} missing"
done
# Through nginx exactly as clients use it: https://<appliance>/influx (prefix stripped by nginx).
INFLUX_API="${INFLUX_API:-https://127.0.0.1/influx}"
h="$(curl -sk "${INFLUX_API}/health")"
grep -q '"status": *"pass"' <<<"$h" && ok "${INFLUX_API}/health is InfluxDB's JSON health" || bad "${INFLUX_API}/health returned: $(head -c 80 <<<"$h")"
h="$(curl -sk https://127.0.0.1:8086/health)"
grep -q '"status": *"pass"' <<<"$h" && ok "https://127.0.0.1:8086/health is InfluxDB's JSON health" || bad "https://:8086/health returned: $(head -c 80 <<<"$h")"
write_code() { curl -sk -o /dev/null -w '%{http_code}' -X POST "${INFLUX_API}/api/v2/write?org=${SAVED_INFLUX_ADMIN_ORG}&bucket=$2&precision=s" -H "Authorization: Token $1" --data-binary "goeuc_selftest,check=scope value=1i"; }
query_code() { curl -sk -o /dev/null -w '%{http_code}' -X POST "${INFLUX_API}/api/v2/query?org=${SAVED_INFLUX_ADMIN_ORG}" -H "Authorization: Token $1" -H 'Content-Type: application/vnd.flux' --data-binary 'from(bucket:"Performance") |> range(start:-1m) |> limit(n:1)'; }
c="$(write_code "${SAVED_TELEGRAF_WRITE_TOKEN}" Performance)"; [[ "$c" == 204 ]] && ok "Telegraf token can write Performance" || bad "Telegraf token write Performance -> ${c}"
c="$(write_code "${SAVED_TELEGRAF_WRITE_TOKEN}" Tests)"; [[ "$c" =~ ^40[134]$ ]] && ok "Telegraf token cannot write Tests (${c})" || bad "Telegraf token write Tests -> ${c}"
c="$(query_code "${SAVED_TELEGRAF_WRITE_TOKEN}")"; [[ "$c" =~ ^40[134]$ ]] && ok "Telegraf token cannot read (${c})" || bad "Telegraf token query -> ${c}"
c="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "https://127.0.0.1/api/v2/write?org=${SAVED_INFLUX_ADMIN_ORG}&bucket=Performance&precision=s" -H "Authorization: Token ${SAVED_TELEGRAF_WRITE_TOKEN}" --data-binary "goeuc_selftest,check=root_api value=1i")"
[[ "$c" == 204 ]] && ok "InfluxDB API at the root of 443 (/api/v2/write) accepts the Telegraf token" || bad "/api/v2/write at the root -> ${c}"
c="$(write_code "${SAVED_PROXMOX_WRITE_TOKEN}" Proxmox)"; [[ "$c" == 204 ]] && ok "Proxmox token can write Proxmox" || bad "Proxmox token write Proxmox -> ${c}"
c="$(write_code "${SAVED_PROXMOX_WRITE_TOKEN}" Performance)"; [[ "$c" =~ ^40[134]$ ]] && ok "Proxmox token cannot write Performance (${c})" || bad "Proxmox token write Performance -> ${c}"

echo "===== Grafana"
gf() { curl -s -u "${SAVED_GRAFANA_ADMIN_USER}:${SAVED_GRAFANA_ADMIN_PASSWORD}" "http://127.0.0.1:3000/grafana$1"; }
gf /api/health | grep -q '"database": *"ok"' && ok "Grafana health ok" || bad "Grafana health: $(gf /api/health | tr -d '\n' | cut -c1-120)"
ds_uid="$(gf /api/datasources/name/DS_GO | python3 -c 'import json,sys; print(json.load(sys.stdin).get("uid",""))' 2>/dev/null)"
[[ "${ds_uid}" == "DS_GO" ]] && ok "datasource DS_GO provisioned" || bad "datasource DS_GO: '${ds_uid}'"
dh="$(gf /api/datasources/uid/DS_GO/health | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null)"
[[ "${dh}" == "OK" ]] && ok "datasource DS_GO health OK" || bad "datasource DS_GO health: '${dh}'"
# Every dashboard file in the provisioned bundle must be loaded, with unique titles. The bundle is
# the repo's Dashboards.zip after first boot, or the published one after a full update.
files="$(find /opt/influx-grafana/stack/grafana/dashboards -name '*.json' | wc -l | tr -d ' ')"
# Count only file-provisioned dashboards (hand-made or migrated ones live alongside them).
n="$(python3 - "${SAVED_GRAFANA_ADMIN_USER}" "${SAVED_GRAFANA_ADMIN_PASSWORD}" <<'PY' 2>/dev/null
import base64, json, sys, urllib.request
auth = "Basic " + base64.b64encode(f"{sys.argv[1]}:{sys.argv[2]}".encode()).decode()
def get(path):
    req = urllib.request.Request("http://127.0.0.1:3000/grafana" + path, headers={"Authorization": auth})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)
prov = [d["title"] for d in get("/api/search?type=dash-db&limit=5000")
        if get(f"/api/dashboards/uid/{d['uid']}").get("meta", {}).get("provisioned")]
print(len(prov), len(set(prov)))
PY
)"
[[ "${n}" == "${files} ${files}" && "${files}" -gt 0 ]] && ok "${files} dashboard files -> ${files} dashboards provisioned, titles unique" || bad "dashboard files ${files}; provisioned / unique titles: ${n}"
c="$(docker logs grafana 2>&1 | grep -c 'failed to save dashboard')"
[[ "${c}" == 0 ]] && ok "no Grafana dashboard provisioning errors" || bad "Grafana logged ${c} 'failed to save dashboard' error(s)"
ls -R /opt/influx-grafana/stack/grafana/dashboards | grep -q MACOSX && bad "__MACOSX files extracted" || ok "no __MACOSX files in dashboards"

echo "===== Telegraf downloads"
TD=/opt/influx-grafana/public/telegraf
for f in telegraf.conf telegraf_vsphere.conf telegraf_nutanix.conf telegraf_proxmox.conf; do
  [[ -f "$TD/$f" ]] || { bad "$f missing"; continue; }
  grep -q '<<TELEGRAF_' "$TD/$f" && bad "$f still has <<TELEGRAF_ placeholders" || ok "$f rendered"
  grep -qF "${SAVED_TELEGRAF_WRITE_TOKEN}" "$TD/$f" && ok "$f uses write-only token" || bad "$f token is not the write-only token"
  grep -qF "${SAVED_INFLUX_ADMIN_TOKEN}" "$TD/$f" && bad "$f contains the admin token" || ok "$f has no admin token"
  sed 's/<<[A-Z_]*>>/x/g' "$TD/$f" | python3 -c 'import sys,tomllib; tomllib.loads(sys.stdin.read())' 2>/dev/null && ok "$f parses as TOML" || bad "$f TOML parse failed"
done
grep -q "https://${EXPECTED_IP}/influx" "$TD/telegraf.conf" && ok "telegraf.conf URL https://${EXPECTED_IP}/influx" || bad "telegraf.conf URL: $(grep -m1 urls "$TD/telegraf.conf")"
grep -q 'insecure_skip_verify = true' "$TD/telegraf.conf" && ok "telegraf.conf insecure_skip_verify=true (self-signed)" || bad "telegraf.conf insecure_skip_verify not true"
[[ -s "$TD/telegraf.exe" ]] && ok "telegraf.exe downloaded ($(du -h "$TD/telegraf.exe" | cut -f1))" || bad "telegraf.exe missing"
ls "$TD"/telegraf-*_windows_amd64.zip >/dev/null 2>&1 && ok "Telegraf Windows zip present" || bad "Telegraf Windows zip missing"

echo "===== result: ${pass} passed, ${fail} failed"
