#!/usr/bin/env bash

set -eEuo pipefail

MARKER_FILE="/var/lib/go-euc/.installed"
CONFIG_FILE="/etc/go-euc/config.env"
BREAK_GLASS_ENV_FILE="/etc/go-euc/break-glass.env"
DASHBOARD_URL_CONFIG_FILE="/etc/go-euc/dashboard-url"
INSTALLER="/opt/go-euc-installer/scripts/step1_install_base.sh"
LOCAL_DASHBOARD_ZIP="/opt/go-euc-installer/Dashboards.zip"
LOG_FILE="/var/log/go-euc-install.log"
INSTALL_ROOT="/opt/influx-grafana"
APPLIANCE_CREDS_FILE="${INSTALL_ROOT}/appliance-login.env"
SUMMARY_FILE="${INSTALL_ROOT}/install-summary.txt"
LOGIN_BANNER_FILE="/etc/issue"
BOOTSTRAP_NETPLAN_FILE="/etc/netplan/01-go-euc-bootstrap-dhcp.yaml"
STATIC_NETPLAN_FILE="/etc/netplan/99-go-euc-appliance.yaml"
PUBLIC_DIR="${INSTALL_ROOT}/public"
# config.txt holds every appliance credential. nginx serves it at https://<appliance>/config.txt
# without a login, but only to clients on the appliance's local IPv4 subnet(s)
# (allow-list written by go-euc-local-access.sh); everyone else gets 403.
PUBLIC_CONFIG_FILE="${PUBLIC_DIR}/config.txt"
LOCAL_ACCESS_SCRIPT="/usr/local/bin/go-euc-local-access.sh"
# gid of the "nginx" user in the official nginx images, so the file need not be world-readable.
NGINX_CONTAINER_GID="101"
PUBLIC_INDEX_FILE="${PUBLIC_DIR}/index.html"
CONSOLE_CONFIG_MARKER="/var/lib/go-euc/console-config.done"
TELEGRAF_SOURCE_DIR="/opt/go-euc-installer/Telegraf"
TELEGRAF_PUBLIC_DIR="${PUBLIC_DIR}/telegraf"
TELEGRAF_REFRESH_SCRIPT="/usr/local/bin/go-euc-refresh-telegraf.sh"
LE_RENEW_SCRIPT="/usr/local/bin/go-euc-renew-letsencrypt.sh"
NGINX_CERT_SETUP_SCRIPT="/usr/local/bin/go-euc-nginx-cert-setup.sh"
TELEGRAF_PUBLISH_SCRIPT="/usr/local/bin/go-euc-publish-telegraf-config.sh"
NGINX_DIR="${INSTALL_ROOT}/nginx"
NGINX_CONF_DIR="${NGINX_DIR}/conf.d"
NGINX_CERT_DIR="${NGINX_DIR}/certs"
NGINX_ACME_WEBROOT="${NGINX_DIR}/acme"
NGINX_AUTH_DIR="${NGINX_DIR}/auth"
NGINX_HTPASSWD_FILE="${NGINX_AUTH_DIR}/htpasswd"

mkdir -p /var/lib/go-euc /etc/go-euc "${INSTALL_ROOT}"

if [[ -f "${MARKER_FILE}" ]]; then
  exit 0
fi

get_runtime_network_details() {
  RUNTIME_HOSTNAME="$(hostname 2>/dev/null || echo "<unknown>")"
  RUNTIME_IFACE="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  RUNTIME_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  RUNTIME_GATEWAY="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
  # The configured (upstream) DNS servers; /etc/resolv.conf only shows the local stub 127.0.0.53.
  RUNTIME_DNS="$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2 != "" {print $2}' | tr ' ' '\n' | grep -v '^$' | sort -u | paste -sd',' -)"
  [[ -n "${RUNTIME_DNS}" ]] || RUNTIME_DNS="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | paste -sd',' -)"

  [[ -n "${RUNTIME_IFACE}" ]] || RUNTIME_IFACE="<unknown>"
  [[ -n "${RUNTIME_IP}" ]] || RUNTIME_IP="<unknown>"
  [[ -n "${RUNTIME_GATEWAY}" ]] || RUNTIME_GATEWAY="<unknown>"
  [[ -n "${RUNTIME_DNS}" ]] || RUNTIME_DNS="<unknown>"
}

