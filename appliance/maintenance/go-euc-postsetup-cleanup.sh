#!/usr/bin/env bash

set -euo pipefail

MARKER_FILE="/var/lib/go-euc/delete-config-after-bootid"
PUBLIC_CONFIG="/opt/influx-grafana/public/config.txt"

if [[ ! -f "${MARKER_FILE}" ]]; then
  exit 0
fi

target_boot_id="$(cat "${MARKER_FILE}" 2>/dev/null || true)"
current_boot_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"

if [[ -z "${target_boot_id}" || -z "${current_boot_id}" ]]; then
  exit 0
fi

# Delete on the first boot after setup completion.
if [[ "${current_boot_id}" != "${target_boot_id}" ]]; then
  rm -f "${PUBLIC_CONFIG}" || true
  rm -f "${MARKER_FILE}" || true
fi
