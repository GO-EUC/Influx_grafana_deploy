#!/usr/bin/env bash
# Sets Grafana's own URL (GF_SERVER_ROOT_URL), which Grafana uses in the links it generates
# (Share > Copy link, alert notifications). Navigation works without it.
#
#   With a public host name (go-euc-set-hostname) or an active Let's Encrypt certificate:
#     https://<name>[:<port>]/grafana/   (go-euc-public-url.sh)
#   Otherwise: Grafana's default (http://localhost/grafana/)
#
#   go-euc-grafana-url.sh           update docker-compose.yml and recreate Grafana if it changed
#   go-euc-grafana-url.sh --print   only print the URL (used by the installer)
#
# Called by the Let's Encrypt deploy hook (first certificate and every renewal),
# go-euc-set-ports and go-euc-set-hostname.

set -euo pipefail

PUBLIC_URL_SCRIPT="/usr/local/bin/go-euc-public-url.sh"
STACK_FILE="/opt/influx-grafana/stack/docker-compose.yml"
DEFAULT_URL='%(protocol)s://%(domain)s/grafana/'

if [[ "${EUID}" -ne 0 && "${1:-}" != "--print" ]]; then
  exec sudo "$0" "$@"
fi
public="$("${PUBLIC_URL_SCRIPT}")" || exit 1
url="${DEFAULT_URL}"
if [[ "$(sed -n 's/^PUBLIC_SOURCE=//p' <<<"${public}")" != "ip" ]]; then
  url="$(sed -n 's/^PUBLIC_BASE=//p' <<<"${public}")/grafana/"
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
