#!/usr/bin/env bash
# Set the host name clients use to reach the appliance, with or without a Let's Encrypt
# certificate, e.g. when a reverse proxy or a DNS name points at it.
#
#   sudo go-euc-set-hostname goeuc.example.com        port follows the appliance's web port
#   sudo go-euc-set-hostname goeuc.example.com:443    explicit port (e.g. a proxy on 443 in
#                                                     front of an appliance on 4443)
#   sudo go-euc-set-hostname --clear                  back to the Let's Encrypt domain or the IP
#
# Saved as APPLIANCE_PUBLIC_HOSTNAME in /etc/go-euc/config.env. Re-publishes the Telegraf
# configs and sets Grafana's URL; the Proxmox Metric Server settings follow on the landing page.
# Only the addresses the appliance hands out change: nginx answers on every name either way.
# The landing page calls this through its API (Maintenance > Public host name).

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

CONFIG_FILE="/etc/go-euc/config.env"
TELEGRAF_PUBLISH_SCRIPT="/usr/local/bin/go-euc-publish-telegraf-config.sh"
GRAFANA_URL_SCRIPT="/usr/local/bin/go-euc-grafana-url.sh"
PUBLIC_URL_SCRIPT="/usr/local/bin/go-euc-public-url.sh"

value="${1:-}"
case "${value}" in
  "") echo "usage: $0 <host-name>[:<port>] | --clear" >&2; exit 64 ;;
  --clear) value="" ;;
  *)
    name="${value%%:*}"
    port=""; [[ "${value}" == *:* ]] && port="${value#*:}"
    label='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    if (( ${#name} > 253 )) || [[ ! "${name}" =~ ^${label}(\.${label})+$ ]]; then
      echo "[hostname] '${name}' is not a valid host name (e.g. goeuc.example.com)" >&2; exit 64
    fi
    if [[ -n "${port}" ]] && { [[ ! "${port}" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); }; then
      echo "[hostname] '${port}' is not a valid port" >&2; exit 64
    fi
    value="${name,,}${port:+:${port}}"
    ;;
esac

touch "${CONFIG_FILE}"; chmod 600 "${CONFIG_FILE}"
tmp="$(mktemp)"
grep -Ev '^(export[[:space:]]+)?APPLIANCE_PUBLIC_HOSTNAME=' "${CONFIG_FILE}" > "${tmp}" || true
[[ -n "${value}" ]] && printf "APPLIANCE_PUBLIC_HOSTNAME='%s'\n" "${value}" >> "${tmp}"
install -m 600 "${tmp}" "${CONFIG_FILE}"; rm -f "${tmp}"

[[ -x "${TELEGRAF_PUBLISH_SCRIPT}" ]] && "${TELEGRAF_PUBLISH_SCRIPT}" || true
[[ -x "${GRAFANA_URL_SCRIPT}" ]] && "${GRAFANA_URL_SCRIPT}" || true

base="$(sed -n 's/^PUBLIC_BASE=//p' < <("${PUBLIC_URL_SCRIPT}"))"
if [[ -n "${value}" ]]; then
  echo "[hostname] Public host name set: clients are given ${base}/"
else
  echo "[hostname] Public host name cleared: clients are given ${base}/"
fi
