#!/usr/bin/env bash

set -eEuo pipefail

MARKER_FILE="/var/lib/go-euc/.installed"
CONFIG_FILE="/etc/go-euc/config.env"
INSTALLER="/opt/go-euc-installer/scripts/step1_install_base.sh"
LOCAL_DASHBOARD_ZIP="/opt/go-euc-installer/Dashboards.zip"
LOG_FILE="/var/log/go-euc-install.log"
INSTALL_ROOT="/opt/influx-grafana"
APPLIANCE_CREDS_FILE="${INSTALL_ROOT}/appliance-login.env"
SUMMARY_FILE="${INSTALL_ROOT}/install-summary.txt"
LOGIN_BANNER_FILE="/etc/issue"
BOOTSTRAP_NETPLAN_FILE="/etc/netplan/01-go-euc-bootstrap-dhcp.yaml"
STATIC_NETPLAN_FILE="/etc/netplan/99-go-euc-appliance.yaml"

mkdir -p /var/lib/go-euc /etc/go-euc "${INSTALL_ROOT}"

if [[ -f "${MARKER_FILE}" ]]; then
  exit 0
fi

get_runtime_network_details() {
  RUNTIME_HOSTNAME="$(hostname 2>/dev/null || echo "<unknown>")"
  RUNTIME_IFACE="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  RUNTIME_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  RUNTIME_GATEWAY="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
  RUNTIME_DNS="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd',' -)"

  [[ -n "${RUNTIME_IFACE}" ]] || RUNTIME_IFACE="<unknown>"
  [[ -n "${RUNTIME_IP}" ]] || RUNTIME_IP="<unknown>"
  [[ -n "${RUNTIME_GATEWAY}" ]] || RUNTIME_GATEWAY="<unknown>"
  [[ -n "${RUNTIME_DNS}" ]] || RUNTIME_DNS="<unknown>"
}

write_issue_status() {
  local status="$1"
  local detail="${2:-}"

  get_runtime_network_details

  cat > "${LOGIN_BANNER_FILE}" <<EOF
GO-EUC APPLIANCE - ${status}

If setup is running or failed, log in with break-glass account:
  username: ${BREAK_GLASS_USER_RESOLVED:-recovery}
  password: ${BREAK_GLASS_PASSWORD_RESOLVED:-Recover-ChangeMe-Now!}

Deployment status:
  ${detail:-No additional details}

Current network:
  hostname: ${RUNTIME_HOSTNAME}
  interface: ${RUNTIME_IFACE}
  ip: ${RUNTIME_IP}
  gateway: ${RUNTIME_GATEWAY}
  dns: ${RUNTIME_DNS}

First-boot troubleshooting:
  sudo systemctl status go-euc-firstboot.service
  sudo journalctl -u go-euc-firstboot.service -n 200 --no-pager
  sudo tail -n 200 ${LOG_FILE}
EOF
  chmod 644 "${LOGIN_BANNER_FILE}" || true
}

on_firstboot_error() {
  local exit_code="$1"
  local last_log_line="<no log output>"
  if [[ -f "${LOG_FILE}" ]]; then
    last_log_line="$(awk 'NF{p=$0} END{print p}' "${LOG_FILE}")"
  fi
  write_issue_status "FAILED" "First-boot exited with code ${exit_code}. Last log line: ${last_log_line}"
}

trap 'on_firstboot_error "$?"' ERR

ensure_firstboot_prereqs() {
  # Some CI-built appliances avoid in-image package installs during virt-customize.
  # Install runtime prerequisites here when available.
  local need_update="false"
  local pkgs=()

  if ! command -v growpart >/dev/null 2>&1; then
    pkgs+=("cloud-guest-utils")
  fi
  if ! command -v vmtoolsd >/dev/null 2>&1; then
    pkgs+=("open-vm-tools")
  fi
  if ! command -v xfs_growfs >/dev/null 2>&1; then
    pkgs+=("xfsprogs")
  fi

  if [[ "${#pkgs[@]}" -gt 0 ]]; then
    need_update="true"
  fi

  if [[ "${need_update}" == "true" ]]; then
    echo "[firstboot] Installing prerequisite packages: ${pkgs[*]}"
    apt-get update -y || true
    apt-get install -y "${pkgs[@]}" || true
  fi

  systemctl enable --now open-vm-tools >/dev/null 2>&1 || true
}

generate_secret() {
  local length="${1:-20}"
  local charset='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+='
  local i
  local output=""
  for ((i = 0; i < length; i++)); do
    output+="${charset:RANDOM%${#charset}:1}"
  done
  printf '%s' "${output}"
}