write_issue_status() {
  local status="$1"
  local detail="${2:-}"
  local access_block=""

  get_runtime_network_details

  # The break-glass password is only shown on the local console while setup is
  # pending/running/failed. Once complete, credentials stay in root-only files.
  if [[ "${status}" == "COMPLETE" ]]; then
    access_block="Log in as ${APPLIANCE_LOGIN_USER_RESOLVED:-goeucadmin} and view credentials with:
  sudo cat ${SUMMARY_FILE}"
  else
    access_block="If setup is running or failed, log in with break-glass account:
  username: ${BREAK_GLASS_USER_RESOLVED:-recovery}
  password: ${BREAK_GLASS_PASSWORD_RESOLVED:-<see ${BREAK_GLASS_ENV_FILE}>}"
  fi

  cat > "${LOGIN_BANNER_FILE}" <<EOF
GO-EUC APPLIANCE - ${status}

${access_block}

Deployment status:
  ${detail:-No additional details}

Current network:
  hostname: ${RUNTIME_HOSTNAME}
  interface: ${RUNTIME_IFACE}
  ip: ${RUNTIME_IP}
  gateway: ${RUNTIME_GATEWAY}
  dns: ${RUNTIME_DNS}

Troubleshooting (appliance status, containers, recent errors, log locations):
  sudo go-euc-status
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
  if ! command -v sshd >/dev/null 2>&1; then
    pkgs+=("openssh-server")
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

generate_password() {
  local length="${1:-16}"
  python3 -c 'import secrets, string, sys
alphabet = string.ascii_letters + string.digits
sys.stdout.write("".join(secrets.choice(alphabet) for _ in range(int(sys.argv[1]))))' "${length}"
}

# Read one key from the build-time break-glass file without touching current variables.
read_break_glass_value() {
  local key="$1"
  [[ -f "${BREAK_GLASS_ENV_FILE}" ]] || return 0
  (
    unset BREAK_GLASS_USER BREAK_GLASS_PASSWORD BREAK_GLASS_ROTATED
    # shellcheck source=/dev/null
    source "${BREAK_GLASS_ENV_FILE}" >/dev/null 2>&1 || true
    printf '%s' "${!key:-}"
  )
}

create_appliance_login() {
  local baked_user=""
  local baked_password=""
  local baked_rotated=""
  baked_user="$(read_break_glass_value BREAK_GLASS_USER)"
  baked_password="$(read_break_glass_value BREAK_GLASS_PASSWORD)"
  baked_rotated="$(read_break_glass_value BREAK_GLASS_ROTATED)"

  APPLIANCE_LOGIN_USER_RESOLVED="${APPLIANCE_LOGIN_USER:-goeucadmin}"
  # The goeucadmin default only exists so the console wizard can be reached;
  # the wizard requires a new password before setup continues.
  APPLIANCE_LOGIN_PASSWORD_RESOLVED="${APPLIANCE_LOGIN_PASSWORD:-goeucadmin}"
  BREAK_GLASS_USER_RESOLVED="${BREAK_GLASS_USER:-${baked_user:-recovery}}"
  if [[ -n "${BREAK_GLASS_PASSWORD:-}" ]]; then
    BREAK_GLASS_PASSWORD_RESOLVED="${BREAK_GLASS_PASSWORD}"
  elif [[ "${baked_rotated}" == "true" && -n "${baked_password}" ]]; then
    BREAK_GLASS_PASSWORD_RESOLVED="${baked_password}"
  else
    # The build-time password is shared by every VM made from the image: rotate it per VM.
    BREAK_GLASS_PASSWORD_RESOLVED="$(generate_password 16)"
  fi

  (
    umask 077
    {
      printf 'BREAK_GLASS_USER=%q\n' "${BREAK_GLASS_USER_RESOLVED}"
      printf 'BREAK_GLASS_PASSWORD=%q\n' "${BREAK_GLASS_PASSWORD_RESOLVED}"
      printf 'BREAK_GLASS_ROTATED=true\n'
    } > "${BREAK_GLASS_ENV_FILE}"
  )
  chmod 600 "${BREAK_GLASS_ENV_FILE}"

  if ! id -u "${APPLIANCE_LOGIN_USER_RESOLVED}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${APPLIANCE_LOGIN_USER_RESOLVED}" || true
  fi

  usermod -aG sudo "${APPLIANCE_LOGIN_USER_RESOLVED}" >/dev/null 2>&1 || true
  printf '%s:%s\n' "${APPLIANCE_LOGIN_USER_RESOLVED}" "${APPLIANCE_LOGIN_PASSWORD_RESOLVED}" | chpasswd

  (
    umask 077
    {
      printf 'APPLIANCE_LOGIN_USER=%q\n' "${APPLIANCE_LOGIN_USER_RESOLVED}"
      printf 'APPLIANCE_LOGIN_PASSWORD=%q\n' "${APPLIANCE_LOGIN_PASSWORD_RESOLVED}"
      printf 'BREAK_GLASS_USER=%q\n' "${BREAK_GLASS_USER_RESOLVED}"
      printf 'BREAK_GLASS_PASSWORD=%q\n' "${BREAK_GLASS_PASSWORD_RESOLVED}"
    } > "${APPLIANCE_CREDS_FILE}"
  )
  chmod 600 "${APPLIANCE_CREDS_FILE}"

  if ! id -u "${BREAK_GLASS_USER_RESOLVED}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${BREAK_GLASS_USER_RESOLVED}" || true
  fi
  usermod -aG sudo "${BREAK_GLASS_USER_RESOLVED}" >/dev/null 2>&1 || true
  printf '%s:%s\n' "${BREAK_GLASS_USER_RESOLVED}" "${BREAK_GLASS_PASSWORD_RESOLVED}" | chpasswd
}

# HTTP basic auth for the appliance landing page, /telegraf/ and /api/.
write_web_auth() {
  local hash=""
  mkdir -p "${NGINX_AUTH_DIR}"
  hash="$(printf '%s\n' "${APPLIANCE_LOGIN_PASSWORD_RESOLVED}" | openssl passwd -6 -stdin)"
  printf '%s:%s\n' "${APPLIANCE_LOGIN_USER_RESOLVED}" "${hash}" > "${NGINX_HTPASSWD_FILE}"
  # nginx workers (non-root inside the container) must be able to read the hash file.
  chmod 644 "${NGINX_HTPASSWD_FILE}"
}

add_login_user_to_docker_group() {
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "${APPLIANCE_LOGIN_USER_RESOLVED}" >/dev/null 2>&1 || true
  fi
}

configure_ssh_access() {
  if ! command -v sshd >/dev/null 2>&1; then
    return 0
  fi

  # Password-based SSH for break-glass and appliance users (runs after the console wizard).
  # sshd uses the FIRST value it reads for each option, and the Ubuntu cloud image ships
  # /etc/ssh/sshd_config.d/60-cloudimg-settings.conf with "PasswordAuthentication no", which
  # overrides anything in sshd_config. Our own drop-in sorts first, so it takes effect.
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/10-go-euc.conf <<'CONF'
# GO-EUC appliance: password login for goeucadmin and the break-glass account (enabled only
# after the console wizard has replaced the default password). Keys keep working as well.
PasswordAuthentication yes
KbdInteractiveAuthentication no
CONF
  chmod 644 /etc/ssh/sshd_config.d/10-go-euc.conf

  # Ensure host keys exist so sshd can start.
  mkdir -p /etc/ssh
  if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    ssh-keygen -A >/dev/null 2>&1 || true
  fi

  systemctl enable --now ssh >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || true
}

publish_final_summary() {
  local saved_portainer_user="<unknown>"
  local saved_portainer_password="<unknown>"
  local saved_influx_user="<unknown>"
  local saved_influx_password="<unknown>"
  local saved_influx_org="<unknown>"
  local saved_influx_token="<unknown>"
  local saved_grafana_user="<unknown>"
  local saved_grafana_password="<unknown>"
  local saved_telegraf_token="<not-available: see ${LOG_FILE}>"
  local saved_proxmox_token="<not-available: see ${LOG_FILE}>"

  if [[ -f "${INSTALL_ROOT}/credentials.env" ]]; then
    # shellcheck source=/dev/null
    source "${INSTALL_ROOT}/credentials.env"
    saved_portainer_user="${SAVED_PORTAINER_ADMIN_USER:-<unknown>}"
    saved_portainer_password="${SAVED_PORTAINER_ADMIN_PASSWORD:-<unknown>}"
    saved_influx_user="${SAVED_INFLUX_ADMIN_USER:-<unknown>}"
    saved_influx_password="${SAVED_INFLUX_ADMIN_PASSWORD:-<unknown>}"
    saved_influx_org="${SAVED_INFLUX_ADMIN_ORG:-<unknown>}"
    saved_influx_token="${SAVED_INFLUX_ADMIN_TOKEN:-<unknown>}"
    saved_grafana_user="${SAVED_GRAFANA_ADMIN_USER:-<unknown>}"
    saved_grafana_password="${SAVED_GRAFANA_ADMIN_PASSWORD:-<unknown>}"
    if [[ -n "${SAVED_TELEGRAF_WRITE_TOKEN:-}" ]]; then
      saved_telegraf_token="${SAVED_TELEGRAF_WRITE_TOKEN}"
    fi
    if [[ -n "${SAVED_PROXMOX_WRITE_TOKEN:-}" ]]; then
      saved_proxmox_token="${SAVED_PROXMOX_WRITE_TOKEN}"
    fi
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
Appliance Login (also the web page login for https://${host_ip}/)
  Username: ${APPLIANCE_LOGIN_USER_RESOLVED}
  Password: ${APPLIANCE_LOGIN_PASSWORD_RESOLVED}

Break Glass
  Username: ${BREAK_GLASS_USER_RESOLVED}
  Password: ${BREAK_GLASS_PASSWORD_RESOLVED}

Portainer
  URL:      https://${host_ip}/portainer/
  Username: ${saved_portainer_user}
  Password: ${saved_portainer_password}

GO-EUC Web
  URL:      https://${host_ip}/goeucweb/

InfluxDB
  URL:      https://${host_ip}:8086/  (API also at https://${host_ip}/influx)
  Username: ${saved_influx_user}
  Password: ${saved_influx_password}
  Org:      ${saved_influx_org}
  Admin token: ${saved_influx_token}
  Telegraf write-only token: ${saved_telegraf_token}
  Proxmox Metric Server write-only token (Proxmox bucket): ${saved_proxmox_token}

Grafana
  URL:      https://${host_ip}/grafana/
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

  # Keep runtime network details visible at the login prompt (credentials stay in root-only files).
  local net_info=""
  get_runtime_network_details
  net_info="Setup complete. Hostname=${RUNTIME_HOSTNAME}, Interface=${RUNTIME_IFACE}, IP=${RUNTIME_IP}, Gateway=${RUNTIME_GATEWAY}, DNS=${RUNTIME_DNS}"
  write_issue_status "COMPLETE" "${net_info}"

  publish_telegraf_files

  cat > "${PUBLIC_CONFIG_FILE}" <<EOF
GO-EUC APPLIANCE CONFIG
GeneratedUTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ApplianceIP=${host_ip}

ServiceEndpoints
HTTPSBase=https://${host_ip}
RelativeGrafana=/grafana/
RelativeInflux=/influx/
RelativePortainer=/portainer/
RelativeGoeucWeb=/goeucweb/
GrafanaURL=https://${host_ip}/grafana/
InfluxURL=https://${host_ip}:8086/
InfluxApiURL=https://${host_ip}/influx
PortainerURL=https://${host_ip}/portainer/
GoeucWebURL=https://${host_ip}/goeucweb/
PortainerDirectURL=https://${host_ip}:9443
PortainerPort=9443
InfluxPort=8086
GoeucWebContainerPort=80

Appliance Login
Username=${APPLIANCE_LOGIN_USER_RESOLVED}
Password=${APPLIANCE_LOGIN_PASSWORD_RESOLVED}

Break Glass
Username=${BREAK_GLASS_USER_RESOLVED}
Password=${BREAK_GLASS_PASSWORD_RESOLVED}

Portainer
Username=${saved_portainer_user}
Password=${saved_portainer_password}

InfluxDB
Username=${saved_influx_user}
Password=${saved_influx_password}
Org=${saved_influx_org}
AdminToken=${saved_influx_token}

Grafana
Username=${saved_grafana_user}
Password=${saved_grafana_password}

Telegraf
PackageFolder=${TELEGRAF_PUBLIC_DIR}
InfluxURL=https://${host_ip}/influx
InfluxOrg=${saved_influx_org}
InfluxBucket=Performance
InfluxToken=${saved_telegraf_token}
InfluxTokenScope=write-only (Performance bucket)

ProxmoxMetricServer
Server=${host_ip}
Port=443
Protocol=https
ApiPathPrefix=/influx
Organization=${saved_influx_org}
Bucket=Proxmox
Token=${saved_proxmox_token}
TokenScope=write-only (Proxmox bucket)
EOF
  # Contains every appliance credential: readable by root and the nginx container's workers only.
  chown "root:${NGINX_CONTAINER_GID}" "${PUBLIC_CONFIG_FILE}"
  chmod 640 "${PUBLIC_CONFIG_FILE}"
}

detect_primary_interface() {
  local iface=""
  local candidate=""
  iface="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  if [[ -n "${iface}" ]]; then
    printf '%s' "${iface}"
    return 0
  fi

  # Prefer first interface with carrier up.
  for candidate in /sys/class/net/*; do
    candidate="$(basename "${candidate}")"
    [[ "${candidate}" == "lo" ]] && continue
    if [[ -r "/sys/class/net/${candidate}/carrier" ]] && [[ "$(cat "/sys/class/net/${candidate}/carrier" 2>/dev/null)" == "1" ]]; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

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
  local netmask="${APPLIANCE_NETMASK:-}"
  local gateway="${APPLIANCE_GATEWAY:-}"
  local dns_csv="${APPLIANCE_DNS:-}"
  local iface="${APPLIANCE_NET_IFACE:-$(detect_primary_interface)}"
  local dns_yaml=""
  local prefix=""

  if [[ -z "${static_ip}" || -z "${iface}" ]]; then
    return 0
  fi

  if [[ "${static_ip}" != */* ]]; then
    if [[ -n "${netmask}" ]]; then
      case "${netmask}" in
        255.255.255.255) prefix="32" ;;
        255.255.255.254) prefix="31" ;;
        255.255.255.252) prefix="30" ;;
        255.255.255.248) prefix="29" ;;
        255.255.255.240) prefix="28" ;;
        255.255.255.224) prefix="27" ;;
        255.255.255.192) prefix="26" ;;
        255.255.255.128) prefix="25" ;;
        255.255.255.0) prefix="24" ;;
        255.255.254.0) prefix="23" ;;
        255.255.252.0) prefix="22" ;;
        255.255.248.0) prefix="21" ;;
        255.255.240.0) prefix="20" ;;
        255.255.224.0) prefix="19" ;;
        255.255.192.0) prefix="18" ;;
        255.255.128.0) prefix="17" ;;
        255.255.0.0) prefix="16" ;;
        255.254.0.0) prefix="15" ;;
        255.252.0.0) prefix="14" ;;
        255.248.0.0) prefix="13" ;;
        255.240.0.0) prefix="12" ;;
        255.224.0.0) prefix="11" ;;
        255.192.0.0) prefix="10" ;;
        255.128.0.0) prefix="9" ;;
        255.0.0.0) prefix="8" ;;
        *) prefix="24" ;;
      esac
    else
      prefix="24"
    fi
    static_ip="${static_ip}/${prefix}"
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
  netplan generate
  netplan apply
}

