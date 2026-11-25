#!/usr/bin/env bash

set -u

CONSOLE_CONFIG_MARKER="/var/lib/go-euc/console-config.done"

log() {
  echo "[ensure-ssh] $*"
}

ensure_sshd_config() {
  if [[ ! -f /etc/ssh/sshd_config ]]; then
    return
  fi

  # Until the console wizard has replaced the default goeucadmin password,
  # leave the image's SSH password settings alone.
  if [[ ! -f "${CONSOLE_CONFIG_MARKER}" ]]; then
    log "Console setup pending; not enabling SSH password authentication yet."
    return
  fi

  # sshd uses the FIRST value it reads for each option, and the Ubuntu cloud image ships
  # /etc/ssh/sshd_config.d/60-cloudimg-settings.conf with "PasswordAuthentication no", which
  # overrides anything in sshd_config. Our own drop-in sorts first, so it takes effect.
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/10-go-euc.conf <<'CONF'
# GO-EUC appliance: password login for goeucadmin and the break-glass account (enabled only
# after the console wizard has replaced the default password). Keys keep working as well.
PasswordAuthentication yes
KbdInteractiveAuthentication no
CONF
  chmod 644 /etc/ssh/sshd_config.d/10-go-euc.conf
}

ensure_host_keys() {
  mkdir -p /etc/ssh
  if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    log "SSH host keys missing, generating with ssh-keygen -A."
    ssh-keygen -A >/dev/null 2>&1 || true
  fi
}

start_ssh_service() {
  systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
}

if command -v sshd >/dev/null 2>&1; then
  log "openssh-server already installed."
  ensure_sshd_config
  ensure_host_keys
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
  ensure_host_keys
  start_ssh_service
  log "openssh-server installed and started."
else
  log "failed to install openssh-server (will retry on next boot)."
fi

exit 0
