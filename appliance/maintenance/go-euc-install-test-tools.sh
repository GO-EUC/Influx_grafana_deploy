#!/usr/bin/env bash
# Installs the tools the landing page's Testing section uses to work with GO-EUC/benchmarkle:
# PowerShell 7 (Setup.ps1), the Azure CLI (az) and the GitHub CLI (gh), from the Microsoft and
# GitHub apt repositories. Idempotent: adds the repositories once and installs what is missing;
# "Run Full Appliance Update" re-runs it and its apt upgrade keeps the tools current.
#
# The image is built without network access, so this runs on the appliance: during first boot
# (scripts/step1_install_base.sh) and on every full update. A failure doesn't stop the rest of the
# setup: the Testing section reports the missing tools, and the next full update tries again.

set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

KEYRINGS=/etc/apt/keyrings
MS_KEY="${KEYRINGS}/microsoft.gpg"
GH_KEY="${KEYRINGS}/githubcli-archive-keyring.gpg"
export DEBIAN_FRONTEND=noninteractive

# shellcheck source=/dev/null
. /etc/os-release
codename="${VERSION_CODENAME:-noble}"
version="${VERSION_ID:-24.04}"
arch="$(dpkg --print-architecture)"

install -m 0755 -d "${KEYRINGS}"

if [[ ! -s "${MS_KEY}" ]]; then
  curl -fsSL --retry 3 https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o "${MS_KEY}.tmp"
  mv -f "${MS_KEY}.tmp" "${MS_KEY}"; chmod a+r "${MS_KEY}"
fi
if [[ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]]; then
  echo "deb [arch=${arch} signed-by=${MS_KEY}] https://packages.microsoft.com/ubuntu/${version}/prod ${codename} main" \
    > /etc/apt/sources.list.d/microsoft-prod.list
fi
if [[ ! -f /etc/apt/sources.list.d/azure-cli.list ]]; then
  echo "deb [arch=${arch} signed-by=${MS_KEY}] https://packages.microsoft.com/repos/azure-cli/ ${codename} main" \
    > /etc/apt/sources.list.d/azure-cli.list
fi

if [[ ! -s "${GH_KEY}" ]]; then
  curl -fsSL --retry 3 -o "${GH_KEY}.tmp" https://cli.github.com/packages/githubcli-archive-keyring.gpg
  mv -f "${GH_KEY}.tmp" "${GH_KEY}"; chmod a+r "${GH_KEY}"
fi
if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
  echo "deb [arch=${arch} signed-by=${GH_KEY}] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
fi

missing=()
command -v pwsh >/dev/null 2>&1 || missing+=(powershell)
command -v az >/dev/null 2>&1 || missing+=(azure-cli)
command -v gh >/dev/null 2>&1 || missing+=(gh)

if [[ "${#missing[@]}" -gt 0 ]]; then
  apt-get update -y -o Dpkg::Use-Pty=0 >/dev/null
  apt-get install -y -o Dpkg::Use-Pty=0 --no-install-recommends "${missing[@]}"
fi

# az: no interactive login experience or telemetry prompts on a server.
AZURE_CONFIG_DIR=/var/lib/go-euc/azure
install -d -m 0700 "${AZURE_CONFIG_DIR}"
AZURE_CONFIG_DIR="${AZURE_CONFIG_DIR}" az config set core.login_experience_v2=off core.collect_telemetry=false core.only_show_errors=true >/dev/null 2>&1 || true

printf '[test-tools] pwsh %s, az %s, gh %s\n' \
  "$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo missing)" \
  "$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo missing)" \
  "$(gh --version 2>/dev/null | awk 'NR==1 {print $3}' || echo missing)"