# Outbound access needed by first boot (Ubuntu packages, Docker install, container images).
# Optional sites only produce a warning: the bundled dashboards are used on first boot and the
# Telegraf package can be fetched later from the landing page.
REQUIRED_SITES=(
  "http://archive.ubuntu.com/ubuntu/"
  "http://security.ubuntu.com/ubuntu/"
  "https://download.docker.com/linux/ubuntu/gpg"
  "https://registry-1.docker.io/v2/"
  "https://auth.docker.io/token"
)
OPTIONAL_SITES=(
  "https://api.github.com/repos/influxdata/telegraf/releases/latest"
)

# Fail fast with a clear console message when the appliance has no internet access, instead
# of failing partway through the Docker installation. Retries for up to 2 minutes while the
# network settles, showing progress on the console banner. Sites are probed in parallel with
# short timeouts, so even with an unreachable DNS server each attempt takes ~8 seconds.
# Any HTTP answer (even 401/404) counts as reachable.
probe_sites() {
  # Prints the unreachable sites (scheme://host), one per line.
  local dir="" site="" i=0
  dir="$(mktemp -d)"
  for site in "$@"; do
    ( curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 "${site}" > "${dir}/${i}" 2>/dev/null || true ) &
    i=$((i + 1))
  done
  wait
  i=0
  for site in "$@"; do
    [[ "$(cat "${dir}/${i}" 2>/dev/null)" =~ ^[1-5][0-9][0-9]$ ]] || echo "$(cut -d/ -f1-3 <<<"${site}")"
    i=$((i + 1))
  done
  rm -rf "${dir}"
}

