#!/usr/bin/env bash
# Choose the ports the appliance's web server (nginx) listens on.
#
#   sudo go-euc-set-ports standard        HTTP 80,   HTTPS 443  (default)
#   sudo go-euc-set-ports alternative     HTTP 8080, HTTPS 4443
#   sudo go-euc-set-ports <http> <https>  any other pair
#   ... [--no-restart]                    only write the settings (used by first boot)
#
# InfluxDB's TLS port (8086), Portainer (9443) and SSH (22) do not change. Updates
# /etc/go-euc/config.env (APPLIANCE_HTTP_PORT / APPLIANCE_HTTPS_PORT), the nginx redirect,
# the Docker Compose port mapping, the Telegraf downloads, config.txt and the install summary,
# then recreates the nginx container. The landing page calls this through its API.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

CONFIG_FILE="/etc/go-euc/config.env"
NGINX_CONF="/opt/influx-grafana/nginx/conf.d/default.conf"
STACK_FILE="/opt/influx-grafana/stack/docker-compose.yml"
TELEGRAF_PUBLISH_SCRIPT="/usr/local/bin/go-euc-publish-telegraf-config.sh"
GRAFANA_URL_SCRIPT="/usr/local/bin/go-euc-grafana-url.sh"
RESTART=true

args=()
for a in "$@"; do
  [[ "${a}" == "--no-restart" ]] && RESTART=false || args+=("${a}")
done
case "${args[0]:-}" in
  standard) http=80; https=443 ;;
  alternative) http=8080; https=4443 ;;
  [0-9]*) http="${args[0]}"; https="${args[1]:-}" ;;
  *) echo "usage: $0 standard|alternative|<http-port> <https-port> [--no-restart]" >&2; exit 64 ;;