create_appliance_login() {
  APPLIANCE_LOGIN_USER_RESOLVED="${APPLIANCE_LOGIN_USER:-goeucadmin}"
  APPLIANCE_LOGIN_PASSWORD_RESOLVED="${APPLIANCE_LOGIN_PASSWORD:-$(generate_secret 20)}"
  BREAK_GLASS_USER_RESOLVED="${BREAK_GLASS_USER:-recovery}"
  BREAK_GLASS_PASSWORD_RESOLVED="${BREAK_GLASS_PASSWORD:-Recover-ChangeMe-Now!}"

  if ! id -u "${APPLIANCE_LOGIN_USER_RESOLVED}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${APPLIANCE_LOGIN_USER_RESOLVED}" || true
  fi

  usermod -aG sudo "${APPLIANCE_LOGIN_USER_RESOLVED}" >/dev/null 2>&1 || true
  echo "${APPLIANCE_LOGIN_USER_RESOLVED}:${APPLIANCE_LOGIN_PASSWORD_RESOLVED}" | chpasswd

  cat > "${APPLIANCE_CREDS_FILE}" <<EOF
APPLIANCE_LOGIN_USER='${APPLIANCE_LOGIN_USER_RESOLVED}'
APPLIANCE_LOGIN_PASSWORD='${APPLIANCE_LOGIN_PASSWORD_RESOLVED}'
BREAK_GLASS_USER='${BREAK_GLASS_USER_RESOLVED}'
BREAK_GLASS_PASSWORD='${BREAK_GLASS_PASSWORD_RESOLVED}'
EOF
  chmod 600 "${APPLIANCE_CREDS_FILE}"

  if ! id -u "${BREAK_GLASS_USER_RESOLVED}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${BREAK_GLASS_USER_RESOLVED}" || true
  fi
  usermod -aG sudo "${BREAK_GLASS_USER_RESOLVED}" >/dev/null 2>&1 || true
  echo "${BREAK_GLASS_USER_RESOLVED}:${BREAK_GLASS_PASSWORD_RESOLVED}" | chpasswd
}

add_login_user_to_docker_group() {
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "${APPLIANCE_LOGIN_USER_RESOLVED}" >/dev/null 2>&1 || true
  fi
}

publish_final_summary() {
  local saved_portainer_user="<unknown>"
  local saved_portainer_password="<unknown>"
  local saved_influx_user="<unknown>"
  local saved_influx_password="<unknown>"
  local saved_influx_org="<unknown>"
  local saved_grafana_user="<unknown>"
  local saved_grafana_password="<unknown>"

  if [[ -f "${INSTALL_ROOT}/credentials.env" ]]; then
    # shellcheck source=/dev/null
    source "${INSTALL_ROOT}/credentials.env"
    saved_portainer_user="${SAVED_PORTAINER_ADMIN_USER:-<unknown>}"
    saved_portainer_password="${SAVED_PORTAINER_ADMIN_PASSWORD:-<unknown>}"
    saved_influx_user="${SAVED_INFLUX_ADMIN_USER:-<unknown>}"
    saved_influx_password="${SAVED_INFLUX_ADMIN_PASSWORD:-<unknown>}"
    saved_influx_org="${SAVED_INFLUX_ADMIN_ORG:-<unknown>}"
    saved_grafana_user="${SAVED_GRAFANA_ADMIN_USER:-<unknown>}"
    saved_grafana_password="${SAVED_GRAFANA_ADMIN_PASSWORD:-<unknown>}"
  fi

  local host_ip="<unknown>"
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -z "${host_ip}" ]]; then
    host_ip="<unknown>"
  fi

  cat > "${SUMMARY_FILE}" <<EOF
============================================================
GO-EUC APPLIANCE SETUP COMPLETE
============================================================
Appliance Login
  Username: ${APPLIANCE_LOGIN_USER_RESOLVED}
  Password: ${APPLIANCE_LOGIN_PASSWORD_RESOLVED}

Portainer
  URL:      https://${host_ip}:9443
  Username: ${saved_portainer_user}
  Password: ${saved_portainer_password}

InfluxDB
  URL:      http://${host_ip}:8086
  Username: ${saved_influx_user}
  Password: ${saved_influx_password}
  Org:      ${saved_influx_org}

Grafana
  URL:      http://${host_ip}:3000
  Username: ${saved_grafana_user}
  Password: ${saved_grafana_password}

