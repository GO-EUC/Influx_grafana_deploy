#!/usr/bin/env bash

# Re-exec under bash if launched via sh/dash.
if [ -z "${BASH_VERSION:-}" ]; then
  SCRIPT_PATH="$0"
  case "${SCRIPT_PATH}" in
    /*) ;;
    *) SCRIPT_PATH="$(pwd)/${SCRIPT_PATH}" ;;
  esac
  exec /usr/bin/env bash "${SCRIPT_PATH}" "$@"
fi

set -euo pipefail

# Installer:
# - Install Docker Engine + Compose plugin on Ubuntu
# - Install and run Portainer CE
# - Create a shared Docker network for the monitoring stack
# - Create a docker-compose stack with InfluxDB + Grafana
# - Bootstrap Influx and Grafana configuration/provisioning

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root (or with sudo)." >&2
  exit 1
fi

echo "==> Starting installer"

if [[ ! -f /etc/os-release ]]; then
  echo "Cannot detect OS. /etc/os-release is missing." >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID}" != "ubuntu" ]]; then
  echo "This script currently supports Ubuntu only. Detected: ${ID}" >&2
  exit 1
fi

INSTALL_ROOT="/opt/influx-grafana"
STACK_DIR="${INSTALL_ROOT}/stack"
NETWORK_NAME="monitoring_net"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
NGINX_CONF_DIR="${INSTALL_ROOT}/nginx/conf.d"
NGINX_CERT_DIR="${INSTALL_ROOT}/nginx/certs"
NGINX_ACME_WEBROOT="${INSTALL_ROOT}/nginx/acme"

# Load previously generated credentials/settings so reruns are stable.
if [[ -f "${CREDENTIALS_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CREDENTIALS_FILE}"
fi

# Generate deterministic-length secrets from a safe character set.
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

PORTAINER_ADMIN_USER="${PORTAINER_ADMIN_USER:-${SAVED_PORTAINER_ADMIN_USER:-admin}}"
PORTAINER_ADMIN_PASSWORD="${PORTAINER_ADMIN_PASSWORD:-${SAVED_PORTAINER_ADMIN_PASSWORD:-$(generate_secret 20)}}"
INFLUX_ADMIN_USER="${INFLUX_ADMIN_USER:-${SAVED_INFLUX_ADMIN_USER:-influxadmin}}"
INFLUX_ADMIN_PASSWORD="${INFLUX_ADMIN_PASSWORD:-${SAVED_INFLUX_ADMIN_PASSWORD:-$(generate_secret 20)}}"
INFLUX_ADMIN_ORG="${INFLUX_ADMIN_ORG:-${SAVED_INFLUX_ADMIN_ORG:-monitoring}}"
INFLUX_INIT_BUCKET="${INFLUX_INIT_BUCKET:-${SAVED_INFLUX_INIT_BUCKET:-bootstrap}}"
INFLUX_ADMIN_TOKEN="${INFLUX_ADMIN_TOKEN:-${SAVED_INFLUX_ADMIN_TOKEN:-$(generate_secret 40)}}"
INFLUX_BUCKET_PERFORMANCE="${INFLUX_BUCKET_PERFORMANCE:-Performance}"
INFLUX_BUCKET_TESTS="${INFLUX_BUCKET_TESTS:-Tests}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-${SAVED_GRAFANA_ADMIN_USER:-admin}}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-${SAVED_GRAFANA_ADMIN_PASSWORD:-$(generate_secret 20)}}"
# Hardcoded dashboard bundle URL (version-controlled artifact location).
DASHBOARDS_ZIP_URL="https://goeucartifacts4hiu9i.blob.core.windows.net/files/Dashboards.zip"
GRAFANA_DATASOURCE_NAME="DS_GO"
GRAFANA_DATASOURCE_UID="DS_GO"

# Persist resolved values for idempotent reruns and easier troubleshooting.
mkdir -p "${INSTALL_ROOT}"
cat > "${CREDENTIALS_FILE}" <<EOF
SAVED_PORTAINER_ADMIN_USER='${PORTAINER_ADMIN_USER}'
SAVED_PORTAINER_ADMIN_PASSWORD='${PORTAINER_ADMIN_PASSWORD}'
SAVED_INFLUX_ADMIN_USER='${INFLUX_ADMIN_USER}'
SAVED_INFLUX_ADMIN_PASSWORD='${INFLUX_ADMIN_PASSWORD}'
SAVED_INFLUX_ADMIN_ORG='${INFLUX_ADMIN_ORG}'
SAVED_INFLUX_INIT_BUCKET='${INFLUX_INIT_BUCKET}'
SAVED_INFLUX_ADMIN_TOKEN='${INFLUX_ADMIN_TOKEN}'
SAVED_GRAFANA_ADMIN_USER='${GRAFANA_ADMIN_USER}'
SAVED_GRAFANA_ADMIN_PASSWORD='${GRAFANA_ADMIN_PASSWORD}'
EOF
chmod 600 "${CREDENTIALS_FILE}"

PORTAINER_CREDS_STATUS="configured"
INFLUX_STATUS="unknown"
GRAFANA_STATUS="unknown"
DASHBOARD_IMPORT_STATUS="not-configured"
DASHBOARD_JSON_COUNT="0"
GRAFANA_DATASOURCE_STATUS="unknown"

# Poll an HTTP endpoint until an expected status code is returned.
wait_for_http() {
  local url="$1"
  local expected="$2"
  local retries="${3:-60}"
  local sleep_seconds="${4:-2}"
  local code=""
  local _i

  for _i in $(seq 1 "${retries}"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${url}" || true)"
    if [[ "${code}" == "${expected}" ]]; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done
  return 1
}

ensure_influx_bucket() {
  local bucket_name="$1"
  # If bucket already exists, do nothing.
  if docker exec influxdb influx bucket find \
    --name "${bucket_name}" \
    --org "${INFLUX_ADMIN_ORG}" \
    --token "${INFLUX_ADMIN_TOKEN}" >/dev/null 2>&1; then
    return 0
  fi

  docker exec influxdb influx bucket create \
    --name "${bucket_name}" \
    --org "${INFLUX_ADMIN_ORG}" \
    --token "${INFLUX_ADMIN_TOKEN}" >/dev/null
}

# Download dashboard ZIP, extract it, and normalize known datasource placeholders.
download_dashboards_zip() {
  local url="$1"
  local tmp_zip=""
  shopt -s globstar nullglob

  tmp_zip="$(mktemp /tmp/grafana-dashboards-XXXXXX.zip)"
  # Fetch dashboard artifact from the configured URL.
  if ! curl -fsSL "${url}" -o "${tmp_zip}"; then
    rm -f "${tmp_zip}"
    DASHBOARD_IMPORT_STATUS="download-failed"
    shopt -u globstar nullglob
    return 1
  fi

  # Replace previously extracted dashboards with the latest bundle contents.
  rm -rf "${STACK_DIR}/grafana/dashboards/"*
  if ! unzip -oq "${tmp_zip}" -d "${STACK_DIR}/grafana/dashboards"; then
    rm -f "${tmp_zip}"
    DASHBOARD_IMPORT_STATUS="extract-failed"
    shopt -u globstar nullglob
    return 1
  fi
  rm -f "${tmp_zip}"

  local dashboard_files=("${STACK_DIR}"/grafana/dashboards/**/*.json)
  DASHBOARD_JSON_COUNT="${#dashboard_files[@]}"
  if [[ "${DASHBOARD_JSON_COUNT}" -gt 0 ]]; then
    for dashboard in "${dashboard_files[@]}"; do
      # Resolve common exported Grafana datasource placeholders.
      sed -i \
        -e 's/"\${DS_GO}"/"DS_GO"/g' \
        -e 's/"{DS_GO}"/"DS_GO"/g' \
        -e 's/\${DS_GO}/DS_GO/g' \
        -e 's/{DS_GO}/DS_GO/g' \
        "${dashboard}" || true
    done
    DASHBOARD_IMPORT_STATUS="import-ready"
  else
    DASHBOARD_IMPORT_STATUS="no-json-found"
  fi
  shopt -u globstar nullglob
  return 0
}