esac
for p in "${http}" "${https}"; do
  if [[ ! "${p}" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    echo "[ports] invalid port '${p}'" >&2; exit 64
  fi
  case "${p}" in
    22|3000|8086|9443|18080) echo "[ports] port ${p} is already used by the appliance" >&2; exit 64 ;;
  esac
done
[[ "${http}" != "${https}" ]] || { echo "[ports] HTTP and HTTPS ports must differ" >&2; exit 64; }

old_http="$(sed -n 's/^APPLIANCE_HTTP_PORT=//p' "${CONFIG_FILE}" 2>/dev/null | tail -1)"; old_http="${old_http:-80}"
old_https="$(sed -n 's/^APPLIANCE_HTTPS_PORT=//p' "${CONFIG_FILE}" 2>/dev/null | tail -1)"; old_https="${old_https:-443}"

# config.env (keeps every other setting).
touch "${CONFIG_FILE}"; chmod 600 "${CONFIG_FILE}"
tmp="$(mktemp)"
grep -Ev '^(APPLIANCE_HTTP_PORT|APPLIANCE_HTTPS_PORT)=' "${CONFIG_FILE}" > "${tmp}" || true
printf 'APPLIANCE_HTTP_PORT=%s\nAPPLIANCE_HTTPS_PORT=%s\n' "${http}" "${https}" >> "${tmp}"
install -m 600 "${tmp}" "${CONFIG_FILE}"; rm -f "${tmp}"

# nginx redirect (HTTP -> HTTPS) and Compose port mapping. The nginx config is bind-mounted as a
# single file, so it is rewritten in place (same inode), never replaced.
GOEUC_HTTP="${http}" GOEUC_HTTPS="${https}" GOEUC_OLD_HTTPS="${old_https}" python3 - "${NGINX_CONF}" "${STACK_FILE}" <<'PY'
import os, re, sys
http, https, old_https = os.environ["GOEUC_HTTP"], os.environ["GOEUC_HTTPS"], os.environ["GOEUC_OLD_HTTPS"]
conf, stack = sys.argv[1], sys.argv[2]
suffix = "" if https == "443" else f":{https}"
if os.path.exists(conf):
    text = open(conf, encoding="utf-8").read()
    new = re.sub(r"return 301 https://\$host[^$]*\$request_uri;", f"return 301 https://$host{suffix}$request_uri;", text)
    if new != text:
        with open(conf, "r+", encoding="utf-8") as fh:
            fh.seek(0); fh.write(new); fh.truncate()
if os.path.exists(stack):
    text = open(stack, encoding="utf-8").read()
    new = re.sub(r'(?m)^(\s*- ")\d+(:80")$', rf"\g<1>{http}\g<2>", text)
    new = re.sub(r'(?m)^(\s*- ")\d+(:443")$', rf"\g<1>{https}\g<2>", new)
    if new != text:
        open(stack, "w", encoding="utf-8").write(new)
PY

# Files that contain the appliance's HTTPS address.
replace_https_base() {
  local file="$1" ip="$2"
  [[ -f "${file}" && -n "${ip}" ]] || return 0
  local old_suffix="" new_suffix=""
  [[ "${old_https}" != 443 ]] && old_suffix=":${old_https}"
  [[ "${https}" != 443 ]] && new_suffix=":${https}"
  GOEUC_IP="${ip}" GOEUC_OLD="${old_suffix}" GOEUC_NEW="${new_suffix}" python3 - "${file}" <<'PY'
import os, re, sys
ip, old, new = os.environ["GOEUC_IP"], os.environ["GOEUC_OLD"], os.environ["GOEUC_NEW"]
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
# https://<ip>[:old]  followed by "/" or end of value, but not the other services' ports (8086, 9443).
pattern = re.compile(r"https://" + re.escape(ip) + re.escape(old) + r"(?=/|\s|$)", re.M)
new_text = pattern.sub(f"https://{ip}{new}", text)
if new_text != text:
    with open(path, "r+", encoding="utf-8") as fh:
        fh.seek(0); fh.write(new_text); fh.truncate()
PY
}
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
for f in /opt/influx-grafana/public/config.txt /opt/influx-grafana/install-summary.txt; do
  replace_https_base "${f}" "${ip}"
done

# config.txt port entries: HTTPPort / HTTPSPort, and Port= in the ProxmoxMetricServer section.
CONFIG_TXT=/opt/influx-grafana/public/config.txt
if [[ -f "${CONFIG_TXT}" ]]; then
  GOEUC_HTTP="${http}" GOEUC_HTTPS="${https}" python3 - "${CONFIG_TXT}" <<'PY'
import os, re, sys
path, http, https = sys.argv[1], os.environ["GOEUC_HTTP"], os.environ["GOEUC_HTTPS"]
text = open(path, encoding="utf-8").read()
new = re.sub(r"(?m)^HTTPPort=\d+$", f"HTTPPort={http}", text)
new = re.sub(r"(?m)^HTTPSPort=\d+$", f"HTTPSPort={https}", new)
new = re.sub(r"(?m)(^ProxmoxMetricServer\n(?:[^\n]+\n)*?)Port=\d+$", rf"\g<1>Port={https}", new)
if new != text:
    with open(path, "r+", encoding="utf-8") as fh:
        fh.seek(0); fh.write(new); fh.truncate()
PY
fi
[[ -x "${TELEGRAF_PUBLISH_SCRIPT}" ]] && "${TELEGRAF_PUBLISH_SCRIPT}" >/dev/null 2>&1 || true

echo "[ports] HTTP ${old_http} -> ${http}, HTTPS ${old_https} -> ${https}"
if [[ "${RESTART}" == true && -f "${STACK_FILE}" ]]; then
  docker compose -f "${STACK_FILE}" up -d nginx >/dev/null 2>&1
  echo "[ports] nginx restarted"
  # With a Let's Encrypt domain, Grafana's own URL carries the port too.
  [[ -x "${GRAFANA_URL_SCRIPT}" ]] && "${GRAFANA_URL_SCRIPT}" || true
fi
suffix=""; [[ "${https}" != 443 ]] && suffix=":${https}"
echo "[ports] The appliance is now at https://${ip}${suffix}/  (router: forward external ${http} -> ${http} and ${https} -> ${https})"
