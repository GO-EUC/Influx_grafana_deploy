#!/usr/bin/env bash

set -euo pipefail

MARKER_FILE="/var/lib/go-euc/delete-config-after-bootid"

if [[ ! -f "${MARKER_FILE}" ]]; then
  exit 0
fi

# Legacy marker cleanup only. config.txt is intentionally persistent.
rm -f "${MARKER_FILE}" || true