# Ensure Grafana has the expected datasource, with API fallback if file provisioning misses it.
ensure_grafana_datasource_via_api() {
  local get_code=""
  local post_code=""
  local payload_file=""
  local datasource_name_encoded=""

  datasource_name_encoded="${GRAFANA_DATASOURCE_NAME// /%20}"
  # Check whether datasource already exists in Grafana.
  get_code="$(
    curl -s -o /tmp/grafana-datasource-check.json -w '%{http_code}' \
      -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      "http://localhost:3000/api/datasources/name/${datasource_name_encoded}" || true
  )"

  if [[ "${get_code}" == "200" ]]; then
    GRAFANA_DATASOURCE_STATUS="exists"
    return 0
  fi

  # Build datasource payload that matches the provisioned Influx settings.
  payload_file="$(mktemp /tmp/grafana-datasource-payload-XXXXXX.json)"
  cat > "${payload_file}" <<JSON
{
  "name": "${GRAFANA_DATASOURCE_NAME}",
  "uid": "${GRAFANA_DATASOURCE_UID}",
  "type": "influxdb",
  "url": "http://influxdb:8086",
  "access": "proxy",
  "isDefault": true,
  "jsonData": {
    "version": "Flux",
    "organization": "${INFLUX_ADMIN_ORG}",
    "defaultBucket": "${INFLUX_INIT_BUCKET}"
  },
  "secureJsonData": {
    "token": "${INFLUX_ADMIN_TOKEN}"
  }
}
JSON

  post_code="$(
    curl -s -o /tmp/grafana-datasource-create.json -w '%{http_code}' \
      -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
      -H "Content-Type: application/json" \
      -X POST "http://localhost:3000/api/datasources" \
      --data-binary "@${payload_file}" || true
  )"

  rm -f "${payload_file}"

  # Treat 409 as success-like because datasource already exists.
  case "${post_code}" in
    200)
      GRAFANA_DATASOURCE_STATUS="created-via-api"
      ;;
    409)
      GRAFANA_DATASOURCE_STATUS="already-exists"
      ;;
    *)
      GRAFANA_DATASOURCE_STATUS="api-create-failed"
      ;;
  esac
}

