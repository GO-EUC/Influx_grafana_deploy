#!/usr/bin/env bash
# Restore a go-euc-backup.sh archive onto a (new) provisioned GO-EUC appliance.
#
#   sudo go-euc-restore.sh <go-euc-backup-*.tar.gz> [--with-grafana]
#
# - InfluxDB: every bucket's points are written into this appliance's bucket of the same name
#   (created if missing). This appliance's org, bucket IDs and tokens are kept, so its
#   Telegraf downloads, collectors and Grafana keep working. Points already present with the
#   same series and timestamp are simply overwritten, so re-running is safe.
# - Collector settings are restored and every enabled collector is started.
# - Let's Encrypt domain/email, AUTO_UPGRADE_ENABLED and DASHBOARDS_ZIP_URL are carried over
#   into /etc/go-euc/config.env when not already set here (certificates are not requested
#   automatically: point DNS at this appliance, then use the landing page).
# - --with-grafana also replaces Grafana's database (users, dashboards made in the UI). The
#   Grafana admin password is then reset to this appliance's, so config.txt stays correct.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

ARCHIVE="${1:?usage: $0 <go-euc-backup-*.tar.gz> [--with-grafana]}"
WITH_GRAFANA=false
[[ "${2:-}" == "--with-grafana" ]] && WITH_GRAFANA=true
INSTALL_ROOT="/opt/influx-grafana"
CREDENTIALS_FILE="${INSTALL_ROOT}/credentials.env"
CONFIG_FILE="/etc/go-euc/config.env"
COLLECTOR_SCRIPT="/usr/local/bin/go-euc-collector.sh"

[[ -f "${ARCHIVE}" ]] || { echo "[restore] ${ARCHIVE} not found" >&2; exit 1; }
[[ -f /var/lib/go-euc/.installed ]] || { echo "[restore] this appliance has not finished first boot yet" >&2; exit 1; }
# shellcheck source=/dev/null
source "${CREDENTIALS_FILE}"
ORG="${SAVED_INFLUX_ADMIN_ORG:?missing SAVED_INFLUX_ADMIN_ORG}"
TOKEN="${SAVED_INFLUX_ADMIN_TOKEN:?missing SAVED_INFLUX_ADMIN_TOKEN}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
chmod 700 "${WORK}"
tar -C "${WORK}" -xzf "${ARCHIVE}"
[[ -f "${WORK}/manifest.json" ]] || { echo "[restore] not a go-euc-backup archive (no manifest.json)" >&2; exit 1; }
echo "[restore] Backup of $(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["source_hostname"], "taken", m["created_utc"], "from org", repr(m["influx_org"]))' "${WORK}/manifest.json")"

echo "[restore] InfluxDB -> org '${ORG}'"
shopt -s nullglob
for f in "${WORK}"/influx/*.lp.gz; do
  bucket="$(basename "${f}" .lp.gz)"
  points="$(gzip -dc "${f}" | wc -l | tr -d ' ')"
  if [[ "${points}" == 0 ]]; then
    echo "[restore]   bucket ${bucket}: empty, skipped"
    continue
  fi
  if ! docker exec influxdb influx bucket find --name "${bucket}" --org "${ORG}" --token "${TOKEN}" >/dev/null 2>&1; then
    docker exec influxdb influx bucket create --name "${bucket}" --org "${ORG}" --token "${TOKEN}" >/dev/null
    echo "[restore]   bucket ${bucket}: created"
  fi
  docker cp "${f}" "influxdb:/tmp/goeuc-restore.lp.gz" >/dev/null
  docker exec influxdb influx write --bucket "${bucket}" --org "${ORG}" --token "${TOKEN}" \
    --file /tmp/goeuc-restore.lp.gz --compression gzip --format lp
  docker exec influxdb rm -f /tmp/goeuc-restore.lp.gz
  echo "[restore]   bucket ${bucket}: ${points} points written"
done

for f in "${WORK}"/settings/collector-*.env; do
  install -m 600 -o root -g root "${f}" "/etc/go-euc/$(basename "${f}")"
  echo "[restore] collector settings: $(basename "${f}")"
done
shopt -u nullglob
if [[ -x "${COLLECTOR_SCRIPT}" ]]; then
  "${COLLECTOR_SCRIPT}" all apply-enabled || echo "[restore] WARN: a collector failed to start; check it on the landing page."
fi

if [[ -s "${WORK}/settings/carryover.env" ]]; then
  touch "${CONFIG_FILE}"; chmod 600 "${CONFIG_FILE}"
  while IFS= read -r line; do
    key="${line%%=*}"
    if ! grep -q "^${key}=" "${CONFIG_FILE}"; then
      printf '%s\n' "${line}" >> "${CONFIG_FILE}"
      echo "[restore] config.env: carried over ${key}"
    fi
  done < "${WORK}/settings/carryover.env"
fi

if [[ "${WITH_GRAFANA}" == true ]]; then
  if [[ -f "${WORK}/grafana/grafana.db" ]]; then
    docker stop grafana >/dev/null
    install -m 640 -o 472 -g 472 "${WORK}/grafana/grafana.db" "${INSTALL_ROOT}/stack/grafana/data/grafana.db"
    docker start grafana >/dev/null
    sleep 5
    docker exec grafana grafana cli --homepath /usr/share/grafana admin reset-admin-password "${SAVED_GRAFANA_ADMIN_PASSWORD}" >/dev/null \
      && echo "[restore] Grafana database restored; admin password reset to this appliance's (see config.txt)" \
      || echo "[restore] WARN: Grafana database restored, but resetting the admin password failed; the old appliance's Grafana admin password applies."
  else
    echo "[restore] WARN: --with-grafana given, but the backup has no Grafana database"
  fi
fi

echo "[restore] Done. Telegraf clients still pointing at the old appliance need this appliance's"
echo "[restore] configs from https://<this-appliance>/telegraf/ (new address and write-only token)."
