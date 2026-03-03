#!/usr/bin/env bash

set -u

log() {
  echo "[ensure-ssh] $*"
}

ensure_sshd_config() {
  if [[ ! -f /etc/ssh/sshd_config ]]; then
    return
  fi

  sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config || true
  if ! grep -q '^PasswordAuthentication yes' /etc/ssh/sshd_config; then
    echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
  fi

  sed -i 's/^[#[:space:]]*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config || true
}

start_ssh_service() {
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
}

if command -v sshd >/dev/null 2>&1; then
  log "openssh-server already installed."
  ensure_sshd_config
  start_ssh_service
  exit 0
fi

if ! command -v apt-get >/dev/null 2>&1; then
  log "apt-get not available; cannot install openssh-server."
  exit 0
fi

log "openssh-server missing, attempting install."
if apt-get update -y >/dev/null 2>&1 && apt-get install -y openssh-server >/dev/null 2>&1; then
  ensure_sshd_config
  start_ssh_service
  log "openssh-server installed and started."
else
  log "failed to install openssh-server (will retry on next boot)."
fi

exit 0
