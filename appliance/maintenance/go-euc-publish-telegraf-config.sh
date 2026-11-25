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
PUBLIC_URL_SCRIPT="/usr/local/bin/go-euc-public-url.sh"

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

# The address clients are given (go-euc-public-url.sh): the public host name override, the
# Let's Encrypt domain once its certificate is active, or the IP; with the web port. TLS is
# verified only against the appliance's own Let's Encrypt certificate; with the self-signed
# one (or a name the certificate doesn't cover) verification is skipped.
PUBLIC_BASE=""; PUBLIC_TLS_VERIFY="false"
while IFS='=' read -r key value; do
  case "${key}" in PUBLIC_*) printf -v "${key}" '%s' "${value}" ;; esac
done < <("${PUBLIC_URL_SCRIPT}")
if [[ -z "${PUBLIC_BASE}" || "${PUBLIC_BASE}" == "https://" ]]; then
  echo "[telegraf-config] Unable to determine appliance address." >&2
  exit 1
fi
insecure_skip_verify="true"
[[ "${PUBLIC_TLS_VERIFY}" == "true" ]] && insecure_skip_verify="false"
telegraf_url="${PUBLIC_BASE}/influx"
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