check_internet_access() {
  local deadline=$(( $(date +%s) + 120 ))
  local attempt=0
  local failed=""
  local site=""

  while :; do
    attempt=$((attempt + 1))
    failed="$(probe_sites "${REQUIRED_SITES[@]}" | tr '\n' ' ' | sed 's/ $//')"
    [[ -z "${failed}" ]] && break
    echo "[firstboot] Internet check attempt ${attempt}: unreachable: ${failed}"
    (( $(date +%s) >= deadline )) && break
    write_issue_status "INITIALIZING" "Waiting for internet access (attempt ${attempt}, up to 2 minutes): cannot reach ${failed}"
    sleep 10
  done

  if [[ -n "${failed}" ]]; then
    get_runtime_network_details
    write_issue_status "FAILED" "No internet access: cannot reach ${failed}. First boot needs outbound HTTP/HTTPS (Ubuntu mirrors, Docker). Check gateway ${RUNTIME_GATEWAY}, DNS ${RUNTIME_DNS} and firewall/proxy rules, then reboot to retry (setup resumes automatically)."
    echo "[firstboot] ERROR: no internet access (${failed}); stopping before installation."
    exit 1
  fi
  echo "[firstboot] Internet check passed."
  write_issue_status "INITIALIZING" "Monitoring services setup is running. This can take 10-20 minutes."

  for site in $(probe_sites "${OPTIONAL_SITES[@]}"); do
    echo "[firstboot] WARN: optional site unreachable: ${site} (Telegraf package download will fail until it is reachable)."
  done
}

# Optional local override file (used by console-first setup).
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

# The dashboard URL used by post-install update flows is baked in at build time
# (${DASHBOARD_URL_CONFIG_FILE}); DASHBOARDS_ZIP_URL in config.env overrides it.
if [[ -n "${DASHBOARDS_ZIP_URL:-}" ]]; then
  printf '%s\n' "${DASHBOARDS_ZIP_URL}" > "${DASHBOARD_URL_CONFIG_FILE}"
  chmod 644 "${DASHBOARD_URL_CONFIG_FILE}"
fi

create_appliance_login
if [[ ! -f "${CONSOLE_CONFIG_MARKER}" ]]; then
  write_issue_status "PENDING-CONSOLE-CONFIG" "Log in on console to run the initial hostname/IP wizard."
  exit 0
fi

write_issue_status "INITIALIZING" "Monitoring services setup is running. This can take 10-20 minutes."
# Network first: the package installs below need the configured (static) address.
apply_hostname_config
apply_network_config
bootstrap_dhcp_network
check_internet_access
ensure_firstboot_prereqs
configure_ssh_access

configure_upgrade_timer() {
  if [[ "${AUTO_UPGRADE_ENABLED:-false}" == "true" ]]; then
    systemctl daemon-reload || true
    systemctl enable --now go-euc-upgrade.timer || true
    echo "[firstboot] Automatic upgrade timer enabled."
  else
    echo "[firstboot] Automatic upgrade timer disabled (set AUTO_UPGRADE_ENABLED=true to enable)."
  fi
}

configure_web_file_host() {
  mkdir -p "${PUBLIC_DIR}" "${NGINX_CONF_DIR}" "${NGINX_CERT_DIR}" "${NGINX_ACME_WEBROOT}" "${NGINX_AUTH_DIR}"
  write_web_auth
  # Local-subnet allow-list for /config.txt (network config has been applied by now).
  "${LOCAL_ACCESS_SCRIPT}" || true

  cat > "${TELEGRAF_REFRESH_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TELEGRAF_PUBLIC_DIR="/opt/influx-grafana/public/telegraf"
mkdir -p "${TELEGRAF_PUBLIC_DIR}"

resolve_latest_telegraf_windows_url() {
  local api_json=""
  local api_url=""
  local location=""
  local tag=""
  local version=""
  local candidate=""

  api_json="$(curl -fsSL -A "go-euc-appliance/1.0" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/influxdata/telegraf/releases/latest" || true)"
  if [[ -n "${api_json}" ]]; then
    api_url="$(
      printf '%s' "${api_json}" | python3 - <<'PY'
import json
import sys
payload = sys.stdin.read()
try:
    data = json.loads(payload)
except Exception:
    print("")
    raise SystemExit(0)
for asset in data.get("assets", []):
    name = str(asset.get("name", "")).lower()
    url = str(asset.get("browser_download_url", ""))
    if "windows_amd64" in name and name.endswith(".zip") and url:
        print(url)
        raise SystemExit(0)
print("")
PY
    )"
    if [[ -n "${api_url}" ]]; then
      printf '%s' "${api_url}"
      return 0
    fi
  fi

  location="$(
    curl -fsSLI -A "go-euc-appliance/1.0" "https://github.com/influxdata/telegraf/releases/latest" \
      | awk 'BEGIN{IGNORECASE=1} /^location:/ {print $2}' \
      | tr -d '\r' \
      | tail -n1
  )"
  tag="${location##*/}"
  version="${tag#v}"

  for candidate in \
    "https://github.com/influxdata/telegraf/releases/download/${tag}/telegraf-${version}_windows_amd64.zip" \
    "https://dl.influxdata.com/telegraf/releases/telegraf-${version}_windows_amd64.zip"
  do
    if [[ -n "${tag}" && -n "${version}" ]] && curl -fLSs -o /dev/null "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done

  return 1
}

download_url="$(resolve_latest_telegraf_windows_url || true)"

if [[ -z "${download_url}" ]]; then
  echo "Unable to resolve latest Telegraf windows_amd64 release asset URL." >&2
  exit 1
fi

output_pkg="${TELEGRAF_PUBLIC_DIR}/$(basename "${download_url}")"
tmp_pkg="$(mktemp /tmp/telegraf-windows-amd64-XXXXXX.zip)"

if ! curl -fLSs "${download_url}" -o "${tmp_pkg}"; then
  rm -f "${tmp_pkg}" || true
  echo "Failed to download ${download_url}" >&2
  exit 1
fi

install -m 0644 "${tmp_pkg}" "${output_pkg}"
rm -f "${tmp_pkg}" || true
cp -f "${output_pkg}" "${TELEGRAF_PUBLIC_DIR}/telegraf_windows_amd64_latest.zip" || true

python3 - "${output_pkg}" "${TELEGRAF_PUBLIC_DIR}/telegraf.exe" <<'PY'
import sys
import zipfile

zip_path = sys.argv[1]
exe_out = sys.argv[2]
member = None

with zipfile.ZipFile(zip_path) as zf:
    for name in zf.namelist():
        lower = name.lower()
        if lower.endswith("/telegraf.exe") or lower == "telegraf.exe":
            member = name
            break
    if member is None:
        raise RuntimeError("telegraf.exe not found in downloaded archive")
    with zf.open(member) as src, open(exe_out, "wb") as dst:
        dst.write(src.read())
PY

echo "Downloaded: ${output_pkg}"
echo "Extracted: ${TELEGRAF_PUBLIC_DIR}/telegraf.exe"
EOF
  chmod 755 "${TELEGRAF_REFRESH_SCRIPT}"

  cat > "${LE_RENEW_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/go-euc/config.env"
NGINX_CERT_DIR="/opt/influx-grafana/nginx/certs"
ACME_WEBROOT="/opt/influx-grafana/nginx/acme"
LETSENCRYPT_DOMAIN="${APPLIANCE_LETSENCRYPT_DOMAIN:-}"
LETSENCRYPT_EMAIL="${APPLIANCE_LETSENCRYPT_EMAIL:-}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
  LETSENCRYPT_DOMAIN="${APPLIANCE_LETSENCRYPT_DOMAIN:-${LETSENCRYPT_DOMAIN}}"
  LETSENCRYPT_EMAIL="${APPLIANCE_LETSENCRYPT_EMAIL:-${LETSENCRYPT_EMAIL}}"
fi

if [[ -z "${LETSENCRYPT_DOMAIN}" || -z "${LETSENCRYPT_EMAIL}" ]]; then
  cat <<MSG
