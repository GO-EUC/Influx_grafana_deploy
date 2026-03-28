#!/usr/bin/env bash

set -eEuo pipefail

MARKER_FILE="/var/lib/go-euc/.installed"
CONFIG_FILE="/etc/go-euc/config.env"
REMOTE_DASHBOARDS_ZIP_URL="https://goeucartifacts4hiu9i.blob.core.windows.net/files/Dashboards.zip"
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
PUBLIC_CONFIG_FILE="${PUBLIC_DIR}/config.txt"
PUBLIC_INDEX_FILE="${PUBLIC_DIR}/index.html"
CONSOLE_CONFIG_MARKER="/var/lib/go-euc/console-config.done"
TELEGRAF_SOURCE_DIR="/opt/go-euc-installer/Telegraf"
TELEGRAF_PUBLIC_DIR="${PUBLIC_DIR}/telegraf"
TELEGRAF_REFRESH_SCRIPT="/usr/local/bin/go-euc-refresh-telegraf.sh"
LE_RENEW_SCRIPT="/usr/local/bin/go-euc-renew-letsencrypt.sh"
NGINX_CERT_SETUP_SCRIPT="/usr/local/bin/go-euc-nginx-cert-setup.sh"
NGINX_DIR="${INSTALL_ROOT}/nginx"
NGINX_CONF_DIR="${NGINX_DIR}/conf.d"
NGINX_CERT_DIR="${NGINX_DIR}/certs"
NGINX_ACME_WEBROOT="${NGINX_DIR}/acme"

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

