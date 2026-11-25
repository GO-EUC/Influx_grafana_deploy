#!/usr/bin/env bash

# Renders the Telegraf config templates into the appliance web root (/telegraf/).
# Re-run whenever the Influx token, appliance address or TLS certificate changes
# (first boot and the Let's Encrypt deploy hook call it automatically).

set -euo pipefail

INSTALL_ROOT="/opt/influx-grafana"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
CONFIG_FILE="/etc/go-euc/config.env"
TEMPLATE_DIR="/opt/go-euc-installer/Telegraf"
TELEGRAF_PUBLIC_DIR="${INSTALL_ROOT}/public/telegraf"
NGINX_CERT_DIR="${INSTALL_ROOT}/nginx/certs"

if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
  echo "[telegraf-config] Credentials file not found: ${CREDENTIALS_FILE}" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${CREDENTIALS_FILE}"
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

influx_org="${SAVED_INFLUX_ADMIN_ORG:?SAVED_INFLUX_ADMIN_ORG missing from ${CREDENTIALS_FILE}}"
influx_token="${SAVED_TELEGRAF_WRITE_TOKEN:-}"
if [[ -z "${influx_token}" ]]; then
  echo "[telegraf-config] WARN: no Telegraf write-only token found; falling back to the admin token." >&2
  influx_token="${SAVED_INFLUX_ADMIN_TOKEN:?SAVED_INFLUX_ADMIN_TOKEN missing from ${CREDENTIALS_FILE}}"
fi

# With the default self-signed certificate Telegraf cannot verify the server, so TLS
# verification is skipped. Once a Let's Encrypt certificate is active, clients use the
# certificate's domain name and verify it normally.
appliance_host="$(hostname -I 2>/dev/null | awk '{print $1}')"
insecure_skip_verify="true"
if [[ -n "${APPLIANCE_LETSENCRYPT_DOMAIN:-}" && -s "${NGINX_CERT_DIR}/letsencrypt.crt" ]] \
  && cmp -s "${NGINX_CERT_DIR}/cert.pem" "${NGINX_CERT_DIR}/letsencrypt.crt"; then
  appliance_host="${APPLIANCE_LETSENCRYPT_DOMAIN}"
  insecure_skip_verify="false"
fi

if [[ -z "${appliance_host}" ]]; then
  echo "[telegraf-config] Unable to determine appliance address." >&2
  exit 1
fi

# Web server port (go-euc-set-ports), omitted when it is the standard 443. The Let's Encrypt
# domain is a public name and uses the public port 443 (the router maps 443 -> 4443).
https_port="${APPLIANCE_HTTPS_PORT:-443}"
port_suffix=""
[[ "${https_port}" != "443" && "${insecure_skip_verify}" == "true" ]] && port_suffix=":${https_port}"
telegraf_url="https://${appliance_host}${port_suffix}/influx"
mkdir -p "${TELEGRAF_PUBLIC_DIR}"

shopt -s nullglob
for template in "${TEMPLATE_DIR}"/*.conf; do
  output="${TELEGRAF_PUBLIC_DIR}/$(basename "${template}")"
  sed \
    -e "s|<<TELEGRAF_ORGANISATION>>|${influx_org}|g" \
    -e "s|<<TELEGRAF_URL>>|${telegraf_url}|g" \
    -e "s|<<TELEGRAF_TOKEN>>|${influx_token}|g" \
    -e "s|<<TELEGRAF_INSECURE_SKIP_VERIFY>>|${insecure_skip_verify}|g" \
    "${template}" > "${output}.tmp"
  chmod 644 "${output}.tmp"
  mv -f "${output}.tmp" "${output}"
done
shopt -u nullglob

echo "[telegraf-config] Published configs: url=${telegraf_url} insecure_skip_verify=${insecure_skip_verify}"