Let's Encrypt not configured.
Set APPLIANCE_LETSENCRYPT_DOMAIN and APPLIANCE_LETSENCRYPT_EMAIL in /etc/go-euc/config.env.
MSG
  exit 1
fi

if ! command -v certbot >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y certbot
fi

mkdir -p "${NGINX_CERT_DIR}" "${ACME_WEBROOT}"

certbot certonly \
  --webroot -w "${ACME_WEBROOT}" \
  --domain "${LETSENCRYPT_DOMAIN}" \
  --email "${LETSENCRYPT_EMAIL}" \
  --agree-tos \
  --non-interactive \
  --keep-until-expiring

# Register the deploy hook so certbot.timer renewals are copied into nginx automatically.
DEPLOY_HOOK="/usr/local/bin/go-euc-letsencrypt-deploy-hook.sh"
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
ln -sf "${DEPLOY_HOOK}" /etc/letsencrypt/renewal-hooks/deploy/go-euc-nginx.sh
systemctl enable --now certbot.timer >/dev/null 2>&1 || true

# Apply the current certificate now (certbot skips hooks when nothing was renewed).
RENEWED_LINEAGE="/etc/letsencrypt/live/${LETSENCRYPT_DOMAIN}" "${DEPLOY_HOOK}"

echo "Let's Encrypt certificate is active for ${LETSENCRYPT_DOMAIN}."
EOF
  chmod 755 "${LE_RENEW_SCRIPT}"

  cat > "${NGINX_CERT_SETUP_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

NGINX_CERT_DIR="/opt/influx-grafana/nginx/certs"
CONFIG_FILE="/etc/go-euc/config.env"

mkdir -p "${NGINX_CERT_DIR}"

if [[ ! -s "${NGINX_CERT_DIR}/selfsigned.key" || ! -s "${NGINX_CERT_DIR}/selfsigned.crt" ]]; then
  CN="$(hostname -f 2>/dev/null || hostname)"
  openssl req -x509 -nodes -newkey rsa:4096 -days 825 \
    -subj "/CN=${CN}" \
    -keyout "${NGINX_CERT_DIR}/selfsigned.key" \
    -out "${NGINX_CERT_DIR}/selfsigned.crt"
fi

install -m 0644 "${NGINX_CERT_DIR}/selfsigned.crt" "${NGINX_CERT_DIR}/cert.pem"
install -m 0600 "${NGINX_CERT_DIR}/selfsigned.key" "${NGINX_CERT_DIR}/key.pem"

EOF
  chmod 755 "${NGINX_CERT_SETUP_SCRIPT}"

  cat > "${NGINX_CONF_DIR}/default.conf" <<'EOF'
# InfluxDB UI and API on InfluxDB's usual port, over TLS. Its web UI only works at the root
# of a host:port (it loads /<hash>.js and calls /api/v2), so it cannot live under /influx/.
server {
  listen 8086 ssl;
  listen [::]:8086 ssl;
  server_name _;

  ssl_certificate /etc/nginx/certs/cert.pem;
  ssl_certificate_key /etc/nginx/certs/key.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;
  # Telegraf batches and Proxmox Metric Server pushes (default max body 25 MB).
  client_max_body_size 32m;

  location / {
    proxy_pass http://influxdb:8086;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s;
  }
}

server {
  listen 80;
  listen [::]:80;
  server_name _;

  location ^~ /.well-known/acme-challenge/ {
    root /var/www/acme;
    default_type "text/plain";
  }

  location / {
    return 301 https://$host$request_uri;
  }
}

