#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="/etc/go-euc/config.env"
MARKER_FILE="/var/lib/go-euc/console-config.done"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo /usr/local/bin/go-euc-console-wizard.sh "$@"
fi

mkdir -p /etc/go-euc /var/lib/go-euc

detect_iface() {
  local iface=""
  iface="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  if [[ -n "${iface}" ]]; then
    printf '%s' "${iface}"
    return
  fi
  iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')"
  printf '%s' "${iface}"
}

DEFAULT_HOSTNAME="$(hostname 2>/dev/null || echo goeuc-appliance)"
DEFAULT_IFACE="$(detect_iface)"
DEFAULT_DNS="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd',' -)"

echo
echo "GO-EUC first login configuration wizard"
echo "Provide hostname and network details for this appliance."
echo

read -r -p "Hostname [${DEFAULT_HOSTNAME}]: " APPLIANCE_NAME
APPLIANCE_NAME="${APPLIANCE_NAME:-${DEFAULT_HOSTNAME}}"

read -r -p "Network interface [${DEFAULT_IFACE}]: " APPLIANCE_NET_IFACE
APPLIANCE_NET_IFACE="${APPLIANCE_NET_IFACE:-${DEFAULT_IFACE}}"

while true; do
  read -r -p "Static IP (CIDR, e.g. 192.168.1.215/24): " APPLIANCE_STATIC_IP_CIDR
  if [[ -n "${APPLIANCE_STATIC_IP_CIDR}" ]]; then
    break
  fi
  echo "Static IP is required."
done

while true; do
  read -r -p "Gateway (e.g. 192.168.1.1): " APPLIANCE_GATEWAY
  if [[ -n "${APPLIANCE_GATEWAY}" ]]; then
    break
  fi
  echo "Gateway is required."
done

read -r -p "DNS servers comma-separated [${DEFAULT_DNS:-1.1.1.1,8.8.8.8}]: " APPLIANCE_DNS
APPLIANCE_DNS="${APPLIANCE_DNS:-${DEFAULT_DNS:-1.1.1.1,8.8.8.8}}"

echo
echo "Appliance login user is: goeucadmin"
echo "Default password is currently: goeucadmin"
while true; do
  read -r -s -p "Enter new goeucadmin password (leave blank to keep current): " APPLIANCE_LOGIN_PASSWORD
  echo
  if [[ -z "${APPLIANCE_LOGIN_PASSWORD}" ]]; then
    break
  fi

  read -r -s -p "Confirm new password: " APPLIANCE_LOGIN_PASSWORD_CONFIRM
  echo
  if [[ "${APPLIANCE_LOGIN_PASSWORD}" == "${APPLIANCE_LOGIN_PASSWORD_CONFIRM}" ]]; then
    break
  fi
  echo "Passwords do not match. Try again."
  APPLIANCE_LOGIN_PASSWORD=""
done

TMP_FILE="$(mktemp /tmp/go-euc-config-XXXXXX)"
if [[ -f "${CONFIG_FILE}" ]]; then
  grep -Ev '^(APPLIANCE_NAME|APPLIANCE_HOSTNAME|APPLIANCE_NET_IFACE|APPLIANCE_STATIC_IP_CIDR|APPLIANCE_GATEWAY|APPLIANCE_DNS|APPLIANCE_LOGIN_PASSWORD)=' "${CONFIG_FILE}" > "${TMP_FILE}" || true
fi

cat >> "${TMP_FILE}" <<EOF
APPLIANCE_NAME=${APPLIANCE_NAME}
APPLIANCE_NET_IFACE=${APPLIANCE_NET_IFACE}
APPLIANCE_STATIC_IP_CIDR=${APPLIANCE_STATIC_IP_CIDR}
APPLIANCE_GATEWAY=${APPLIANCE_GATEWAY}
APPLIANCE_DNS=${APPLIANCE_DNS}
EOF

if [[ -n "${APPLIANCE_LOGIN_PASSWORD}" ]]; then
  cat >> "${TMP_FILE}" <<EOF
APPLIANCE_LOGIN_PASSWORD=${APPLIANCE_LOGIN_PASSWORD}
EOF
fi

mv "${TMP_FILE}" "${CONFIG_FILE}"
chmod 600 "${CONFIG_FILE}"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "${MARKER_FILE}"
chmod 600 "${MARKER_FILE}"

echo
echo "Configuration saved to ${CONFIG_FILE}"
echo "System will reboot to apply settings and continue appliance setup."
sleep 3
reboot
