#!/usr/bin/env bash
# The address the appliance hands out to clients (go-euc-public-url.sh), run ON the appliance
# as root:
#
#   ssh goeucadmin@<ip> 'sudo bash -s' < testing/checks/public_address_checks.sh
#
# Checks Grafana's own URL (share/alert links), the Telegraf downloads and the Proxmox Metric
# Server settings for each source of the address:
#   - the public host name override (go-euc-set-hostname and the landing page API), with and
#     without a port, and with the alternative web ports;
#   - an active Let's Encrypt certificate. A real one needs a public name that reaches the
#     appliance on port 80, so this simulates one: the appliance's self-signed certificate in a
#     fake certbot lineage, a test domain, and the real deploy hook;
#   - both together (the override wins);
# then restores everything.

set -u
DOMAIN="goeuc-le-test.example.com"
NAME="goeuc-override.example.com"
CONFIG=/etc/go-euc/config.env
CERTS=/opt/influx-grafana/nginx/certs
HOOK=/usr/local/bin/go-euc-letsencrypt-deploy-hook.sh
SET_HOSTNAME=/usr/local/bin/go-euc-set-hostname.sh
STACK=/opt/influx-grafana/stack/docker-compose.yml
TELEGRAF_CONF=/opt/influx-grafana/public/telegraf/telegraf.conf
API=http://127.0.0.1:18080
IP="$(hostname -I | awk '{print $1}')"
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }

https_port() { local p; p="$(sed -n 's/^APPLIANCE_HTTPS_PORT=//p' "${CONFIG}" | tail -1)"; echo "${p:-443}"; }
grafana_app_url() {  # Grafana's appUrl as served to browsers (waits for a restart)
  local u=""
  for _ in $(seq 1 45); do
    u="$(curl -sk --max-time 5 "https://127.0.0.1:$(https_port)/grafana/login" | grep -o '"appUrl":"[^"]*"' | cut -d'"' -f4)"
    [[ -n "${u}" ]] && break
    sleep 2
  done
  echo "${u}"
}
json_field() { python3 -c "import json,sys; print(json.load(sys.stdin).get('$1'))"; }
metric() { curl -s --max-time 5 -H "Host: ${IP}" "${API}/api/proxmox-metric-server" | json_field "$1"; }  # Host: as a browser on the LAN sends it
telegraf_url() { grep -m1 -o 'https://[^"]*/influx' "${TELEGRAF_CONF}"; }
telegraf_skip() { grep -m1 -o 'insecure_skip_verify = [a-z]*' "${TELEGRAF_CONF}" | awk '{print $3}'; }

# expect_addresses <label> <base-url> <tls-verify true|false> [grafana-url]
expect_addresses() {
  local label="$1" base="$2" verify="$3" grafana="${4:-$2/grafana/}" host port u
  host="${base#https://}"; host="${host%%:*}"
  port="443"; [[ "${base#https://}" == *:* ]] && port="${base##*:}"
  [[ "$(telegraf_url)" == "${base}/influx" ]] && ok "${label}: Telegraf URL ${base}/influx" || bad "${label}: Telegraf URL $(telegraf_url), expected ${base}/influx"
  local skip=true; [[ "${verify}" == true ]] && skip=false
  [[ "$(telegraf_skip)" == "${skip}" ]] && ok "${label}: Telegraf insecure_skip_verify = ${skip}" || bad "${label}: Telegraf insecure_skip_verify = $(telegraf_skip)"
  [[ "$(metric server)" == "${host}" && "$(metric port)" == "${port}" ]] && ok "${label}: Proxmox Metric Server ${host}:${port}" || bad "${label}: Proxmox Metric Server $(metric server):$(metric port)"
  [[ "$(metric verify_certificate)" == "$([[ "${verify}" == true ]] && echo True || echo False)" ]] && ok "${label}: Proxmox verify certificate ${verify}" || bad "${label}: Proxmox verify certificate $(metric verify_certificate)"
  u="$(grafana_app_url)"
  [[ "${u}" == "${grafana}" ]] && ok "${label}: Grafana appUrl ${u}" || bad "${label}: Grafana appUrl '${u}', expected ${grafana}"
}