# --- Base package and Docker installation ---
echo "==> Installing Docker prerequisites"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https unzip

install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

echo "==> Installing Docker Engine and Compose plugin"
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker

# --- Networking and Portainer setup ---
echo "==> Creating shared Docker network (${NETWORK_NAME})"
if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  docker network create "${NETWORK_NAME}" >/dev/null
fi

echo "==> Installing Portainer CE"
docker volume create portainer_data >/dev/null
if ! docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
  docker run -d \
    --name portainer \
    --restart=always \
    --network "${NETWORK_NAME}" \
    -p 8000:8000 \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest \
    --base-url /portainer >/dev/null
fi

if ! docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s " $k}}{{end}}' portainer 2>/dev/null | grep -q "${NETWORK_NAME}"; then
  echo "==> Recreating Portainer to attach ${NETWORK_NAME}"
  docker rm -f portainer >/dev/null 2>&1 || true
  docker run -d \
    --name portainer \
    --restart=always \
    --network "${NETWORK_NAME}" \
    -p 8000:8000 \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest \
    --base-url /portainer >/dev/null
fi

# Wait for Portainer API before attempting admin user initialization.
echo "==> Initializing Portainer admin credentials"
PORTAINER_READY=0
for _ in $(seq 1 60); do
  if curl -sk --max-time 2 "https://localhost:9443/api/status" >/dev/null || curl -sk --max-time 2 "https://localhost:9443/portainer/api/status" >/dev/null; then
    PORTAINER_READY=1
    break
  fi
  sleep 2
done

if [[ "${PORTAINER_READY}" -eq 1 ]]; then
  PORTAINER_INIT_CODE="000"
  PORTAINER_INIT_CODE="$(
    curl -sk \
      -o /tmp/portainer-init.json \
      -w '%{http_code}' \
      -H "Content-Type: application/json" \
      -X POST "https://localhost:9443/api/users/admin/init" \
      -d "{\"Username\":\"${PORTAINER_ADMIN_USER}\",\"Password\":\"${PORTAINER_ADMIN_PASSWORD}\"}"
  )"
  if [[ "${PORTAINER_INIT_CODE}" != "200" && "${PORTAINER_INIT_CODE}" != "409" && "${PORTAINER_INIT_CODE}" != "422" ]]; then
    PORTAINER_INIT_CODE="$(
      curl -sk \
        -o /tmp/portainer-init.json \
        -w '%{http_code}' \
        -H "Content-Type: application/json" \
        -X POST "https://localhost:9443/portainer/api/users/admin/init" \
        -d "{\"Username\":\"${PORTAINER_ADMIN_USER}\",\"Password\":\"${PORTAINER_ADMIN_PASSWORD}\"}"
    )"
  fi

  case "${PORTAINER_INIT_CODE}" in
    200)
      PORTAINER_CREDS_STATUS="configured"
      ;;
    409|422)
      PORTAINER_CREDS_STATUS="already-initialized"
      PORTAINER_ADMIN_PASSWORD="<already-set>"
      ;;
    *)
      PORTAINER_CREDS_STATUS="init-failed"
      PORTAINER_ADMIN_PASSWORD="<unknown>"
      ;;
  esac
