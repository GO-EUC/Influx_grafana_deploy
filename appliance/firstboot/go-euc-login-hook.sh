#!/usr/bin/env bash

# Runs once on local console login to collect hostname/IP details.

if [[ -n "${GO_EUC_WIZARD_DONE_IN_SHELL:-}" ]]; then
  return 0
fi
export GO_EUC_WIZARD_DONE_IN_SHELL=1

MARKER_FILE="/var/lib/go-euc/console-config.done"
INSTALLED_MARKER="/var/lib/go-euc/.installed"
WIZARD="/usr/local/bin/go-euc-console-wizard.sh"

[[ -f "${MARKER_FILE}" ]] && return 0
[[ -f "${INSTALLED_MARKER}" ]] && return 0
[[ -x "${WIZARD}" ]] || return 0

TTY_PATH="$(tty 2>/dev/null || true)"
case "${TTY_PATH}" in
  /dev/tty*|/dev/console) ;;
  *) return 0 ;;
esac

echo
echo "GO-EUC initial setup is pending."
echo "Launching console configuration wizard..."
"${WIZARD}"