TMP="$(mktemp -d)"
cp -a "${CONFIG}" "${TMP}/config.env"
cp -a "${CERTS}/cert.pem" "${TMP}/cert.pem"
cp -a "${CERTS}/key.pem" "${TMP}/key.pem"
restore() {
  cp -a "${TMP}/config.env" "${CONFIG}"
  install -m 0644 "${TMP}/cert.pem" "${CERTS}/cert.pem"
  install -m 0600 "${TMP}/key.pem" "${CERTS}/key.pem"
  rm -f "${CERTS}/letsencrypt.crt" "${CERTS}/letsencrypt.key"
  docker exec goeuc-nginx nginx -s reload >/dev/null 2>&1 || true
  /usr/local/bin/go-euc-publish-telegraf-config.sh >/dev/null 2>&1 || true
  /usr/local/bin/go-euc-grafana-url.sh >/dev/null 2>&1 || true
}
trap 'restore; rm -rf "${TMP}"' EXIT

echo "===== Before: no host name, self-signed certificate"
for s in go-euc-public-url.sh go-euc-set-hostname.sh go-euc-grafana-url.sh; do
  [[ -x "/usr/local/bin/${s}" ]] && ok "${s} installed" || bad "${s} missing"
done
expect_addresses "IP" "https://${IP}" false "http://localhost/grafana/"

echo "===== Host name override, no certificate (go-euc-set-hostname)"
"${SET_HOSTNAME}" "${NAME}" >/dev/null && ok "go-euc-set-hostname ${NAME}" || bad "go-euc-set-hostname ${NAME} failed"
grep -q "^APPLIANCE_PUBLIC_HOSTNAME='${NAME}'$" "${CONFIG}" && ok "config.env has APPLIANCE_PUBLIC_HOSTNAME" || bad "config.env not updated"
expect_addresses "override" "https://${NAME}" false
"${SET_HOSTNAME}" "${NAME}:8443" >/dev/null && ok "go-euc-set-hostname ${NAME}:8443" || bad "go-euc-set-hostname with port failed"
expect_addresses "override:port" "https://${NAME}:8443" false

echo "===== Override without a port follows the web port (alternative ports)"
"${SET_HOSTNAME}" "${NAME}" >/dev/null
echo "APPLIANCE_HTTPS_PORT=4443" >> "${CONFIG}"
/usr/local/bin/go-euc-publish-telegraf-config.sh >/dev/null 2>&1
[[ "$(telegraf_url)" == "https://${NAME}:4443/influx" ]] && ok "Telegraf URL https://${NAME}:4443/influx" || bad "Telegraf URL $(telegraf_url)"
[[ "$(/usr/local/bin/go-euc-grafana-url.sh --print)" == "https://${NAME}:4443/grafana/" ]] && ok "Grafana URL https://${NAME}:4443/grafana/" || bad "Grafana URL $(/usr/local/bin/go-euc-grafana-url.sh --print)"
sed -i '$d' "${CONFIG}"
/usr/local/bin/go-euc-publish-telegraf-config.sh >/dev/null 2>&1

echo "===== Invalid values are refused"
for v in "bad name" "x;id" "nodot" "${NAME}:99999" "-bad.example.com"; do
  "${SET_HOSTNAME}" "${v}" >/dev/null 2>&1; rc=$?
  [[ "${rc}" == 64 ]] && ok "CLI refuses '${v}'" || bad "CLI accepted '${v}' (rc=${rc})"
done
c="$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d '{"hostname":"x;id"}' "${API}/api/public-hostname")"
[[ "${c}" == 400 ]] && ok "API refuses 'x;id' (400)" || bad "API invalid host name -> ${c}"
grep -q "^APPLIANCE_PUBLIC_HOSTNAME='${NAME}'$" "${CONFIG}" && ok "refused values left the setting alone" || bad "setting changed by a refused value"

