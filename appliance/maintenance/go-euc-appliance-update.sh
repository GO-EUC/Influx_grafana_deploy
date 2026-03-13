#!/usr/bin/env bash

set -euo pipefail

LOG_FILE="/var/log/go-euc-appliance-update.log"
LOCK_FILE="/var/lock/go-euc-appliance-update.lock"
INSTALL_ROOT="/opt/influx-grafana"
STACK_DIR="${INSTALL_ROOT}/stack"
DASHBOARDS_DIR="${STACK_DIR}/grafana/dashboards"
DASHBOARDS_URL_DEFAULT="https://goeucartifacts4hiu9i.blob.core.windows.net/files/Dashboards.zip"
REFRESH_TELEGRAF_SCRIPT="/usr/local/bin/go-euc-refresh-telegraf.sh"
CONTAINER_UPGRADE_SCRIPT="/usr/local/bin/go-euc-upgrade.sh"
DASHBOARD_URL_CONFIG_FILE="/etc/go-euc/dashboard-url"

if [[ "${EUID}" -ne 0 ]]; then
  echo "[full-update] Please run as root." >&2
  exit 1
fi

mkdir -p "$(dirname "${LOG_FILE}")" "$(dirname "${LOCK_FILE}")"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "[full-update] Another update is already running." >&2
  exit 1
fi

exec > >(tee -a "${LOG_FILE}") 2>&1

echo "[full-update] ==================================================="
echo "[full-update] Start: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

echo "[full-update] Applying OS updates..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get autoremove -y

echo "[full-update] Updating container images/services..."
"${CONTAINER_UPGRADE_SCRIPT}"

dashboard_url="${DASHBOARDS_URL_DEFAULT}"
if [[ -f "${DASHBOARD_URL_CONFIG_FILE}" ]]; then
  configured_url="$(tr -d '\r\n' < "${DASHBOARD_URL_CONFIG_FILE}" || true)"
  if [[ -n "${configured_url}" ]]; then
    dashboard_url="${configured_url}"
  fi
fi

echo "[full-update] Refreshing dashboard bundle from: ${dashboard_url}"
tmp_zip="$(mktemp /tmp/go-euc-dashboards-XXXXXX.zip)"
curl -fsSL "${dashboard_url}" -o "${tmp_zip}"
mkdir -p "${DASHBOARDS_DIR}"
rm -rf "${DASHBOARDS_DIR}/"*
unzip -oq "${tmp_zip}" -d "${DASHBOARDS_DIR}"
rm -f "${tmp_zip}"

echo "[full-update] Normalizing datasource placeholders in dashboard JSON files..."
shopt -s globstar nullglob
for dashboard in "${DASHBOARDS_DIR}"/**/*.json; do
  sed -i \
    -e 's/"\${DS_GO}"/"DS_GO"/g' \
    -e 's/"{DS_GO}"/"DS_GO"/g' \
    -e 's/\${DS_GO}/DS_GO/g' \
    -e 's/{DS_GO}/DS_GO/g' \
    "${dashboard}" || true
done
shopt -u globstar nullglob

if [[ -f "${STACK_DIR}/docker-compose.yml" ]]; then
  echo "[full-update] Restarting Grafana to reload dashboards..."
  docker compose -f "${STACK_DIR}/docker-compose.yml" restart grafana || true
fi

echo "[full-update] Refreshing latest Telegraf package..."
"${REFRESH_TELEGRAF_SCRIPT}"

echo "[full-update] Completed: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "[full-update] ==================================================="
