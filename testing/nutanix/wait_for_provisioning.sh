#!/usr/bin/env bash
# Wait until a freshly deployed GO-EUC appliance finishes first-boot provisioning (see testing/README.md).
#
#   testing/nutanix/wait_for_provisioning.sh <appliance-ip> [timeout-seconds]
#
# Prints each state change (SSH reachability, /etc/issue banner, go-euc-firstboot.service state).
# Exit 0 when /var/lib/go-euc/.installed exists, 1 on FAILED banner or timeout.

set -u
IP="${1:?usage: $0 <appliance-ip> [timeout-seconds]}"
TIMEOUT="${2:-2700}"
DIR="${GOEUC_TEST_DIR:-$HOME/.goeuc-test}"
SSH=(ssh -i "${DIR}/id_goeuc_test" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${DIR}/known_hosts"
     -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o BatchMode=yes "goeucadmin@${IP}")

start=$(date +%s)
state=""
while :; do
  elapsed=$(( $(date +%s) - start ))
  if (( elapsed > TIMEOUT )); then
    echo "[${elapsed}s] TIMEOUT after ${TIMEOUT}s (last state: ${state})"
    exit 1
  fi
  out="$("${SSH[@]}" 'head -1 /etc/issue; test -f /var/lib/go-euc/.installed && echo INSTALLED; systemctl is-active go-euc-firstboot.service; tail -1 /var/log/go-euc-install.log 2>/dev/null' 2>/dev/null | tr '\n' '|')"
  new="${out:-ssh-unreachable}"
  # Only the banner/marker/service state count as a change; show the latest log line with it.
  key="$(cut -d'|' -f1-3 <<<"${new}")"
  if [[ "${key}" != "${state}" ]]; then
    echo "[${elapsed}s] ${new}"
    state="${key}"
  fi
  case "${out}" in
    *INSTALLED*) echo "[${elapsed}s] provisioning complete"; exit 0 ;;
    *FAILED*) echo "[${elapsed}s] provisioning FAILED"; exit 1 ;;
  esac
  sleep 20
done
