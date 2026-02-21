#!/usr/bin/env bash

set -euo pipefail

MARKER_FILE="/var/lib/go-euc/.installed"
CONFIG_FILE="/etc/go-euc/config.env"
INSTALLER="/opt/go-euc-installer/scripts/step1_install_base.sh"
LOCAL_DASHBOARD_ZIP="/opt/go-euc-installer/Dashboards.zip"
LOG_FILE="/var/log/go-euc-install.log"

mkdir -p /var/lib/go-euc /etc/go-euc

if [[ -f "${MARKER_FILE}" ]]; then
  exit 0
fi

read_ovf_property() {
  local key="$1"
  local ovf_xml=""
  ovf_xml="$(vmtoolsd --cmd 'info-get guestinfo.ovfEnv' 2>/dev/null || true)"
  if [[ -z "${ovf_xml}" ]]; then
    return 0
  fi

  python3 - "${key}" <<'PY' 2>/dev/null <<<"${ovf_xml}"
import sys
import xml.etree.ElementTree as ET

want = sys.argv[1]
data = sys.stdin.read()
if not data.strip():
    print("")
    raise SystemExit(0)

try:
    root = ET.fromstring(data)
except Exception:
    print("")
    raise SystemExit(0)

def lname(tag):
    return tag.rsplit("}", 1)[-1]

for elem in root.iter():
    if lname(elem.tag) != "Property":
        continue
    key_attr = ""
    val_attr = ""
    for attr_name, attr_val in elem.attrib.items():
        la = lname(attr_name)
        if la == "key":
            key_attr = attr_val
        elif la == "value":
            val_attr = attr_val
    if key_attr == want:
        print(val_attr)
        raise SystemExit(0)

print("")
PY
}

load_ovf_properties() {
  # Values entered during OVA import (vApp/OVF properties).
  APPLIANCE_NAME="${APPLIANCE_NAME:-$(read_ovf_property appliance_name)}"
  APPLIANCE_NET_IFACE="${APPLIANCE_NET_IFACE:-$(read_ovf_property appliance_net_iface)}"
  APPLIANCE_STATIC_IP_CIDR="${APPLIANCE_STATIC_IP_CIDR:-$(read_ovf_property appliance_static_ip_cidr)}"
  APPLIANCE_GATEWAY="${APPLIANCE_GATEWAY:-$(read_ovf_property appliance_gateway)}"
  APPLIANCE_DNS="${APPLIANCE_DNS:-$(read_ovf_property appliance_dns)}"
}

log_detected_ovf_settings() {
  echo "[firstboot] OVF properties detected:"
  echo "[firstboot]   appliance_name=${APPLIANCE_NAME:-<not-set>}"
  echo "[firstboot]   appliance_net_iface=${APPLIANCE_NET_IFACE:-<auto-detect>}"
  echo "[firstboot]   appliance_static_ip_cidr=${APPLIANCE_STATIC_IP_CIDR:-<not-set>}"
  echo "[firstboot]   appliance_gateway=${APPLIANCE_GATEWAY:-<not-set>}"
  echo "[firstboot]   appliance_dns=${APPLIANCE_DNS:-<not-set>}"
}

# Optional local override file (takes precedence over OVF if set).
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

load_ovf_properties
log_detected_ovf_settings

detect_primary_interface() {
  ip route | awk '/^default/ {print $5; exit}'
}

apply_hostname_config() {
  local new_name="${APPLIANCE_NAME:-${APPLIANCE_HOSTNAME:-}}"
  if [[ -n "${new_name}" ]]; then
    hostnamectl set-hostname "${new_name}" || true
  fi
}

apply_network_config() {
  local static_ip="${APPLIANCE_STATIC_IP_CIDR:-}"
  local gateway="${APPLIANCE_GATEWAY:-}"
  local dns_csv="${APPLIANCE_DNS:-}"
  local iface="${APPLIANCE_NET_IFACE:-$(detect_primary_interface)}"
  local dns_yaml=""

  if [[ -z "${static_ip}" || -z "${iface}" ]]; then
    return 0
  fi

  if [[ -n "${dns_csv}" ]]; then
    dns_yaml="$(echo "${dns_csv}" | awk -F',' '{for (i=1; i<=NF; i++) {gsub(/^[ \t]+|[ \t]+$/, "", $i); printf "%s\"%s\"", (i==1 ? "" : ", "), $i}}')"
  fi

  cat > /etc/netplan/99-go-euc-appliance.yaml <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${static_ip}
EOF

  if [[ -n "${gateway}" ]]; then
    cat >> /etc/netplan/99-go-euc-appliance.yaml <<EOF
      routes:
        - to: default
          via: ${gateway}
EOF
  fi

  if [[ -n "${dns_yaml}" ]]; then
    cat >> /etc/netplan/99-go-euc-appliance.yaml <<EOF
      nameservers:
        addresses: [${dns_yaml}]
EOF
  fi

  netplan generate || true
  netplan apply || true
}

configure_upgrade_timer() {
  if [[ "${AUTO_UPGRADE_ENABLED:-false}" == "true" ]]; then
    systemctl daemon-reload || true
    systemctl enable --now go-euc-upgrade.timer || true
    echo "[firstboot] Automatic upgrade timer enabled."
  else
    echo "[firstboot] Automatic upgrade timer disabled (set AUTO_UPGRADE_ENABLED=true to enable)."
  fi
}

apply_hostname_config
apply_network_config
configure_upgrade_timer

# In appliance mode we always use the baked-in dashboard bundle.
if [[ -f "${INSTALLER}" && -f "${LOCAL_DASHBOARD_ZIP}" ]]; then
  sed -i 's|^DASHBOARDS_ZIP_URL=.*|DASHBOARDS_ZIP_URL="file:///opt/go-euc-installer/Dashboards.zip"|' "${INSTALLER}"
fi

if [[ ! -x "${INSTALLER}" ]]; then
  chmod +x "${INSTALLER}"
fi

"${INSTALLER}" | tee "${LOG_FILE}"

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${MARKER_FILE}"
