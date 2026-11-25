#!/usr/bin/env bash
# GO-EUC appliance HTTP checks, run from a client machine (see testing/README.md).
#
#   testing/checks/http_checks.sh <appliance-ip> [expect-config-txt]
#
# expect-config-txt: HTTP status expected for /config.txt from THIS client:
#   403 (default) when the client is NOT on the appliance's subnet, 200 when it is.
# The goeucadmin password is read from $GOEUC_TEST_DIR/goeucadmin.password (default ~/.goeuc-test).

set -u
IP="${1:?usage: $0 <appliance-ip> [expect-config-txt]}"
EXPECT_CONFIG_TXT="${2:-403}"
DIR="${GOEUC_TEST_DIR:-$HOME/.goeuc-test}"
BASE="https://${IP}"
pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
info() { echo "INFO  $*"; }

AUTH_CFG="$(mktemp)"; BODY="$(mktemp)"
trap 'rm -f "${AUTH_CFG}" "${BODY}"' EXIT
( umask 077; printf 'user = "goeucadmin:%s"\n' "$(tr -d '\r\n' < "${DIR}/goeucadmin.password")" > "${AUTH_CFG}" )

code()      { curl -sk -o "${BODY}" -w '%{http_code}' --connect-timeout 5 --max-time 60 "$@"; }
code_auth() { code -K "${AUTH_CFG}" "$@"; }
expect() { local desc="$1" want="$2" got="$3"; [[ "${got}" =~ ^(${want})$ ]] && ok "${desc} -> ${got}" || bad "${desc} -> ${got} (want ${want})"; }

echo "===== redirects, TLS and login"
expect "http://${IP}/ redirects to HTTPS" "301" "$(code "http://${IP}/")"
cn="$(echo | openssl s_client -connect "${IP}:443" -servername "${IP}" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"
[[ -n "${cn}" ]] && info "certificate ${cn}" || bad "no TLS certificate on :443"
expect "landing page without login" "401" "$(code "${BASE}/")"
expect "landing page with wrong password" "401" "$(code -u goeucadmin:wrong-password "${BASE}/")"
expect "landing page with login" "200" "$(code_auth "${BASE}/")"
for section in 'id="services"' 'id="collectors"' 'data-collector="vsphere"' 'data-collector="nutanix"' 'data-collector="proxmox"' 'id="telegraf"' 'id="maintenance"' 'id="certificates"' 'id="activity"' 'Prism Element'; do
  grep -q "${section}" "${BODY}" && ok "landing page has ${section}" || bad "landing page missing ${section}"
done
expect "/telegraf/ without login" "401" "$(code "${BASE}/telegraf/")"
expect "/telegraf/ folder with login (file listing)" "200" "$(code_auth "${BASE}/telegraf/")"
for f in telegraf.conf telegraf_vsphere.conf telegraf_nutanix.conf telegraf_proxmox.conf telegraf.exe WINDOWS_INSTALL.html; do
  grep -q "href=\"${f}\"" "${BODY}" && ok "/telegraf/ listing shows ${f}" || bad "/telegraf/ listing missing ${f}"
done
expect "/telegraf/telegraf.conf with login" "200" "$(code_auth "${BASE}/telegraf/telegraf.conf")"
expect "/telegraf/WINDOWS_INSTALL.html with login" "200" "$(code_auth "${BASE}/telegraf/WINDOWS_INSTALL.html")"

echo "===== config.txt (local subnet only, no login)"
expect "/config.txt from this client" "${EXPECT_CONFIG_TXT}" "$(code "${BASE}/config.txt")"
expect "/config.txt with login from this client (login must not bypass the subnet rule)" "${EXPECT_CONFIG_TXT}" "$(code_auth "${BASE}/config.txt")"

