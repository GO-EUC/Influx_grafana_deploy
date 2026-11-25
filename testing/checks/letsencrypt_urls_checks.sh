#!/usr/bin/env bash
# What happens when a Let's Encrypt certificate becomes active, run ON the appliance as root:
#
#   ssh goeucadmin@<ip> 'sudo bash -s' < testing/checks/letsencrypt_urls_checks.sh
#
# A real certificate needs a public name that reaches the appliance on port 80, so this
# simulates one: it copies the appliance's self-signed certificate into a fake certbot
# lineage, sets a test domain and runs the real deploy hook. Checks Grafana's own URL
# (share/alert links), the Telegraf downloads and the Proxmox Metric Server settings use the
# domain (on port 443, also when the appliance listens on 4443), then restores everything.

set -u
DOMAIN="goeuc-le-test.example.com"
CONFIG=/etc/go-euc/config.env
CERTS=/opt/influx-grafana/nginx/certs
HOOK=/usr/local/bin/go-euc-letsencrypt-deploy-hook.sh
STACK=/opt/influx-grafana/stack/docker-compose.yml
TELEGRAF_CONF=/opt/influx-grafana/public/telegraf/telegraf.conf
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
metric_server_field() { curl -s --max-time 5 http://127.0.0.1:18080/api/proxmox-metric-server | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }

echo "===== Before: self-signed certificate"
u="$(grafana_app_url)"
[[ "${u}" == "http://localhost/grafana/" ]] && ok "Grafana URL is the default (${u})" || bad "Grafana URL before: '${u}'"
[[ -x /usr/local/bin/go-euc-grafana-url.sh ]] && ok "go-euc-grafana-url.sh installed" || bad "go-euc-grafana-url.sh missing"

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

echo "===== Simulated certificate for ${DOMAIN} (real deploy hook)"
mkdir -p "${TMP}/live"
cp "${CERTS}/cert.pem" "${TMP}/live/fullchain.pem"
cp "${CERTS}/key.pem" "${TMP}/live/privkey.pem"
printf "APPLIANCE_LETSENCRYPT_DOMAIN='%s'\n" "${DOMAIN}" >> "${CONFIG}"
out="$(RENEWED_LINEAGE="${TMP}/live" "${HOOK}" 2>&1)"
grep -q "Grafana URL set to https://${DOMAIN}/grafana/" <<<"${out}" && ok "deploy hook set the Grafana URL" || { bad "deploy hook output:"; echo "${out}" | tail -5; }
grep -q "GF_SERVER_ROOT_URL: \"https://${DOMAIN}/grafana/\"" "${STACK}" && ok "docker-compose.yml has the domain URL" || bad "docker-compose.yml not updated"
u="$(grafana_app_url)"
[[ "${u}" == "https://${DOMAIN}/grafana/" ]] && ok "Grafana serves appUrl ${u}" || bad "Grafana appUrl '${u}'"
grep -q "\"https://${DOMAIN}/influx\"" "${TELEGRAF_CONF}" && ok "Telegraf config uses https://${DOMAIN}/influx" || bad "Telegraf config URL: $(grep -m1 -o 'https://[^"]*/influx' "${TELEGRAF_CONF}")"
grep -q "insecure_skip_verify = false" "${TELEGRAF_CONF}" && ok "Telegraf verifies TLS" || bad "Telegraf insecure_skip_verify not false"
[[ "$(metric_server_field server)" == "${DOMAIN}" ]] && ok "Proxmox Metric Server uses the domain" || bad "Proxmox Metric Server server: $(metric_server_field server)"
r="$(/usr/local/bin/go-euc-grafana-url.sh)"
[[ "${r}" == *"already https://${DOMAIN}/grafana/"* ]] && ok "re-run leaves Grafana alone" || bad "re-run: ${r}"

echo "===== Same, with the appliance on the alternative ports (router maps 443 -> 4443)"
echo "APPLIANCE_HTTPS_PORT=4443" >> "${CONFIG}"
/usr/local/bin/go-euc-publish-telegraf-config.sh >/dev/null 2>&1
grep -q "\"https://${DOMAIN}/influx\"" "${TELEGRAF_CONF}" && ok "Telegraf config: domain without :4443" || bad "Telegraf config URL: $(grep -m1 -o 'https://[^"]*/influx' "${TELEGRAF_CONF}")"
[[ "$(metric_server_field port)" == 443 ]] && ok "Proxmox Metric Server port 443 with the domain" || bad "Proxmox Metric Server port: $(metric_server_field port)"
[[ "$(/usr/local/bin/go-euc-grafana-url.sh --print)" == "https://${DOMAIN}/grafana/" ]] && ok "Grafana URL: domain without :4443" || bad "Grafana URL: $(/usr/local/bin/go-euc-grafana-url.sh --print)"
sed -i '$d' "${CONFIG}"   # drop the APPLIANCE_HTTPS_PORT line again

echo "===== After restoring the self-signed certificate"
restore
u="$(grafana_app_url)"
[[ "${u}" == "http://localhost/grafana/" ]] && ok "Grafana URL back to the default" || bad "Grafana appUrl after restore: '${u}'"
grep -q "\"https://${IP}/influx\"" "${TELEGRAF_CONF}" && ok "Telegraf config back to https://${IP}/influx" || bad "Telegraf config URL after restore"
cmp -s "${CONFIG}" "${TMP}/config.env" && ok "config.env restored" || bad "config.env differs"

echo
echo "===== result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
