#!/usr/bin/env bash
# Console wizard check (see testing/README.md). Runs a sandboxed copy of
# /usr/local/bin/go-euc-console-wizard.sh with scripted answers: paths are redirected to a temp
# dir and the final reboot is disabled, so the appliance is not changed.
# Run as root on the appliance: ssh ... 'sudo bash -s' < wizard_check.sh

set -u
pass=0; fail=0
ok()  { echo "PASS  $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
sed -e "s|^CONFIG_FILE=.*|CONFIG_FILE=\"${T}/config.env\"|" \
    -e "s|^MARKER_FILE=.*|MARKER_FILE=\"${T}/console-config.done\"|" \
    -e 's|^reboot$|echo REBOOT-SKIPPED|' \
    -e 's|^sleep 3$|:|' \
    /usr/local/bin/go-euc-console-wizard.sh > "${T}/wizard.sh"

GOOD_PW="Str0ng pass\$word'x"
# hostname, interface (default), static IP (blank -> re-asked), gateway, DNS (default),
# passwords: too short, the default, a mismatch, then a valid one confirmed.
answers="$(printf '%s\n' \
  "wizard-test" "" "" "10.9.8.7/24" "10.9.8.1" "" \
  "short" \
  "goeucadmin" \
  "${GOOD_PW}" "different" \
  "${GOOD_PW}" "${GOOD_PW}")"
out="$(bash "${T}/wizard.sh" <<<"${answers}" 2>&1)"

grep -q "Static IP is required" <<<"${out}" && ok "blank static IP is rejected" || bad "blank static IP not rejected"
grep -q "at least 8 characters" <<<"${out}" && ok "short password rejected" || bad "short password not rejected"
grep -q "other than the default" <<<"${out}" && ok "default password rejected" || bad "default password not rejected"
grep -q "Passwords do not match" <<<"${out}" && ok "password mismatch rejected" || bad "password mismatch not rejected"
grep -q "REBOOT-SKIPPED" <<<"${out}" && ok "wizard completed" || bad "wizard did not complete: $(tail -3 <<<"${out}" | tr '\n' ' ')"
[[ -f "${T}/console-config.done" ]] && ok "marker written" || bad "marker missing"
[[ "$(stat -c %a "${T}/config.env" 2>/dev/null)" == 600 ]] && ok "config.env mode 600" || bad "config.env mode $(stat -c %a "${T}/config.env" 2>/dev/null)"
(
  # shellcheck source=/dev/null
  source "${T}/config.env"
  [[ "${APPLIANCE_LOGIN_PASSWORD}" == "${GOOD_PW}" ]] || exit 1
  [[ "${APPLIANCE_NAME}" == "wizard-test" && "${APPLIANCE_STATIC_IP_CIDR}" == "10.9.8.7/24" && "${APPLIANCE_GATEWAY}" == "10.9.8.1" ]] || exit 1
) && ok "config.env round-trips values (password with space, \$ and ')" || bad "config.env values wrong after sourcing"

echo "===== result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