create_appliance_login() {
  APPLIANCE_LOGIN_USER_RESOLVED="${APPLIANCE_LOGIN_USER:-goeucadmin}"
  APPLIANCE_LOGIN_PASSWORD_RESOLVED="${APPLIANCE_LOGIN_PASSWORD:-goeucadmin}"
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

configure_ssh_access() {
  if ! command -v sshd >/dev/null 2>&1; then
    return 0
  fi

  # Ensure password-based SSH works for break-glass and appliance users.
  sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
  if ! grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config; then
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
  fi
  sed -i 's/^[#[:space:]]*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config || true
  if ! grep -q '^UsePAM yes' /etc/ssh/sshd_config; then
    echo 'UsePAM yes' >> /etc/ssh/sshd_config
  fi

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
  URL:      https://${host_ip}/portainer/
  Username: ${saved_portainer_user}
  Password: ${saved_portainer_password}

GO-EUC Web
  URL:      https://${host_ip}/goeucweb/

InfluxDB
  URL:      https://${host_ip}/influx/
  Username: ${saved_influx_user}
  Password: ${saved_influx_password}
  Org:      ${saved_influx_org}

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

  # Keep credentials and runtime network details visible at login prompt.
  local net_info=""
  get_runtime_network_details
  net_info="Setup complete. Hostname=${RUNTIME_HOSTNAME}, Interface=${RUNTIME_IFACE}, IP=${RUNTIME_IP}, Gateway=${RUNTIME_GATEWAY}, DNS=${RUNTIME_DNS}"
  write_issue_status "COMPLETE" "${net_info}"
  cat "${SUMMARY_FILE}" >> "${LOGIN_BANNER_FILE}"

  publish_telegraf_files "${host_ip}" "${saved_influx_org}" "${saved_influx_token}"

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
InfluxURL=https://${host_ip}/influx/
PortainerURL=https://${host_ip}/portainer/
GoeucWebURL=https://${host_ip}/goeucweb/
GrafanaDirectURL=http://${host_ip}:3000/grafana/
InfluxDirectURL=http://${host_ip}:8086/influx/
PortainerDirectURL=https://${host_ip}:9443
GrafanaPort=3000
InfluxPort=8086
PortainerPort=9443
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

Grafana
Username=${saved_grafana_user}
Password=${saved_grafana_password}

Telegraf
PackageFolder=${TELEGRAF_PUBLIC_DIR}
InfluxURL=https://${host_ip}/influx
InfluxOrg=${saved_influx_org}
InfluxToken=${saved_influx_token}
EOF
  chmod 644 "${PUBLIC_CONFIG_FILE}"
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

# Optional local override file (used by console-first setup).
if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
fi

# Persist source dashboard URL for post-install update flows.
echo "${REMOTE_DASHBOARDS_ZIP_URL}" > /etc/go-euc/dashboard-url
chmod 644 /etc/go-euc/dashboard-url

create_appliance_login
if [[ ! -f "${CONSOLE_CONFIG_MARKER}" ]]; then
  write_issue_status "PENDING-CONSOLE-CONFIG" "Log in on console to run the initial hostname/IP wizard."
  exit 0
fi

write_issue_status "INITIALIZING" "Monitoring services setup is running. This can take 10-20 minutes."
bootstrap_dhcp_network
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
  mkdir -p "${PUBLIC_DIR}" "${NGINX_CONF_DIR}" "${NGINX_CERT_DIR}" "${NGINX_ACME_WEBROOT}"

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

install -m 0644 "/etc/letsencrypt/live/${LETSENCRYPT_DOMAIN}/fullchain.pem" "${NGINX_CERT_DIR}/letsencrypt.crt"
install -m 0600 "/etc/letsencrypt/live/${LETSENCRYPT_DOMAIN}/privkey.pem" "${NGINX_CERT_DIR}/letsencrypt.key"
ln -sfn "${NGINX_CERT_DIR}/letsencrypt.crt" "${NGINX_CERT_DIR}/cert.pem"
ln -sfn "${NGINX_CERT_DIR}/letsencrypt.key" "${NGINX_CERT_DIR}/key.pem"

if docker ps --format '{{.Names}}' | grep -q '^goeuc-nginx$'; then
  docker exec goeuc-nginx nginx -s reload >/dev/null 2>&1 || true
fi

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

ln -sfn "${NGINX_CERT_DIR}/selfsigned.crt" "${NGINX_CERT_DIR}/cert.pem"
ln -sfn "${NGINX_CERT_DIR}/selfsigned.key" "${NGINX_CERT_DIR}/key.pem"

EOF
  chmod 755 "${NGINX_CERT_SETUP_SCRIPT}"

  cat > "${NGINX_CONF_DIR}/default.conf" <<'EOF'
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

  location /influx/ {
    proxy_pass http://influxdb:8086/influx/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Prefix /influx;
  }

  location /portainer/ {
    proxy_pass https://portainer:9443/portainer/;
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
    proxy_pass http://host.docker.internal:18080/api/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
  }

  location / {
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
  <title>GO-EUC Appliance Files</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 2rem; line-height: 1.4; }
    button { padding: 0.6rem 1rem; font-size: 1rem; cursor: pointer; }
    input { padding: 0.45rem 0.55rem; font-size: 1rem; min-width: 320px; max-width: 100%; }
    label { display: inline-block; margin-top: 0.4rem; margin-bottom: 0.2rem; font-weight: 600; }
    pre { background: #f6f8fa; padding: 1rem; border: 1px solid #d0d7de; border-radius: 6px; white-space: pre-wrap; }
    .links a { display: inline-block; margin: 0.2rem 0.6rem 0.2rem 0; }
    .card { border: 1px solid #d0d7de; border-radius: 8px; padding: 1rem; margin: 1rem 0; background: #fff; max-width: 900px; }
    .form-row { margin-bottom: 0.5rem; }
    .hint { color: #57606a; font-size: 0.95rem; margin-top: 0.5rem; }
  </style>
</head>
<body>
  <h1>GO-EUC Appliance</h1>
  <p class="links">
    <a href="/grafana/">Open Grafana</a>
    <a href="/influx/">Open InfluxDB</a>
    <a href="/portainer/">Open Portainer</a>
    <a href="/goeucweb/">Open GO-EUC Web</a>
    <a href="/telegraf/">Browse /telegraf/</a>
    <a href="/config.txt">View config.txt</a>
  </p>
  <button id="refreshBtn" type="button">Fetch latest Telegraf Windows package</button>
  <button id="fullUpdateBtn" type="button">Run Full Appliance Update</button>
  <button id="renewLeBtn" type="button">Renew Let's Encrypt Certificate</button>
  <div class="card">
    <h2>Let's Encrypt Setup</h2>
    <form id="letsencryptForm">
      <div class="form-row">
        <label for="leDomain">Domain (public DNS)</label><br>
        <input id="leDomain" name="domain" type="text" placeholder="appliance.example.com" required>
      </div>
      <div class="form-row">
        <label for="leEmail">Email</label><br>
        <input id="leEmail" name="email" type="email" placeholder="admin@example.com" required>
      </div>
      <button id="saveLeBtn" type="submit">Save and Request Certificate</button>
      <div class="hint">This saves values into appliance config, then immediately requests and applies the cert.</div>
    </form>
  </div>
  <p id="status"></p>
  <pre id="output">Click the button to fetch/update Telegraf package and telegraf.exe.</pre>
  <script>
    const btn = document.getElementById('refreshBtn');
    const fullUpdateBtn = document.getElementById('fullUpdateBtn');
    const renewLeBtn = document.getElementById('renewLeBtn');
    const saveLeBtn = document.getElementById('saveLeBtn');
    const letsencryptForm = document.getElementById('letsencryptForm');
    const leDomain = document.getElementById('leDomain');
    const leEmail = document.getElementById('leEmail');
    const status = document.getElementById('status');
    const output = document.getElementById('output');
    const allButtons = [btn, fullUpdateBtn, renewLeBtn, saveLeBtn];

    function setBusyState(disabled) {
      allButtons.forEach((button) => {
        if (button) button.disabled = disabled;
      });
    }

    btn.addEventListener('click', async () => {
      setBusyState(true);
      status.textContent = 'Refreshing package...';
      output.textContent = '';
      try {
        const res = await fetch('/api/refresh-telegraf', { method: 'POST' });
        output.textContent = await res.text();
        status.textContent = res.ok ? 'Refresh request completed.' : 'Refresh request returned an error.';
      } catch (err) {
        status.textContent = 'Refresh request failed.';
        output.textContent = String(err);
      } finally {
        setBusyState(false);
      }
    });

    fullUpdateBtn.addEventListener('click', async () => {
      setBusyState(true);
      status.textContent = 'Running full appliance update (this can take a while)...';
      output.textContent = '';
      try {
        const res = await fetch('/api/full-update', { method: 'POST' });
        output.textContent = await res.text();
        status.textContent = res.ok ? 'Full update completed.' : 'Full update returned an error.';
      } catch (err) {
        status.textContent = 'Full update request failed.';
        output.textContent = String(err);
      } finally {
        setBusyState(false);
      }
    });

    renewLeBtn.addEventListener('click', async () => {
      setBusyState(true);
      status.textContent = "Renewing Let's Encrypt certificate...";
      output.textContent = '';
      try {
        const res = await fetch('/api/renew-letsencrypt', { method: 'POST' });
        const payload = await res.json();
        output.textContent = payload.output || payload.message || '';
        status.textContent = res.ok ? 'Certificate renewal completed.' : 'Certificate renewal returned an error.';
      } catch (err) {
        status.textContent = 'Certificate renewal request failed.';
        output.textContent = String(err);
      } finally {
        setBusyState(false);
      }
    });

    letsencryptForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      const domain = leDomain.value.trim().toLowerCase();
      const email = leEmail.value.trim();
      if (!domain || !email) {
        status.textContent = 'Domain and email are required.';
        return;
      }

      setBusyState(true);
      status.textContent = "Saving Let's Encrypt settings and requesting certificate...";
      output.textContent = '';
      try {
        const res = await fetch('/api/configure-letsencrypt', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ domain, email })
        });
        const payload = await res.json();
        output.textContent = payload.output || payload.message || '';
        status.textContent = res.ok
          ? `Certificate applied for ${payload.domain}.`
          : (payload.message || 'Certificate request/apply returned an error.');
      } catch (err) {
        status.textContent = 'Certificate setup request failed.';
        output.textContent = String(err);
      } finally {
        setBusyState(false);
      }
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
  local host_ip="$1"
  local influx_org="$2"
  local influx_token="$3"
  local telegraf_url="https://${host_ip}/influx"
  local conf_file=""
  local install_md_source="${TELEGRAF_SOURCE_DIR}/WINDOWS_INSTALL.md"
  local install_md_dest="${TELEGRAF_PUBLIC_DIR}/WINDOWS_INSTALL.md"
  local install_html_dest="${TELEGRAF_PUBLIC_DIR}/WINDOWS_INSTALL.html"

  mkdir -p "${TELEGRAF_PUBLIC_DIR}"

  if [[ -d "${TELEGRAF_SOURCE_DIR}" ]]; then
    cp -f "${TELEGRAF_SOURCE_DIR}"/*.conf "${TELEGRAF_PUBLIC_DIR}/" 2>/dev/null || true
  fi

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

  for conf_file in "${TELEGRAF_PUBLIC_DIR}"/*.conf; do
    [[ -f "${conf_file}" ]] || continue
    sed -i \
      -e "s|<<TELEGRAF_ORGANISATION>>|${influx_org}|g" \
      -e "s|<<TELEGRAF_URL>>|${telegraf_url}|g" \
      -e "s|<<TELEGRAF_TOKEN>>|${influx_token}|g" \
      -e "s|<<TELEGRAG_TOKEN>>|${influx_token}|g" \
      "${conf_file}" || true
  done

  "${TELEGRAF_REFRESH_SCRIPT}" || true
}

apply_hostname_config
apply_network_config
configure_upgrade_timer
configure_web_file_host

# In appliance mode we always use the baked-in dashboard bundle.
if [[ -f "${INSTALLER}" && -f "${LOCAL_DASHBOARD_ZIP}" ]]; then
  sed -i 's|^DASHBOARDS_ZIP_URL=.*|DASHBOARDS_ZIP_URL="file:///opt/go-euc-installer/Dashboards.zip"|' "${INSTALLER}"
fi

if [[ ! -x "${INSTALLER}" ]]; then
  chmod +x "${INSTALLER}"
fi

"${INSTALLER}" | tee "${LOG_FILE}"
add_login_user_to_docker_group
"${LE_RENEW_SCRIPT}" auto || true
publish_final_summary

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${MARKER_FILE}"