Credential files
  ${APPLIANCE_CREDS_FILE}
  ${INSTALL_ROOT}/credentials.env
  ${SUMMARY_FILE}
============================================================
EOF
  chmod 600 "${SUMMARY_FILE}"

  cat "${SUMMARY_FILE}" >> "${LOG_FILE}"
  for tty_dev in /dev/tty1 /dev/console; do
    if [[ -w "${tty_dev}" ]]; then
      cat "${SUMMARY_FILE}" > "${tty_dev}" || true
    fi
  done

  # Keep credentials and runtime network details visible at login prompt.
  local net_info=""
  get_runtime_network_details
  net_info="Setup complete. Hostname=${RUNTIME_HOSTNAME}, Interface=${RUNTIME_IFACE}, IP=${RUNTIME_IP}, Gateway=${RUNTIME_GATEWAY}, DNS=${RUNTIME_DNS}"
  write_issue_status "COMPLETE" "${net_info}"
  cat "${SUMMARY_FILE}" >> "${LOGIN_BANNER_FILE}"
}

read_ovf_property() {
  local key="$1"
  local ovf_xml=""
  if ! command -v vmtoolsd >/dev/null 2>&1; then
    return 0
  fi

  ovf_xml="$(vmtoolsd --cmd 'info-get guestinfo.ovfEnv' 2>/dev/null || true)"
  if [[ -z "${ovf_xml}" ]]; then
    return 0
  fi

  OVF_XML="${ovf_xml}" python3 -c '
import os
import sys
import xml.etree.ElementTree as ET

want = sys.argv[1]
data = os.environ.get("OVF_XML", "")
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
' "${key}" 2>/dev/null
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
  if ! command -v vmtoolsd >/dev/null 2>&1; then
    echo "[firstboot] vmtoolsd not found; OVF/vApp properties unavailable."
  fi
  echo "[firstboot] OVF properties detected:"
  echo "[firstboot]   appliance_name=${APPLIANCE_NAME:-<not-set>}"
  echo "[firstboot]   appliance_net_iface=${APPLIANCE_NET_IFACE:-<auto-detect>}"
  echo "[firstboot]   appliance_static_ip_cidr=${APPLIANCE_STATIC_IP_CIDR:-<not-set>}"
  echo "[firstboot]   appliance_gateway=${APPLIANCE_GATEWAY:-<not-set>}"
  echo "[firstboot]   appliance_dns=${APPLIANCE_DNS:-<not-set>}"
}

detect_primary_interface() {
  local iface=""
  iface="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  if [[ -n "${iface}" ]]; then
    printf '%s' "${iface}"
    return 0
  fi

  iface="$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')"
  printf '%s' "${iface}"
}

bootstrap_dhcp_network() {
  local iface=""
  local current_ip=""
  iface="$(detect_primary_interface)"
  current_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  if [[ -n "${current_ip}" ]]; then
    echo "[firstboot] Bootstrap DHCP not needed; IP already present (${current_ip})."
    return 0
  fi

  if [[ -z "${iface}" ]]; then
    echo "[firstboot] No network interface detected for bootstrap DHCP."
    return 0
  fi

  echo "[firstboot] Applying bootstrap DHCP config on interface ${iface}."
  cat > "${BOOTSTRAP_NETPLAN_FILE}" <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: true
      optional: true
EOF

  netplan generate || true
  netplan apply || true
  sleep 5
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

  cat > "${STATIC_NETPLAN_FILE}" <<EOF
network:
  version: 2
  ethernets:
    ${iface}:
      dhcp4: false
      addresses:
        - ${static_ip}
EOF

  if [[ -n "${gateway}" ]]; then
    cat >> "${STATIC_NETPLAN_FILE}" <<EOF
      routes:
        - to: default
          via: ${gateway}
EOF
  fi

  if [[ -n "${dns_yaml}" ]]; then
    cat >> "${STATIC_NETPLAN_FILE}" <<EOF
      nameservers:
        addresses: [${dns_yaml}]
EOF
  fi

  rm -f "${BOOTSTRAP_NETPLAN_FILE}" || true
  netplan generate || true
  netplan apply || true
}

# Optional local override file (takes precedence over OVF if set).
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

create_appliance_login
write_issue_status "INITIALIZING" "Bootstrapping appliance and applying imported OVA settings."
bootstrap_dhcp_network
ensure_firstboot_prereqs
load_ovf_properties
log_detected_ovf_settings

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
add_login_user_to_docker_group
publish_final_summary

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${MARKER_FILE}"