else
  PORTAINER_CREDS_STATUS="portainer-unreachable"
  PORTAINER_ADMIN_PASSWORD="<unknown>"
fi

# --- Generate stack files and provisioning definitions ---
echo "==> Creating stack layout under ${INSTALL_ROOT}"
mkdir -p "${STACK_DIR}"/{grafana,influxdb}
mkdir -p "${STACK_DIR}/grafana/data" "${STACK_DIR}/influxdb/data" "${STACK_DIR}/influxdb/config"
mkdir -p "${STACK_DIR}/grafana/provisioning/datasources"
mkdir -p "${STACK_DIR}/grafana/provisioning/dashboards" "${STACK_DIR}/grafana/dashboards"
mkdir -p "${NGINX_CONF_DIR}" "${NGINX_CERT_DIR}" "${NGINX_ACME_WEBROOT}"
chown -R 472:472 "${STACK_DIR}/grafana/data" || true

# Grafana datasource provisioning file (InfluxDB/Flux).
cat > "${STACK_DIR}/grafana/provisioning/datasources/influxdb.yml" <<YAML
apiVersion: 1
prune: true

datasources:
  - name: "${GRAFANA_DATASOURCE_NAME}"
    uid: "${GRAFANA_DATASOURCE_UID}"
    type: influxdb
    access: proxy
    url: "http://influxdb:8086"
    isDefault: true
    editable: true
    jsonData:
      version: Flux
      organization: "${INFLUX_ADMIN_ORG}"
      defaultBucket: "${INFLUX_INIT_BUCKET}"
    secureJsonData:
      token: "${INFLUX_ADMIN_TOKEN}"
YAML

# Grafana dashboard provider config to load JSON files from mounted path.
cat > "${STACK_DIR}/grafana/provisioning/dashboards/dashboards.yml" <<'YAML'
apiVersion: 1

providers:
  - name: default
    orgId: 1
    folder: Imported
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: true
YAML

# Dashboard bundle ingestion (optional if URL is blank).
if [[ -n "${DASHBOARDS_ZIP_URL}" ]]; then
  echo "==> Downloading dashboards from ZIP URL"
  download_dashboards_zip "${DASHBOARDS_ZIP_URL}" || true
else
  DASHBOARD_IMPORT_STATUS="not-configured"
fi

# Docker Compose definition for InfluxDB and Grafana services.
cat > "${STACK_DIR}/docker-compose.yml" <<YAML
services:
  influxdb:
    image: influxdb:2.7
    container_name: influxdb
    restart: unless-stopped
    ports:
      - "8086:8086"
    volumes:
      - ./influxdb/data:/var/lib/influxdb2
      - ./influxdb/config:/etc/influxdb2
    environment:
      DOCKER_INFLUXDB_INIT_MODE: "setup"
      DOCKER_INFLUXDB_INIT_USERNAME: "${INFLUX_ADMIN_USER}"
      DOCKER_INFLUXDB_INIT_PASSWORD: "${INFLUX_ADMIN_PASSWORD}"
      DOCKER_INFLUXDB_INIT_ORG: "${INFLUX_ADMIN_ORG}"
      DOCKER_INFLUXDB_INIT_BUCKET: "${INFLUX_INIT_BUCKET}"
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: "${INFLUX_ADMIN_TOKEN}"
      INFLUXD_HTTP_BASE_PATH: "/influx"
    networks:
      - monitoring_net

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - ./grafana/data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    environment:
      GF_SECURITY_ADMIN_USER: "${GRAFANA_ADMIN_USER}"
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD}"
      GF_SERVER_ROOT_URL: "%(protocol)s://%(domain)s/grafana/"
      GF_SERVER_SERVE_FROM_SUB_PATH: "true"
    networks:
      - monitoring_net
    depends_on:
      - influxdb

  goeucweb:
    image: goeuc/webserver:latest
    container_name: goeucweb
    restart: unless-stopped
    networks:
      - monitoring_net

  nginx:
    image: nginx:1.27-alpine
    container_name: goeuc-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ${INSTALL_ROOT}/public:/usr/share/nginx/html:ro
      - ${NGINX_CONF_DIR}/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ${NGINX_CERT_DIR}:/etc/nginx/certs:ro
      - ${NGINX_ACME_WEBROOT}:/var/www/acme:rw
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - monitoring_net
    depends_on:
      - influxdb
      - grafana
      - goeucweb