echo "===== Landing page API"
r="$(curl -s --max-time 120 -H 'Content-Type: application/json' -d '{"hostname":"API-Name.Example.com"}' "${API}/api/public-hostname")"
[[ "$(json_field source <<<"${r}")" == override && "$(json_field base_url <<<"${r}")" == "https://api-name.example.com" ]] && ok "POST sets the host name (lower-cased)" || bad "POST: ${r}"
[[ "$(curl -s "${API}/api/public-hostname" | json_field hostname)" == "api-name.example.com" ]] && ok "GET shows the host name" || bad "GET hostname wrong"
r="$(curl -s --max-time 120 -H 'Content-Type: application/json' -d '{"hostname":""}' "${API}/api/public-hostname")"
[[ "$(json_field source <<<"${r}")" == ip ]] && ok "POST with an empty name clears it" || bad "clear: ${r}"
grep -q "^APPLIANCE_PUBLIC_HOSTNAME=" "${CONFIG}" && bad "config.env still has APPLIANCE_PUBLIC_HOSTNAME" || ok "config.env no longer has APPLIANCE_PUBLIC_HOSTNAME"
expect_addresses "cleared" "https://${IP}" false "http://localhost/grafana/"

echo "===== Simulated Let's Encrypt certificate for ${DOMAIN} (real deploy hook)"
mkdir -p "${TMP}/live"
cp "${CERTS}/cert.pem" "${TMP}/live/fullchain.pem"
cp "${CERTS}/key.pem" "${TMP}/live/privkey.pem"
printf "APPLIANCE_LETSENCRYPT_DOMAIN='%s'\n" "${DOMAIN}" >> "${CONFIG}"
out="$(RENEWED_LINEAGE="${TMP}/live" "${HOOK}" 2>&1)"
grep -q "Grafana URL set to https://${DOMAIN}/grafana/" <<<"${out}" && ok "deploy hook set the Grafana URL" || { bad "deploy hook output:"; echo "${out}" | tail -5; }
grep -q "GF_SERVER_ROOT_URL: \"https://${DOMAIN}/grafana/\"" "${STACK}" && ok "docker-compose.yml has the domain URL" || bad "docker-compose.yml not updated"
expect_addresses "Let's Encrypt" "https://${DOMAIN}" true
r="$(/usr/local/bin/go-euc-grafana-url.sh)"
[[ "${r}" == *"already https://${DOMAIN}/grafana/"* ]] && ok "re-run leaves Grafana alone" || bad "re-run: ${r}"
echo "APPLIANCE_HTTPS_PORT=4443" >> "${CONFIG}"
/usr/local/bin/go-euc-publish-telegraf-config.sh >/dev/null 2>&1
[[ "$(telegraf_url)" == "https://${DOMAIN}:4443/influx" ]] && ok "alternative ports: Telegraf URL https://${DOMAIN}:4443/influx" || bad "alternative ports: Telegraf URL $(telegraf_url)"
[[ "$(metric port)" == 4443 ]] && ok "alternative ports: Proxmox Metric Server port 4443" || bad "alternative ports: Proxmox port $(metric port)"
[[ "$(/usr/local/bin/go-euc-grafana-url.sh --print)" == "https://${DOMAIN}:4443/grafana/" ]] && ok "alternative ports: Grafana URL https://${DOMAIN}:4443/grafana/" || bad "alternative ports: Grafana URL $(/usr/local/bin/go-euc-grafana-url.sh --print)"
sed -i '$d' "${CONFIG}"
/usr/local/bin/go-euc-publish-telegraf-config.sh >/dev/null 2>&1

echo "===== Certificate and host name override together"
"${SET_HOSTNAME}" "${NAME}" >/dev/null
expect_addresses "override wins over the domain (certificate doesn't cover it)" "https://${NAME}" false
"${SET_HOSTNAME}" "${DOMAIN}" >/dev/null
expect_addresses "override equal to the domain" "https://${DOMAIN}" true
"${SET_HOSTNAME}" --clear >/dev/null

echo "===== After restoring"
restore
expect_addresses "restored" "https://${IP}" false "http://localhost/grafana/"
cmp -s "${CONFIG}" "${TMP}/config.env" && ok "config.env restored" || bad "config.env differs"

echo
echo "===== result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
