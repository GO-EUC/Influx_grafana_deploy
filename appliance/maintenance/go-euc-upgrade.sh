#!/usr/bin/env bash

set -euo pipefail

STACK_FILE="/opt/influx-grafana/stack/docker-compose.yml"
# Keep in step with PORTAINER_IMAGE in scripts/step1_install_base.sh.
PORTAINER_IMAGE="portainer/portainer-ce:2.45.4"

if [[ ! -f "${STACK_FILE}" ]]; then
  echo "[upgrade] Stack file not found: ${STACK_FILE}" >&2
  exit 1
fi

echo "[upgrade] Pulling pinned images for compose stack..."
docker compose -f "${STACK_FILE}" pull influxdb grafana nginx

echo "[upgrade] Pulling GO-EUC web image (best effort)..."
if ! docker compose -f "${STACK_FILE}" pull goeucweb; then
  echo "[upgrade] WARN: Failed to pull goeucweb image. Continuing with core services."
fi

echo "[upgrade] Recreating stack services with pulled images..."
docker compose -f "${STACK_FILE}" up -d --remove-orphans influxdb grafana nginx

echo "[upgrade] Starting GO-EUC web service (best effort)..."
if ! docker compose -f "${STACK_FILE}" up -d goeucweb; then
  echo "[upgrade] WARN: Failed to start goeucweb. Core services remain updated."
fi

echo "[upgrade] Updating Portainer CE (${PORTAINER_IMAGE})..."
docker pull "${PORTAINER_IMAGE}"
if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
  docker rm -f portainer >/dev/null 2>&1 || true
fi
docker run -d \
  --name portainer \
  --restart=always \
  --network monitoring_net \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  "${PORTAINER_IMAGE}" \
  --base-url /portainer >/dev/null

# Infrastructure collectors (vSphere, Nutanix): refresh every enabled one with the pinned image.
COLLECTOR_SCRIPT="/usr/local/bin/go-euc-collector.sh"
if [[ -x "${COLLECTOR_SCRIPT}" ]]; then
  echo "[upgrade] Updating enabled infrastructure collectors..."
  "${COLLECTOR_SCRIPT}" all apply-enabled || echo "[upgrade] WARN: one or more collectors failed to update."
fi

echo "[upgrade] Pruning dangling images..."
docker image prune -f >/dev/null 2>&1 || true

echo "[upgrade] Current container images:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo "[upgrade] Completed."