networks:
  monitoring_net:
    external: true
    name: monitoring_net
YAML

# --- Start services and apply readiness checks ---
echo "==> Starting InfluxDB + Grafana"
docker compose -f "${STACK_DIR}/docker-compose.yml" up -d
# Restart Grafana once to ensure provisioning mounts are fully applied.
docker compose -f "${STACK_DIR}/docker-compose.yml" restart grafana >/dev/null 2>&1 || true

echo "==> Waiting for InfluxDB and Grafana readiness"
if wait_for_http "http://localhost:8086/influx/health" "200" 90 2 || wait_for_http "http://localhost:8086/health" "200" 90 2; then
  INFLUX_STATUS="ready"
  # Ensure required business buckets exist every run.
  echo "==> Ensuring required Influx buckets exist"
  ensure_influx_bucket "${INFLUX_BUCKET_PERFORMANCE}"
  ensure_influx_bucket "${INFLUX_BUCKET_TESTS}"
else
  INFLUX_STATUS="not-ready"
fi

if wait_for_http "http://localhost:3000/api/health" "200" 90 2; then
  GRAFANA_STATUS="ready"
  # Double-check datasource through API in case provisioning order/race issues occur.
  echo "==> Verifying Grafana datasource (${GRAFANA_DATASOURCE_NAME})"
  ensure_grafana_datasource_via_api || true
else
  GRAFANA_STATUS="not-ready"
  GRAFANA_DATASOURCE_STATUS="grafana-not-ready"
fi

# --- Final summary and operator-facing output ---
echo
echo "Install complete."
echo "- Web UI (HTTPS): https://<vm-ip>/"
echo "- Grafana: https://<vm-ip>/grafana/"
echo "- InfluxDB: https://<vm-ip>/influx/"
echo "- Portainer: https://<vm-ip>/portainer/"
echo "- GO-EUC Web: https://<vm-ip>/goeucweb/"
echo "- Portainer direct: https://<vm-ip>:9443"
echo "  - username: ${PORTAINER_ADMIN_USER}"
echo "  - password: ${PORTAINER_ADMIN_PASSWORD}"
echo "  - status:   ${PORTAINER_CREDS_STATUS}"
echo "- InfluxDB direct: http://<vm-ip>:8086/influx/"
echo "  - username: ${INFLUX_ADMIN_USER}"
echo "  - password: ${INFLUX_ADMIN_PASSWORD}"
echo "  - org:      ${INFLUX_ADMIN_ORG}"
echo "  - buckets:  ${INFLUX_BUCKET_PERFORMANCE}, ${INFLUX_BUCKET_TESTS}"
echo "  - token:    ${INFLUX_ADMIN_TOKEN}"
echo "  - status:   ${INFLUX_STATUS}"
echo "- Grafana direct: http://<vm-ip>:3000/grafana/"
echo "  - username: ${GRAFANA_ADMIN_USER}"
echo "  - password: ${GRAFANA_ADMIN_PASSWORD}"
echo "  - dashboard ZIP URL: ${DASHBOARDS_ZIP_URL:-<not-set>}"
echo "  - dashboards JSON count: ${DASHBOARD_JSON_COUNT}"
echo "  - dashboard import status: ${DASHBOARD_IMPORT_STATUS}"
echo "  - datasource status: ${GRAFANA_DATASOURCE_STATUS}"
echo "  - status:   ${GRAFANA_STATUS}"
echo
if [[ "${GRAFANA_STATUS}" != "ready" ]]; then
  echo "Grafana did not become ready in time. Check:"
  echo "- docker ps"
  echo "- docker logs grafana"
  echo "- sudo ss -ltnp | grep ':3000'"
fi
echo
echo "Credentials file: ${CREDENTIALS_FILE}"
echo
echo "Next step: add automated bootstrap for credentials, buckets, API token,"
echo "Grafana datasource provisioning, and dashboard import."
