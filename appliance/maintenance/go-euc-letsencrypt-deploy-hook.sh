#!/usr/bin/env bash

# Certbot deploy hook: copies a newly issued/renewed Let's Encrypt certificate into the
# nginx certificate directory and reloads nginx. Installed into
# /etc/letsencrypt/renewal-hooks/deploy/ so certbot.timer renewals reach nginx too.
# certbot sets RENEWED_LINEAGE (e.g. /etc/letsencrypt/live/appliance.example.com).

set -euo pipefail

NGINX_CERT_DIR="/opt/influx-grafana/nginx/certs"
TELEGRAF_PUBLISH_SCRIPT="/usr/local/bin/go-euc-publish-telegraf-config.sh"
GRAFANA_URL_SCRIPT="/usr/local/bin/go-euc-grafana-url.sh"
lineage="${RENEWED_LINEAGE:-}"

if [[ -z "${lineage}" || ! -s "${lineage}/fullchain.pem" || ! -s "${lineage}/privkey.pem" ]]; then
  echo "[le-deploy-hook] RENEWED_LINEAGE is not set to a valid certificate directory." >&2
  exit 1
fi

mkdir -p "${NGINX_CERT_DIR}"
install -m 0644 "${lineage}/fullchain.pem" "${NGINX_CERT_DIR}/letsencrypt.crt"
install -m 0600 "${lineage}/privkey.pem" "${NGINX_CERT_DIR}/letsencrypt.key"
install -m 0644 "${NGINX_CERT_DIR}/letsencrypt.crt" "${NGINX_CERT_DIR}/cert.pem"
install -m 0600 "${NGINX_CERT_DIR}/letsencrypt.key" "${NGINX_CERT_DIR}/key.pem"

if docker ps --format '{{.Names}}' | grep -q '^goeuc-nginx$'; then
  docker exec goeuc-nginx nginx -s reload >/dev/null 2>&1 || true
fi

# Telegraf clients can now verify TLS against the certificate's domain name.
if [[ -x "${TELEGRAF_PUBLISH_SCRIPT}" ]]; then
  "${TELEGRAF_PUBLISH_SCRIPT}" || true
fi

# Grafana's share and alert links use the certificate's domain.
if [[ -x "${GRAFANA_URL_SCRIPT}" ]]; then
  "${GRAFANA_URL_SCRIPT}" || true
fi

echo "[le-deploy-hook] Installed certificate from ${lineage} and reloaded nginx."
