#!/usr/bin/env bash
# Sets Grafana's own URL (GF_SERVER_ROOT_URL), which Grafana uses in the links it generates
# (Share > Copy link, alert notifications). Navigation works without it.
#
#   With an active Let's Encrypt certificate:  https://<domain>/grafana/
#   Otherwise:                                 Grafana's default (http://localhost/grafana/)
#
# The domain is a public name, so the URL uses the public HTTPS port 443 even when the
# appliance listens on 4443 (the router maps 443 -> 4443; see docs/external-access.md).
#
#   go-euc-grafana-url.sh           update docker-compose.yml and recreate Grafana if it changed
#   go-euc-grafana-url.sh --print   only print the URL (used by the installer)
#
# Called by the Let's Encrypt deploy hook (first certificate and every renewal).

set -euo pipefail

CONFIG_FILE="/etc/go-euc/config.env"
CERT_DIR="/opt/influx-grafana/nginx/certs"
STACK_FILE="/opt/influx-grafana/stack/docker-compose.yml"
DEFAULT_URL='%(protocol)s://%(domain)s/grafana/'

if [[ "${EUID}" -ne 0 && "${1:-}" != "--print" ]]; then
  exec sudo "$0" "$@"
fi
if [[ -r "${CONFIG_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG_FILE}"
elif [[ -f "${CONFIG_FILE}" ]]; then
  echo "[grafana-url] ${CONFIG_FILE} is not readable; run with sudo." >&2
  exit 1
fi

url="${DEFAULT_URL}"
domain="${APPLIANCE_LETSENCRYPT_DOMAIN:-}"
if [[ -n "${domain}" && -s "${CERT_DIR}/letsencrypt.crt" ]] \
  && cmp -s "${CERT_DIR}/cert.pem" "${CERT_DIR}/letsencrypt.crt"; then
  url="https://${domain}/grafana/"
fi

if [[ "${1:-}" == "--print" ]]; then
  echo "${url}"
  exit 0
fi

[[ -f "${STACK_FILE}" ]] || { echo "[grafana-url] ${STACK_FILE} not found; nothing to do."; exit 0; }

changed="$(GOEUC_URL="${url}" python3 - "${STACK_FILE}" <<'PY'
import os, re, sys
path, url = sys.argv[1], os.environ["GOEUC_URL"]
text = open(path, encoding="utf-8").read()
new = re.sub(r'(?m)^(\s*GF_SERVER_ROOT_URL: )".*"$', lambda m: f'{m.group(1)}"{url}"', text)
if new != text:
    open(path, "w", encoding="utf-8").write(new)
    print("yes")
PY
)"

if [[ "${changed}" == "yes" ]]; then
  docker compose -f "${STACK_FILE}" up -d grafana >/dev/null 2>&1 || true
  echo "[grafana-url] Grafana URL set to ${url} (Grafana restarted)."
else
  echo "[grafana-url] Grafana URL already ${url}."
fi
