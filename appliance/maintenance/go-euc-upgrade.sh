#!/usr/bin/env bash

set -euo pipefail

STACK_FILE="/opt/influx-grafana/stack/docker-compose.yml"

if [[ ! -f "${STACK_FILE}" ]]; then
  echo "[upgrade] Stack file not found: ${STACK_FILE}" >&2
  exit 1
fi

echo "[upgrade] Pulling latest images for compose stack..."
docker compose -f "${STACK_FILE}" pull

echo "[upgrade] Recreating stack services with latest images..."
docker compose -f "${STACK_FILE}" up -d --remove-orphans

echo "[upgrade] Updating Portainer CE to latest image..."
docker pull portainer/portainer-ce:latest
if docker ps -a --format '{{.Names}}' | grep -q '^portainer$'; then
  docker rm -f portainer >/dev/null 2>&1 || true
fi
docker run -d \
  --name portainer \
  --restart=always \
  --network monitoring_net \
  -p 8000:8000 \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest \
  --base-url /portainer >/dev/null

echo "[upgrade] Pruning dangling images..."
docker image prune -f >/dev/null 2>&1 || true

echo "[upgrade] Current container images:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

echo "[upgrade] Completed."
