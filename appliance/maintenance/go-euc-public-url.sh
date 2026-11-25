#!/usr/bin/env bash
# Prints the address the appliance hands out to clients (Telegraf configs, Grafana's links,
# Proxmox Metric Server settings), as KEY=value lines:
#
#   PUBLIC_SOURCE      override | letsencrypt | ip
#   PUBLIC_HOST        host name or IP address
#   PUBLIC_PORT        HTTPS port
#   PUBLIC_BASE        https://<host>[:<port>]   (port left out when it is 443)
#   PUBLIC_TLS_VERIFY  true when the appliance's own Let's Encrypt certificate is for PUBLIC_HOST
#
# Which address, in order:
#   1. APPLIANCE_PUBLIC_HOSTNAME (go-euc-set-hostname): host name, or host name:port
#   2. the Let's Encrypt domain, once its certificate is active
#   3. the appliance's IP address
# The port is the appliance's web port (APPLIANCE_HTTPS_PORT, go-euc-set-ports), unless the
# host name override gives its own (e.g. a reverse proxy publishing it on 443).

set -euo pipefail

CONFIG_FILE="/etc/go-euc/config.env"
CERT_DIR="/opt/influx-grafana/nginx/certs"

if [[ -r "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
elif [[ -f "${CONFIG_FILE}" ]]; then
  echo "[public-url] ${CONFIG_FILE} is not readable; run with sudo." >&2
  exit 1
fi

le_domain="${APPLIANCE_LETSENCRYPT_DOMAIN:-}"
le_active=false
if [[ -n "${le_domain}" && -s "${CERT_DIR}/letsencrypt.crt" ]] \
  && cmp -s "${CERT_DIR}/cert.pem" "${CERT_DIR}/letsencrypt.crt"; then
  le_active=true
fi

port="${APPLIANCE_HTTPS_PORT:-443}"
override="${APPLIANCE_PUBLIC_HOSTNAME:-}"
if [[ -n "${override}" ]]; then
  source_name="override"
  host="${override%%:*}"
  [[ "${override}" == *:* ]] && port="${override##*:}"
elif [[ "${le_active}" == true ]]; then
  source_name="letsencrypt"
  host="${le_domain}"
else
  source_name="ip"
  host="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

verify=false
[[ "${le_active}" == true && "${host}" == "${le_domain}" ]] && verify=true

base="https://${host}"
[[ "${port}" != 443 ]] && base="${base}:${port}"

printf 'PUBLIC_SOURCE=%s\nPUBLIC_HOST=%s\nPUBLIC_PORT=%s\nPUBLIC_BASE=%s\nPUBLIC_TLS_VERIFY=%s\n' \
  "${source_name}" "${host}" "${port}" "${base}" "${verify}"
