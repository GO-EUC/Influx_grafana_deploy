#!/usr/bin/env bash
# Backup/restore check, run from a client machine (see testing/README.md): restore a
# go-euc-backup.sh archive (taken on another appliance) onto <appliance-ip> and verify it.
#
#   testing/checks/backup_restore_checks.sh <appliance-ip> <backup.tar.gz>
#
# Verifies: every backed-up point is present in the target (in the target's own org), collector
# settings restored and enabled collectors running, Grafana database restored with the admin
# password reset to the target's, and a second restore is harmless (idempotent).

set -u
IP="${1:?usage: $0 <appliance-ip> <backup.tar.gz>}"
BACKUP="${2:?usage: $0 <appliance-ip> <backup.tar.gz>}"
DIR="${GOEUC_TEST_DIR:-$HOME/.goeuc-test}"
pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
info() { echo "INFO  $*"; }
SSH=(ssh -i "${DIR}/id_goeuc_test" -o UserKnownHostsFile="${DIR}/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "goeucadmin@${IP}")

expected="$(tar -xzOf "${BACKUP}" ./manifest.json | python3 -c 'import json,sys
m = json.load(sys.stdin)
print(" ".join("%s=%s" % (b["name"], b["points"]) for b in m["buckets"]))')"
info "backup contents: ${expected}"

"${SSH[@]}" "sudo install -m 600 /dev/stdin /root/restore-test.tar.gz" < "${BACKUP}" && ok "backup uploaded" || bad "upload failed"

echo "===== restore (with Grafana)"
out="$("${SSH[@]}" "sudo go-euc-restore.sh /root/restore-test.tar.gz --with-grafana" 2>&1)"
echo "${out}" | sed 's/^/      | /' | grep -vE ' I! | W! ' | tail -20
grep -q "^\[restore\] Done" <<<"${out}" && ok "go-euc-restore.sh completed" || bad "go-euc-restore.sh did not complete"

count_points() {
  "${SSH[@]}" "sudo bash -c 'source /opt/influx-grafana/credentials.env; docker exec influxdb influx query --org \"\${SAVED_INFLUX_ADMIN_ORG}\" --token \"\${SAVED_INFLUX_ADMIN_TOKEN}\" --raw \"from(bucket: \\\"$1\\\") |> range(start: 0) |> count() |> group() |> sum()\"'" 2>/dev/null \
    | awk -F, '$0 !~ /^#/ && NF > 3 && $NF ~ /^[0-9]+\r?$/ {gsub("\r", "", $NF); print $NF}' | tail -1
}
for pair in ${expected}; do
  bucket="${pair%%=*}"; want="${pair#*=}"
  [[ "${want}" == 0 ]] && continue
  got="$(count_points "${bucket}")"
  [[ -n "${got}" && "${got}" -ge "${want}" ]] && ok "bucket ${bucket}: ${got} points (backup had ${want})" || bad "bucket ${bucket}: ${got:-0} points, backup had ${want}"
done

for t in $(tar -tzf "${BACKUP}" | sed -n 's#^\./settings/collector-\(.*\)\.env$#\1#p'); do
  enabled="$(tar -xzOf "${BACKUP}" "./settings/collector-${t}.env" | grep -c '^COLLECTOR_ENABLED=true$')"
  st="$("${SSH[@]}" "sudo docker inspect -f '{{.State.Status}}' telegraf-${t} 2>/dev/null | grep . || echo not-created")"
  if [[ "${enabled}" == 1 ]]; then
    [[ "${st}" == running ]] && ok "collector ${t} restored and running" || bad "collector ${t} enabled in backup but ${st}"
  else
    [[ "${st}" == not-created ]] && ok "collector ${t} restored (stopped, as in backup)" || bad "collector ${t} stopped in backup but ${st}"
  fi
done

gl="$("${SSH[@]}" "sudo bash -c 'source /opt/influx-grafana/credentials.env; curl -s -o /dev/null -w %{http_code} -u \"\${SAVED_GRAFANA_ADMIN_USER}:\${SAVED_GRAFANA_ADMIN_PASSWORD}\" http://127.0.0.1:3000/grafana/api/user'")"
[[ "${gl}" == 200 ]] && ok "Grafana admin login with this appliance's password after DB restore" || bad "Grafana admin login after restore -> ${gl}"
ds="$("${SSH[@]}" "sudo bash -c 'source /opt/influx-grafana/credentials.env; curl -s -u \"\${SAVED_GRAFANA_ADMIN_USER}:\${SAVED_GRAFANA_ADMIN_PASSWORD}\" http://127.0.0.1:3000/grafana/api/datasources/uid/DS_GO/health'" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' 2>/dev/null)"
[[ "${ds}" == OK ]] && ok "Grafana datasource DS_GO healthy after DB restore (provisioned for this appliance)" || bad "DS_GO health after restore: ${ds}"

echo "===== second restore (idempotent)"
before="$(count_points Performance)"
"${SSH[@]}" "sudo go-euc-restore.sh /root/restore-test.tar.gz" >/dev/null 2>&1 && ok "second restore completed" || bad "second restore failed"
after="$(count_points Performance)"
info "Performance points before/after second restore: ${before} / ${after} (only new collector points may be added)"
[[ -n "${after}" && "${after}" -ge "${before:-0}" ]] && ok "no data lost on re-restore" || bad "Performance count dropped: ${before} -> ${after}"
"${SSH[@]}" "sudo rm -f /root/restore-test.tar.gz"

echo "===== result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
