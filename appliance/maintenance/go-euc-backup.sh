#!/usr/bin/env bash
# Back up a GO-EUC appliance's data so it can be restored onto a new appliance.
#
#   sudo go-euc-backup.sh [output-dir]          (default /var/backups/go-euc)
#
# Standalone on purpose: it also runs on older appliances that do not ship it (copy it over
# and run it), because moving to a new appliance is how older appliances get new releases.
#
# The archive (mode 600, contains collector passwords) holds:
#   influx/<bucket>.lp.gz        every InfluxDB bucket (except _monitoring/_tasks) as gzipped
#                                line protocol: restorable into any org, keeping the new
#                                appliance's bucket IDs and tokens
#   settings/collector-*.env     infrastructure collector settings (if any)
#   settings/carryover.env       Let's Encrypt domain/email, AUTO_UPGRADE_ENABLED, DASHBOARDS_ZIP_URL
#   grafana/grafana.db           Grafana's database (users, dashboards made in the UI)
#   manifest.json                what is in the archive

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

OUT_DIR="${1:-/var/backups/go-euc}"
INSTALL_ROOT="/opt/influx-grafana"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
GRAFANA_DB="${INSTALL_ROOT}/stack/grafana/data/grafana.db"
CONFIG_FILE="/etc/go-euc/config.env"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
ARCHIVE="${OUT_DIR}/go-euc-backup-$(hostname -s)-${STAMP}.tar.gz"

[[ -f "${CREDENTIALS_FILE}" ]] || { echo "[backup] ${CREDENTIALS_FILE} not found: is this a provisioned GO-EUC appliance?" >&2; exit 1; }
docker inspect influxdb >/dev/null 2>&1 || { echo "[backup] influxdb container not found" >&2; exit 1; }
# shellcheck source=/dev/null
source "${CREDENTIALS_FILE}"
ORG="${SAVED_INFLUX_ADMIN_ORG:?missing SAVED_INFLUX_ADMIN_ORG}"
TOKEN="${SAVED_INFLUX_ADMIN_TOKEN:?missing SAVED_INFLUX_ADMIN_TOKEN}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
chmod 700 "${WORK}"
mkdir -p "${WORK}/influx" "${WORK}/settings" "${WORK}/grafana" "${OUT_DIR}"
chmod 700 "${OUT_DIR}"

echo "[backup] InfluxDB org '${ORG}'"
buckets_json="["
while read -r id name; do
  [[ -z "${id}" || "${name}" == _* ]] && continue
  tmp="/tmp/goeuc-backup-${id}.lp.gz"
  docker exec influxdb influxd inspect export-lp --bucket-id "${id}" --engine-path /var/lib/influxdb2/engine \
    --output-path "${tmp}" --compress --log-level error
  docker cp "influxdb:${tmp}" "${WORK}/influx/${name}.lp.gz" >/dev/null
  docker exec influxdb rm -f "${tmp}"
  lines="$(gzip -dc "${WORK}/influx/${name}.lp.gz" | wc -l | tr -d ' ')"
  echo "[backup]   bucket ${name}: ${lines} points"
  buckets_json+="{\"name\": \"${name}\", \"points\": ${lines}},"
done < <(docker exec influxdb influx bucket list --org "${ORG}" --token "${TOKEN}" --hide-headers | awk '{print $1, $2}')
buckets_json="${buckets_json%,}]"

shopt -s nullglob
for f in /etc/go-euc/collector-*.env; do
  install -m 600 "${f}" "${WORK}/settings/"
  echo "[backup] collector settings: $(basename "${f}")"
done
shopt -u nullglob
if [[ -f "${CONFIG_FILE}" ]]; then
  grep -E '^(APPLIANCE_LETSENCRYPT_DOMAIN|APPLIANCE_LETSENCRYPT_EMAIL|AUTO_UPGRADE_ENABLED|DASHBOARDS_ZIP_URL)=' "${CONFIG_FILE}" \
    > "${WORK}/settings/carryover.env" || true
fi

grafana_included=false
if [[ -f "${GRAFANA_DB}" ]]; then
  # Pause Grafana so its SQLite database is copied in a consistent state.
  docker pause grafana >/dev/null 2>&1 || true
  cp -p "${GRAFANA_DB}" "${WORK}/grafana/grafana.db"
  docker unpause grafana >/dev/null 2>&1 || true
  grafana_included=true
  echo "[backup] Grafana database"
fi

cat > "${WORK}/manifest.json" <<EOF
{
  "format": 1,
  "created_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source_hostname": "$(hostname)",
  "influx_org": "${ORG}",
  "buckets": ${buckets_json},
  "grafana_db": ${grafana_included}
}
EOF

( umask 077; tar -C "${WORK}" -czf "${ARCHIVE}" . )
chmod 600 "${ARCHIVE}"
echo "[backup] Wrote ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1)). It contains collector passwords: keep it private."
echo "[backup] Restore on the new appliance: sudo go-euc-restore.sh $(basename "${ARCHIVE}")"