server {
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name _;

  ssl_certificate /etc/nginx/certs/cert.pem;
  ssl_certificate_key /etc/nginx/certs/key.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;

  location ^~ /.well-known/acme-challenge/ {
    root /var/www/acme;
    default_type "text/plain";
  }

  location /grafana/ {
    proxy_pass http://grafana:3000/grafana/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
  }

  # InfluxDB API under /influx (Telegraf clients, Proxmox Metric Server "API Path Prefix").
  # InfluxDB has no base-path option, so the prefix is stripped here (trailing slash on
  # proxy_pass). The web UI is on https://<appliance>:8086/ instead.
  location /influx/ {
    # Telegraf batches and Proxmox Metric Server pushes (default max body 25 MB) exceed nginx's 1 MB default.
    client_max_body_size 32m;
    proxy_pass http://influxdb:8086/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }

  # Portainer's --base-url only changes the links it generates; it still serves from its root,
  # so the /portainer prefix is stripped here. WebSocket headers are needed for container consoles.
  location /portainer/ {
    proxy_pass https://portainer:9443/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_ssl_verify off;
  }

  location = /goeucweb {
    return 301 /goeucweb/;
  }

  location /goeucweb/ {
    proxy_pass http://goeucweb:80/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }

  location /api/ {
    auth_basic "GO-EUC Appliance";
    auth_basic_user_file /etc/nginx/auth/htpasswd;
    # Full appliance updates can run for a long time; don't cut the browser off at 60s.
    proxy_read_timeout 7200s;
    proxy_send_timeout 7200s;
    # The API backend (go-euc-webfiles.py) has no login of its own: nginx reaches it only through
    # a Unix socket shared with this container, never over the network.
    proxy_pass http://unix:/run/go-euc/api.sock:/api/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }

  # config.txt contains appliance credentials: no login, but only for clients on the
  # appliance's local subnet(s). The allow-list is generated by go-euc-local-access.sh;
  # if it is missing, the glob matches nothing and everyone is denied.
  location = /config.txt {
    auth_basic off;
    include /etc/nginx/auth/local-subnets*.conf;
    deny all;
    root /usr/share/nginx/html;
    default_type text/plain;
  }

  location / {
    auth_basic "GO-EUC Appliance";
    auth_basic_user_file /etc/nginx/auth/htpasswd;
    root /usr/share/nginx/html;
    index index.html;
    try_files $uri $uri/ =404;
  }
}
EOF

  cat > "${PUBLIC_INDEX_FILE}" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>GO-EUC Appliance</title>
  <style>
    :root { --border: #d0d7de; --muted: #57606a; --bg: #f6f8fa; --accent: #0969da; --text: #1f2328; }
    * { box-sizing: border-box; }
    body { font-family: -apple-system, "Segoe UI", Arial, sans-serif; margin: 0; background: var(--bg); color: var(--text); line-height: 1.45; }
    header { background: #fff; border-bottom: 1px solid var(--border); padding: 1rem 2rem; }
    header h1 { margin: 0; font-size: 1.5rem; }
    header p { margin: 0.2rem 0 0.6rem; color: var(--muted); }
    nav a { color: var(--accent); text-decoration: none; margin-right: 1rem; font-size: 0.95rem; }
    nav a:hover { text-decoration: underline; }
    main { max-width: 1200px; margin: 0 auto; padding: 0.5rem 2rem 3rem; }
    section { margin-top: 1.75rem; scroll-margin-top: 1rem; }
    section > h2 { font-size: 1.15rem; margin: 0 0 0.2rem; }
    section > p.lead { color: var(--muted); margin: 0 0 0.75rem; max-width: 900px; }
    .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(250px, 1fr)); gap: 1rem; }
    .grid.wide { grid-template-columns: repeat(auto-fill, minmax(400px, 1fr)); }
    .card { background: #fff; border: 1px solid var(--border); border-radius: 8px; padding: 1rem; }
    .card h3 { margin: 0 0 0.35rem; font-size: 1.05rem; display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; }
    .card p { margin: 0.25rem 0; }
    a.tile { display: block; text-decoration: none; color: inherit; }
    a.tile:hover { border-color: var(--accent); }
    a.tile .go { color: var(--accent); font-weight: 600; }
    label { display: block; font-weight: 600; margin: 0.55rem 0 0.2rem; }
    label.check { font-weight: normal; display: flex; gap: 0.45rem; align-items: center; }
    input[type=text], input[type=email], input[type=password] { width: 100%; padding: 0.45rem 0.55rem; font-size: 1rem; border: 1px solid var(--border); border-radius: 6px; }
    button { padding: 0.5rem 0.9rem; font-size: 0.95rem; cursor: pointer; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); margin: 0.6rem 0.4rem 0 0; }
    button.primary { background: #1f883d; color: #fff; border-color: #1a7f37; }
    button:disabled { opacity: 0.6; cursor: wait; }
    .hint { color: var(--muted); font-size: 0.9rem; margin-top: 0.5rem; }
    .badge { font-size: 0.78rem; font-weight: 600; padding: 0.1rem 0.55rem; border-radius: 999px; border: 1px solid var(--border); background: var(--bg); color: var(--muted); }
    .badge.ok { background: #dafbe1; border-color: #4ac26b; color: #116329; }
    .badge.err { background: #ffebe9; border-color: #ff8182; color: #a40e26; }
    pre { background: #0d1117; color: #e6edf3; padding: 1rem; border-radius: 8px; white-space: pre-wrap; max-height: 460px; overflow: auto; margin: 0.5rem 0 0; }
    pre.cmd { background: var(--bg); color: var(--text); border: 1px solid var(--border); font-size: 0.82rem; padding: 0.6rem; word-break: break-all; }
    details { margin-top: 0.9rem; border-top: 1px solid var(--border); padding-top: 0.6rem; }
    summary { cursor: pointer; font-weight: 600; }
    table.kv { border-collapse: collapse; font-size: 0.88rem; margin-top: 0.4rem; width: 100%; }
    table.kv td { border-top: 1px solid var(--border); padding: 0.25rem 0.4rem; vertical-align: top; word-break: break-all; }
    table.kv td:first-child { color: var(--muted); white-space: nowrap; width: 1%; }
  </style>
</head>
<body>
  <header>
    <h1>GO-EUC Appliance</h1>
    <p>Performance monitoring for EUC testing: InfluxDB, Grafana and Telegraf collectors.</p>
    <nav>
      <a href="#services">Services</a>
      <a href="#collectors">Infrastructure collectors</a>
      <a href="#telegraf">Telegraf for Windows</a>
      <a href="#maintenance">Maintenance</a>
      <a href="#certificates">Certificates</a>
      <a href="#activity">Activity</a>
    </nav>
  </header>
  <main>
    <section id="services">
      <h2>Services</h2>
      <div class="grid">
        <a class="card tile" href="/grafana/">
          <h3>Grafana</h3>
          <p>Dashboards for test runs and realtime performance.</p>
          <span class="go">Open &rarr;</span>
        </a>
        <a class="card tile" id="influxTile" href="/influx/">
          <h3>InfluxDB</h3>
          <p>Time-series database (Performance, Tests and Proxmox buckets), on port 8086.</p>
          <span class="go">Open &rarr;</span>
        </a>
        <a class="card tile" href="/portainer/">
          <h3>Portainer</h3>
          <p>Manage the appliance's containers, including the collectors.</p>
          <span class="go">Open &rarr;</span>
        </a>
        <a class="card tile" href="/goeucweb/">
          <h3>GO-EUC Web</h3>
          <p>GO-EUC web content container used by workloads.</p>
          <span class="go">Open &rarr;</span>
        </a>
        <a class="card tile" href="/config.txt">
          <h3>config.txt</h3>
          <p>Endpoints and credentials. Opens from the appliance's local subnet only.</p>
          <span class="go">View &rarr;</span>
        </a>
      </div>
    </section>

    <section id="collectors">
      <h2>Infrastructure collectors</h2>
      <p class="lead">Telegraf containers on this appliance that collect hypervisor metrics into the Performance bucket. Each collector is started, changed or stopped independently, and also appears in Portainer. Passwords are stored root-only on the appliance; leave the password blank to keep the saved one. Starting takes about a minute while the first collection is checked.</p>
      <div class="grid wide">
        <div class="card collector" data-collector="vsphere">
          <h3>VMware vSphere <span class="badge" data-role="badge">loading</span></h3>
          <p class="hint" data-role="status">Loading status...</p>
          <form>
            <label for="vsphereAddress">vCenter address</label>
            <input id="vsphereAddress" name="address" type="text" placeholder="vcenter.lab.local" required>
            <label for="vsphereUsername">Username</label>
            <input id="vsphereUsername" name="username" type="text" placeholder="svc-telegraf@vsphere.local" autocomplete="off" required>
            <label for="vspherePassword">Password</label>
            <input id="vspherePassword" name="password" type="password" autocomplete="new-password">
            <label class="check"><input name="verify_tls" type="checkbox"> Verify the vCenter TLS certificate</label>
            <button class="primary" type="submit">Save and Start</button>
            <button type="button" data-role="stop">Stop</button>
            <div class="hint">VM and host metrics every 20 s; cluster, datastore and datacenter metrics every 5 minutes. A read-only vCenter account is enough.</div>
          </form>
        </div>
        <div class="card collector" data-collector="nutanix">
          <h3>Nutanix Prism Element <span class="badge" data-role="badge">loading</span></h3>
          <p class="hint" data-role="status">Loading status...</p>
          <form>
            <label for="nutanixAddress">Prism Element address (cluster virtual IP)</label>
            <input id="nutanixAddress" name="address" type="text" placeholder="ntnx-cluster.lab.local or 10.0.0.5:9440" required>
            <label for="nutanixUsername">Prism Element username</label>
            <input id="nutanixUsername" name="username" type="text" placeholder="monitoring" autocomplete="off" required>
            <label for="nutanixPassword">Prism Element password</label>
            <input id="nutanixPassword" name="password" type="password" autocomplete="new-password">
            <label class="check"><input name="verify_tls" type="checkbox"> Verify the Prism Element TLS certificate</label>
            <button class="primary" type="submit">Save and Start</button>
            <button type="button" data-role="stop">Stop</button>
            <div class="hint">Connects to <b>Prism Element</b> on the cluster (its virtual IP or name), <b>not Prism Central</b>: host metrics come from the Prism Element v2.0 API (<code>/api/nutanix/v2.0/hosts/</code>) every 5 s, one series per host. For several clusters, each needs its own Prism Element address. Port 9440 is used when none is given. A read-only Prism Element account (Viewer role) is enough.</div>
          </form>
        </div>
        <div class="card collector" data-collector="proxmox">
          <h3>Proxmox VE <span class="badge" data-role="badge">loading</span></h3>
          <p class="hint" data-role="status">Loading status...</p>
          <form>
            <label for="proxmoxAddress">Proxmox address</label>
            <input id="proxmoxAddress" name="address" type="text" placeholder="pve.lab.local or 10.0.0.6:8006" required>
            <label for="proxmoxUsername">API token ID</label>
            <input id="proxmoxUsername" name="username" type="text" placeholder="telegraf@pve!monitoring" autocomplete="off" required>
            <label for="proxmoxPassword">API token secret</label>
            <input id="proxmoxPassword" name="password" type="password" autocomplete="new-password">
            <label class="check"><input name="verify_tls" type="checkbox"> Verify the Proxmox TLS certificate</label>
            <button class="primary" type="submit">Save and Start</button>
            <button type="button" data-role="stop">Stop</button>
            <div class="hint">Every node in the cluster is found automatically (save again or run a full update after adding nodes). Collects per-VM/LXC stats, node status, 1-minute node history (network, pressure stalls), cluster resources including storage, and quorum. Port 8006 is used when none is given. Create a read-only token on any node with:</div>
            <pre class="cmd">pveum user add telegraf@pve
pveum acl modify / -role PVEAuditor -user telegraf@pve
pveum user token add telegraf@pve monitoring -privsep 1
pveum acl modify / -role PVEAuditor -token 'telegraf@pve!monitoring'</pre>
          </form>
          <details>
            <summary>Also push Proxmox's own metrics (Metric Server)</summary>
            <p class="hint">Proxmox VE can send its built-in metrics straight to this appliance, alongside the collector. They are stored in the separate <b>Proxmox</b> bucket. In Proxmox: Datacenter &rarr; Metric Server &rarr; Add &rarr; InfluxDB, with:</p>
            <table class="kv" id="proxmoxPushTable"></table>
            <p class="hint">Or run this on any Proxmox node:</p>
            <pre class="cmd" id="proxmoxPushCmd">Loading...</pre>
          </details>
        </div>
      </div>
    </section>

    <section id="telegraf">
      <h2>Telegraf for Windows</h2>
      <p class="lead">Telegraf package and ready-made configs (pre-filled with this appliance's InfluxDB address and a write-only token) for Windows machines under test.</p>
      <div class="grid wide">
        <div class="card">
          <h3>Downloads</h3>
          <p><a href="/telegraf/">Browse /telegraf/</a>: Telegraf package, <code>telegraf.exe</code>, <code>telegraf.conf</code>, <code>telegraf_vsphere.conf</code>, <code>telegraf_nutanix.conf</code>, <code>telegraf_proxmox.conf</code></p>
          <p><a href="/telegraf/WINDOWS_INSTALL.html">Windows install guide</a></p>
        </div>
        <div class="card">
          <h3>Telegraf package</h3>
          <p>Download the latest Telegraf Windows x64 release into <code>/telegraf/</code>.</p>
          <button id="refreshBtn" type="button">Fetch latest Telegraf package</button>
        </div>
      </div>
    </section>

    <section id="maintenance">
      <h2>Maintenance</h2>
      <div class="card">
        <h3>Full appliance update</h3>
        <p>Updates Ubuntu packages, refreshes the pinned container images (InfluxDB, Grafana, Portainer, GO-EUC Web, nginx and any enabled collectors), reloads the dashboard bundle, refreshes the Telegraf package and configs, and updates the local-subnet access list. This can take a while.</p>
        <button id="fullUpdateBtn" type="button">Run Full Appliance Update</button>
      </div>
    </section>

    <section id="certificates">
      <h2>Certificates</h2>
      <p class="lead">The appliance starts with a self-signed certificate. With a public DNS name pointing at it, a Let's Encrypt certificate can replace it; renewals then happen automatically.</p>
      <div class="grid wide">
        <div class="card">
          <h3>Let's Encrypt setup</h3>
          <form id="letsencryptForm">
            <label for="leDomain">Domain (public DNS)</label>
            <input id="leDomain" name="domain" type="text" placeholder="appliance.example.com" required>
            <label for="leEmail">Email</label>
            <input id="leEmail" name="email" type="email" placeholder="admin@example.com" required>
            <button id="saveLeBtn" class="primary" type="submit">Save and Request Certificate</button>
            <div class="hint">Saves the values into the appliance config, then immediately requests and applies the certificate.</div>
          </form>
        </div>
        <div class="card">
          <h3>Renew now</h3>
          <p>Force a renewal check for the configured Let's Encrypt certificate.</p>
          <button id="renewLeBtn" type="button">Renew Let's Encrypt Certificate</button>
        </div>
      </div>
    </section>

    <section id="activity">
      <h2>Activity</h2>
      <p id="status" class="hint">Results of actions on this page appear here.</p>
      <pre id="output">No actions run yet.</pre>
    </section>
  </main>
  <script>
    const status = document.getElementById('status');
    const output = document.getElementById('output');
    // InfluxDB's UI runs on its own port (it cannot be served under /influx/).
    document.getElementById('influxTile').href = `https://${location.hostname}:8086/`;
    const activity = document.getElementById('activity');

    function setBusyState(disabled) {
      document.querySelectorAll('button').forEach((button) => { button.disabled = disabled; });
    }

    // Run an API call, show its result in the Activity panel and return the parsed response.
    async function runAction(startMessage, url, options, describe) {
      setBusyState(true);
      status.textContent = startMessage;
      output.textContent = '';
      activity.scrollIntoView({ behavior: 'smooth', block: 'start' });
      try {
        const res = await fetch(url, Object.assign({ method: 'POST' }, options || {}));
        const isJson = (res.headers.get('Content-Type') || '').includes('application/json');
        const payload = isJson ? await res.json() : { output: await res.text() };
        output.textContent = payload.output || payload.message || '';
        status.textContent = describe(res, payload);
        return { res, payload };
      } catch (err) {
        status.textContent = 'Request failed.';
        output.textContent = String(err);
        return null;
      } finally {
        setBusyState(false);
      }
    }

    document.getElementById('refreshBtn').addEventListener('click', () => runAction(
      'Fetching the latest Telegraf Windows package...', '/api/refresh-telegraf', null,
      (res) => res.ok ? 'Telegraf package refreshed.' : 'Telegraf package refresh returned an error.'));

    document.getElementById('fullUpdateBtn').addEventListener('click', () => runAction(
      'Running full appliance update (this can take a while)...', '/api/full-update', null,
      (res) => res.ok ? 'Full update completed.' : 'Full update returned an error.'));

    document.getElementById('renewLeBtn').addEventListener('click', () => runAction(
      "Renewing Let's Encrypt certificate...", '/api/renew-letsencrypt', null,
      (res, payload) => payload.message || (res.ok ? 'Certificate renewal completed.' : 'Certificate renewal returned an error.')));

    document.getElementById('letsencryptForm').addEventListener('submit', (event) => {
      event.preventDefault();
      const form = event.target;
      const domain = form.elements.domain.value.trim().toLowerCase();
      const email = form.elements.email.value.trim();
      runAction("Saving Let's Encrypt settings and requesting certificate...", '/api/configure-letsencrypt', {
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ domain, email })
      }, (res, payload) => res.ok ? `Certificate applied for ${payload.domain}.` : (payload.message || 'Certificate request returned an error.'));
    });

    // Infrastructure collectors: one card per collector type, all using /api/collectors/<type>/...
    function setBadge(badge, text, kind) {
      badge.textContent = text;
      badge.className = 'badge' + (kind ? ' ' + kind : '');
    }

    async function loadCollector(card) {
      const type = card.dataset.collector;
      const form = card.querySelector('form');
      const statusLine = card.querySelector('[data-role=status]');
      const badge = card.querySelector('[data-role=badge]');
      try {
        const res = await fetch(`/api/collectors/${type}/status`, { cache: 'no-store' });
        const s = await res.json();
        if (!s.configured) {
          setBadge(badge, 'not configured', '');
          statusLine.textContent = 'Not configured yet.';
          form.elements.password.placeholder = '';
          return;
        }
        if (s.container_status === 'running') {
          setBadge(badge, 'running', 'ok');
        } else if (s.enabled) {
          setBadge(badge, s.container_status, 'err');
        } else {
          setBadge(badge, 'stopped', '');
        }
        statusLine.textContent = `${s.address} as ${s.username} - container ${s.container} (${s.container_status})`;
        form.elements.address.value = s.address;
        form.elements.username.value = s.username;
        form.elements.verify_tls.checked = Boolean(s.verify_tls);
        form.elements.password.placeholder = s.password_set ? 'Saved - leave blank to keep' : '';
      } catch (err) {
        setBadge(badge, 'unknown', 'err');
        statusLine.textContent = 'Unable to load collector status.';
      }
    }

    // Proxmox VE Metric Server (push) settings for this appliance.
    async function loadProxmoxPush() {
      const table = document.getElementById('proxmoxPushTable');
      const cmd = document.getElementById('proxmoxPushCmd');
      try {
        const res = await fetch('/api/proxmox-metric-server', { cache: 'no-store' });
        const s = await res.json();
        const rows = [
          ['Server', s.server], ['Port', String(s.port)], ['Protocol', 'HTTPS'],
          ['Organization', s.organization], ['Bucket', s.bucket], ['Token', s.token || '(not available)'],
          ['API Path Prefix (Advanced)', s.api_path_prefix],
          ['Verify Certificate (Advanced)', s.verify_certificate ? 'Yes' : 'No (self-signed certificate)']
        ];
        table.textContent = '';
        rows.forEach(([key, value]) => {
          const tr = table.insertRow();
          tr.insertCell().textContent = key;
          tr.insertCell().textContent = value;
        });
        cmd.textContent = `pvesh create /cluster/metrics/server/goeuc --type influxdb --server ${s.server} --port ${s.port} ` +
          `--influxdbproto https --api-path-prefix ${s.api_path_prefix} --organization ${s.organization} ` +
          `--bucket ${s.bucket} --token ${s.token} --verify-certificate ${s.verify_certificate ? 1 : 0}`;
      } catch (err) {
        cmd.textContent = 'Unable to load Metric Server settings.';
      }
    }
    loadProxmoxPush();

    document.querySelectorAll('.collector').forEach((card) => {
      const type = card.dataset.collector;
      const label = card.querySelector('h3').firstChild.textContent.trim();
      const form = card.querySelector('form');

      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        const result = await runAction(`Saving ${label} settings and starting the collector (about a minute)...`,
          `/api/collectors/${type}/configure`, {
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              address: form.elements.address.value.trim(),
              username: form.elements.username.value.trim(),
              password: form.elements.password.value,
              verify_tls: form.elements.verify_tls.checked
            })
          }, (res, payload) => payload.message || (res.ok ? `${label} collector started.` : `${label} collector returned an error.`));
        if (result && result.res.ok) form.elements.password.value = '';
        loadCollector(card);
      });

      card.querySelector('[data-role=stop]').addEventListener('click', async () => {
        await runAction(`Stopping the ${label} collector...`, `/api/collectors/${type}/disable`, null,
          (res, payload) => payload.message || (res.ok ? `${label} collector stopped.` : `Failed to stop the ${label} collector.`));
        loadCollector(card);
      });

      loadCollector(card);
    });
  </script>
</body>
</html>
EOF
  chmod 644 "${PUBLIC_INDEX_FILE}"
  "${NGINX_CERT_SETUP_SCRIPT}" || true

  systemctl daemon-reload || true
  systemctl enable --now go-euc-webfiles.service || true
}

publish_telegraf_files() {
  local install_md_source="${TELEGRAF_SOURCE_DIR}/WINDOWS_INSTALL.md"
  local install_md_dest="${TELEGRAF_PUBLIC_DIR}/WINDOWS_INSTALL.md"
  local install_html_dest="${TELEGRAF_PUBLIC_DIR}/WINDOWS_INSTALL.html"

  mkdir -p "${TELEGRAF_PUBLIC_DIR}"

  if [[ -f "${install_md_source}" ]]; then
    cp -f "${install_md_source}" "${install_md_dest}"
    chmod 644 "${install_md_dest}" || true

    cat > "${install_html_dest}" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Telegraf Windows Install</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 2rem; line-height: 1.6; max-width: 1000px; }
    .links a { display: inline-block; margin-right: 1rem; }
    pre { background: #f6f8fa; padding: 1rem; border: 1px solid #d0d7de; border-radius: 6px; overflow: auto; }
    code { background: #f6f8fa; padding: 0.1rem 0.25rem; border-radius: 4px; }
    h1, h2, h3 { margin-top: 1.5rem; }
  </style>
</head>
<body>
  <h1>Telegraf Windows Install</h1>
  <p class="links">
    <a href="/telegraf/">Back to /telegraf/</a>
    <a href="/telegraf/WINDOWS_INSTALL.md">Raw markdown</a>
  </p>
  <div id="content">Loading documentation...</div>
  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
  <script>
    (async () => {
      const content = document.getElementById('content');
      try {
        const res = await fetch('/telegraf/WINDOWS_INSTALL.md', { cache: 'no-store' });
        const md = await res.text();
        if (window.marked && typeof window.marked.parse === 'function') {
          content.innerHTML = window.marked.parse(md);
        } else {
          content.innerHTML = '<pre></pre>';
          content.querySelector('pre').textContent = md;
        }
      } catch (err) {
        content.innerHTML = '<pre></pre>';
        content.querySelector('pre').textContent = String(err);
      }
    })();
  </script>
</body>
</html>
EOF
    chmod 644 "${install_html_dest}" || true
  fi

  # Render telegraf.conf / telegraf_vsphere.conf with org, URL, write-only token and TLS mode.
  "${TELEGRAF_PUBLISH_SCRIPT}" || true

  "${TELEGRAF_REFRESH_SCRIPT}" || true
}

configure_upgrade_timer
configure_web_file_host

# In appliance mode first boot uses the baked-in dashboard bundle.
INSTALLER_DASHBOARDS_ZIP_URL=""
if [[ -f "${LOCAL_DASHBOARD_ZIP}" ]]; then
  INSTALLER_DASHBOARDS_ZIP_URL="file://${LOCAL_DASHBOARD_ZIP}"
fi

if [[ ! -x "${INSTALLER}" ]]; then
  chmod +x "${INSTALLER}"
fi

# Service overrides from config.env (see config.env.example) are plain shell variables here;
# export the ones that are set so the installer (a separate process) actually receives them.
for override in PORTAINER_ADMIN_USER PORTAINER_ADMIN_PASSWORD INFLUX_ADMIN_USER INFLUX_ADMIN_PASSWORD \
  INFLUX_ADMIN_ORG INFLUX_INIT_BUCKET GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD; do
  if [[ -n "${!override:-}" ]]; then
    export "${override?}"
  fi
done

# The install log contains generated credentials: keep it root-only.
install -m 600 /dev/null "${LOG_FILE}"
DASHBOARDS_ZIP_URL="${INSTALLER_DASHBOARDS_ZIP_URL}" "${INSTALLER}" | tee "${LOG_FILE}"
add_login_user_to_docker_group
"${LE_RENEW_SCRIPT}" auto || true
publish_final_summary

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${MARKER_FILE}"
