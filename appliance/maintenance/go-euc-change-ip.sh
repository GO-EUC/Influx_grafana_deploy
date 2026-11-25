#!/usr/bin/env bash
# Change the appliance's static IP address after setup (e.g. to take over an old appliance's
# address once it has been shut down).
#
#   sudo go-euc-change-ip <ip/prefix> [gateway] [dns-servers-comma-separated]
#
# Gateway and DNS default to the current ones. Updates /etc/go-euc/config.env and the netplan
# configuration, applies it, then refreshes everything that depends on the address: the
# config.txt local-subnet list, the Telegraf downloads and the console banner. Run it from the
# VM console: an SSH session to the old address is cut off when the address changes.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

NEW_CIDR="${1:-}"
CONFIG_FILE="/etc/go-euc/config.env"
NETPLAN_FILE="/etc/netplan/99-go-euc-appliance.yaml"

if [[ ! "${NEW_CIDR}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
  echo "usage: $0 <ip/prefix> [gateway] [dns-servers-comma-separated]   e.g. $0 192.168.10.50/24" >&2
  exit 64
fi

iface="$(ip route | awk '/^default/ {print $5; exit}')"
[[ -n "${iface}" ]] || iface="$(ip -o -4 addr show scope global | awk '$2 != "docker0" && $2 !~ /^(br-|veth)/ {print $2; exit}')"
gateway="${2:-$(ip route | awk '/^default/ {print $3; exit}')}"
dns="${3:-$(resolvectl dns "${iface}" 2>/dev/null | awk -F': ' 'NF>1 {print $2}' | tr ' ' ',' | sed 's/,$//')}"
old_cidr="$(ip -4 -o addr show dev "${iface}" scope global | awk '{print $4; exit}')"

echo "[change-ip] ${iface}: ${old_cidr:-none} -> ${NEW_CIDR}, gateway ${gateway:-none}, DNS ${dns:-none}"
if [[ "${NEW_CIDR%/*}" != "${old_cidr%/*}" ]] && ping -c1 -W2 "${NEW_CIDR%/*}" >/dev/null 2>&1; then
  echo "[change-ip] ERROR: ${NEW_CIDR%/*} already answers on the network. Shut the device using it down first." >&2
  exit 1
fi

# config.env (shell-quoted, keeps every other setting).
touch "${CONFIG_FILE}"; chmod 600 "${CONFIG_FILE}"
tmp="$(mktemp)"
grep -Ev '^(APPLIANCE_STATIC_IP_CIDR|APPLIANCE_GATEWAY|APPLIANCE_DNS|APPLIANCE_NET_IFACE)=' "${CONFIG_FILE}" > "${tmp}" || true
{
  printf 'APPLIANCE_NET_IFACE=%q\n' "${iface}"
  printf 'APPLIANCE_STATIC_IP_CIDR=%q\n' "${NEW_CIDR}"
  printf 'APPLIANCE_GATEWAY=%q\n' "${gateway}"
  printf 'APPLIANCE_DNS=%q\n' "${dns}"
} >> "${tmp}"
install -m 600 "${tmp}" "${CONFIG_FILE}"; rm -f "${tmp}"

# netplan (same layout as first boot writes).
dns_yaml="$(tr ',' '\n' <<<"${dns}" | sed '/^$/d; s/.*/"&"/' | paste -sd',' - | sed 's/,/, /g')"
{
  echo "network:"
  echo "  version: 2"
  echo "  ethernets:"
  echo "    ${iface}:"
  echo "      dhcp4: false"
  echo "      addresses:"
  echo "        - ${NEW_CIDR}"
  if [[ -n "${gateway}" ]]; then
    echo "      routes:"
    echo "        - to: default"
    echo "          via: ${gateway}"
  fi
  if [[ -n "${dns_yaml}" ]]; then
    echo "      nameservers:"
    echo "        addresses: [${dns_yaml}]"
  fi
} > "${NETPLAN_FILE}"
chmod 600 "${NETPLAN_FILE}"
netplan generate
netplan apply
sleep 3

new_ip="$(ip -4 -o addr show dev "${iface}" scope global | awk '{print $4; exit}')"
[[ "${new_ip}" == "${NEW_CIDR}" ]] || { echo "[change-ip] ERROR: ${iface} has ${new_ip:-no address} after netplan apply" >&2; exit 1; }
echo "[change-ip] address applied: ${new_ip}"

# Replace whole occurrences of the old address only (192.168.1.13 must not match 192.168.1.130).
replace_ip() {
  local file="$1" old="$2" new="$3" old_re=""
  [[ -f "${file}" && -n "${old}" && "${old}" != "${new}" ]] || return 0
  old_re="${old//./\\.}"
  sed -i -E "s/(^|[^0-9.])${old_re}([^0-9]|$)/\1${new}\2/g" "${file}"
}

# Everything that embeds the address.
/usr/local/bin/go-euc-local-access.sh || true
/usr/local/bin/go-euc-publish-telegraf-config.sh || true
for f in /etc/issue /opt/influx-grafana/public/config.txt /opt/influx-grafana/install-summary.txt; do
  replace_ip "${f}" "${old_cidr%/*}" "${NEW_CIDR%/*}"
done

echo "[change-ip] Done. The appliance is now at https://${NEW_CIDR%/*}/"
echo "[change-ip] Windows machines need Telegraf configs from the new address (https://${NEW_CIDR%/*}/telegraf/)."