echo "===== proxied services"
expect "/grafana/" "200|302" "$(code "${BASE}/grafana/")"
expect "/grafana/login" "200" "$(code "${BASE}/grafana/login")"
expect "/influx/health" "200" "$(code "${BASE}/influx/health")"
grep -q '"status": *"pass"' "${BODY}" && ok "/influx/health is InfluxDB's JSON (API reached, prefix stripped)" || bad "/influx/health body is not InfluxDB health: $(head -c 80 "${BODY}")"
expect "/api/v2/write at the root without token" "401" "$(code -X POST --data-binary 'x v=1i' "${BASE}/api/v2/write?org=x&bucket=Performance")"
grep -q '"code":"unauthorized"' "${BODY}" && ok "/api/v2/ at the root is answered by InfluxDB (not the appliance login)" || bad "/api/v2/ at the root answered by something else: $(head -c 80 "${BODY}")"
expect "/influx/api/v2/write without token" "401" "$(code -X POST --data-binary 'x v=1i' "${BASE}/influx/api/v2/write?org=x&bucket=Performance")"
expect "InfluxDB https://${IP}:8086/health" "200" "$(code "https://${IP}:8086/health")"
grep -q '"status": *"pass"' "${BODY}" && ok ":8086/health is InfluxDB's JSON" || bad ":8086/health body: $(head -c 80 "${BODY}")"
expect "InfluxDB UI https://${IP}:8086/" "200" "$(code "https://${IP}:8086/")"
expect "plain HTTP to :8086 refused by TLS listener" "400" "$(code "http://${IP}:8086/")"
expect "/portainer/" "200" "$(code "${BASE}/portainer/")"
expect "/goeucweb/" "200" "$(code "${BASE}/goeucweb/")"
abs_links="$(grep -oE '(src|href)="/[^"]*"' "${BODY}" | grep -v '"/goeucweb/' | sort -u | head -5 | tr '\n' ' ')"
[[ -z "${abs_links}" ]] && ok "/goeucweb/ page has no root-absolute links" || info "/goeucweb/ root-absolute links (may break under the sub-path): ${abs_links}"
expect "Portainer direct https://${IP}:9443" "200" "$(code "https://${IP}:9443/")"

echo "===== direct ports closed"
for port in 3000 8000 18080; do
  expect "http://${IP}:${port} not reachable" "000" "$(code "http://${IP}:${port}/")"
done

echo "===== API"
expect "collector status without login" "401" "$(code "${BASE}/api/collectors/nutanix/status")"
for t in vsphere nutanix proxmox; do
  expect "GET /api/collectors/${t}/status" "200" "$(code_auth "${BASE}/api/collectors/${t}/status")"
done
expect "unknown collector type" "404" "$(code_auth "${BASE}/api/collectors/hyperv/status")"
expect "unknown API path" "404" "$(code_auth "${BASE}/api/does-not-exist")"
expect "GET /api/proxmox-metric-server" "200" "$(code_auth "${BASE}/api/proxmox-metric-server")"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["bucket"]=="Proxmox" and d["api_path_prefix"]=="/influx" and d["token"] and d["server"]==sys.argv[2]' "${BODY}" "${IP}" 2>/dev/null \
  && ok "Metric Server settings (server ${IP}, bucket Proxmox, prefix /influx, token present)" || bad "Metric Server settings: $(head -c 200 "${BODY}")"
post_json() { code_auth -X POST -H 'Content-Type: application/json' --data-binary "$2" "${BASE}$1"; }
expect "Let's Encrypt: shell injection in email rejected" "400" "$(post_json /api/configure-letsencrypt '{"domain":"appliance.example.com","email":"a@b.c;id"}')"
expect "Let's Encrypt: invalid domain rejected" "400" "$(post_json /api/configure-letsencrypt '{"domain":"not a domain","email":"admin@example.com"}')"
expect "Proxmox: invalid token ID rejected" "400" "$(post_json /api/collectors/proxmox/configure '{"address":"pve.lab","username":"root@pam","password":"8f2c1e2a-1111-2222-3333-444455556666"}')"
expect "Proxmox: invalid token secret rejected" "400" "$(post_json /api/collectors/proxmox/configure '{"address":"pve.lab","username":"telegraf@pve!monitoring","password":"not a uuid!"}')"
expect "vSphere: http:// address rejected" "400" "$(post_json /api/collectors/vsphere/configure '{"address":"http://vc.lab","username":"u","password":"p"}')"
expect "Nutanix: address with path rejected" "400" "$(post_json /api/collectors/nutanix/configure '{"address":"ntnx.lab/evil","username":"u","password":"p"}')"

echo "===== result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
