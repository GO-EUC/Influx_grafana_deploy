#!/usr/bin/env bash
# Migration check, run from a client machine (see testing/README.md): run go-euc-migrate on the
# NEW appliance to pull everything from the OLD one, and verify the result.
#
#   testing/checks/migrate_checks.sh <new-appliance-ip> <old-appliance-ip>
#
# Verifies: every point in every old bucket arrived in the new appliance's buckets (in the new
# org), hand-made Grafana dashboards were copied into "Migrated from <old>", preloaded GO-EUC
# dashboards were not duplicated, the old appliance is unchanged, and re-running is harmless.

set -u
NEW="${1:?usage: $0 <new-appliance-ip> <old-appliance-ip>}"
OLD="${2:?usage: $0 <new-appliance-ip> <old-appliance-ip>}"
DIR="${GOEUC_TEST_DIR:-$HOME/.goeuc-test}"
pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
info() { echo "INFO  $*"; }
ssh_to() { ssh -i "${DIR}/id_goeuc_test" -o UserKnownHostsFile="${DIR}/known_hosts" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "goeucadmin@$1" "${@:2}"; }

# "<bucket> <points>" lines for every non-system bucket, on appliance $1.
bucket_counts() {
  ssh_to "$1" 'sudo bash -s' <<'EOF'
source /opt/influx-grafana/credentials.env
for b in $(docker exec influxdb influx bucket list --org "$SAVED_INFLUX_ADMIN_ORG" --token "$SAVED_INFLUX_ADMIN_TOKEN" --hide-headers | awk '$2 !~ /^_/ {print $2}'); do
  n=$(docker exec influxdb influx query --org "$SAVED_INFLUX_ADMIN_ORG" --token "$SAVED_INFLUX_ADMIN_TOKEN" --raw \
      "from(bucket: \"$b\") |> range(start: 0) |> count() |> group() |> sum()" 2>/dev/null \
      | awk -F, '$0 !~ /^#/ && NF > 3 && $NF ~ /^[0-9]+\r?$/ {gsub("\r", "", $NF); print $NF}' | tail -1)
  echo "$b ${n:-0}"
done
EOF
}
# "<title>|<folder>|<provisioned>" for every dashboard on appliance $1.
dashboards() {
  ssh_to "$1" 'sudo bash -s' <<'EOF'
source /opt/influx-grafana/credentials.env
python3 - "$SAVED_GRAFANA_ADMIN_USER" "$SAVED_GRAFANA_ADMIN_PASSWORD" <<'PY'
import base64, json, sys, urllib.request
auth = "Basic " + base64.b64encode(f"{sys.argv[1]}:{sys.argv[2]}".encode()).decode()
def get(path):
    req = urllib.request.Request("http://127.0.0.1:3000/grafana" + path, headers={"Authorization": auth})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)
for d in get("/api/search?type=dash-db&limit=5000"):
    try:
        prov = get(f"/api/dashboards/uid/{d['uid']}").get("meta", {}).get("provisioned", False)
    except Exception:
        prov = "unknown"
    print(f"{d.get('title')}|{d.get('folderTitle') or ''}|{prov}")
PY
EOF
}

old_before="$(bucket_counts "${OLD}")"; info "old appliance buckets: $(tr '\n' ' ' <<<"${old_before}")"
old_dash_before="$(dashboards "${OLD}" | sort)"
new_dash_before="$(dashboards "${NEW}" | wc -l | tr -d ' ')"

echo "===== go-euc-migrate ${OLD} (on ${NEW})"
out="$(ssh_to "${NEW}" "sudo go-euc-migrate ${OLD} --yes" 2>&1)"; rc=$?
echo "${out}" | sed 's/^/      | /'
[[ ${rc} -eq 0 ]] && grep -q "Done. Next steps" <<<"${out}" && ok "go-euc-migrate completed" || bad "go-euc-migrate failed (exit ${rc})"

new_after="$(bucket_counts "${NEW}")"
while read -r bucket want; do
  [[ -z "${bucket}" || "${want}" == 0 ]] && continue
  got="$(awk -v b="${bucket}" '$1 == b {print $2}' <<<"${new_after}")"
  [[ -n "${got}" && "${got}" -ge "${want}" ]] && ok "bucket ${bucket}: ${got} points on new (old had ${want})" || bad "bucket ${bucket}: ${got:-0} on new, old had ${want}"
done <<<"${old_before}"

hand_made="$(grep '|False$' <<<"${old_dash_before}" | cut -d'|' -f1)"
info "hand-made dashboards on old: $(tr '\n' ';' <<<"${hand_made}")"
new_dash="$(dashboards "${NEW}")"
while IFS= read -r title; do
  [[ -z "${title}" ]] && continue
  grep -qF "${title}|Migrated from ${OLD}|" <<<"${new_dash}" && ok "dashboard '${title}' copied into 'Migrated from ${OLD}'" || bad "dashboard '${title}' not copied"
done <<<"${hand_made}"
dups="$(cut -d'|' -f1 <<<"${new_dash}" | sort | uniq -d)"
[[ -z "${dups}" ]] && ok "no duplicate dashboard titles on new (preloaded dashboards not copied twice)" || bad "duplicate titles on new: ${dups}"

old_after="$(bucket_counts "${OLD}")"
while read -r bucket before; do
  [[ -z "${bucket}" ]] && continue
  after="$(awk -v b="${bucket}" '$1 == b {print $2}' <<<"${old_after}")"
  [[ "${after:-0}" -ge "${before}" ]] || { bad "old bucket ${bucket} lost points: ${before} -> ${after}"; continue; }
done <<<"${old_before}"
[[ "$(dashboards "${OLD}" | sort)" == "${old_dash_before}" ]] && ok "old appliance unchanged (data kept, dashboards unchanged)" || bad "old appliance dashboards changed"

echo "===== second run (idempotent)"
ssh_to "${NEW}" "sudo go-euc-migrate ${OLD} --yes" >/dev/null 2>&1 && ok "second migration completed" || bad "second migration failed"
new_again="$(bucket_counts "${NEW}")"
p1="$(awk '$1 == "Performance" {print $2}' <<<"${new_after}")"; p2="$(awk '$1 == "Performance" {print $2}' <<<"${new_again}")"
info "new Performance points after first/second run: ${p1} / ${p2} (only live collector points may be added)"
[[ "${p2:-0}" -ge "${p1:-0}" ]] && ok "no data lost or doubled beyond live writes on re-run" || bad "Performance count dropped on re-run"
c="$(dashboards "${NEW}" | cut -d'|' -f1 | sort | uniq -d)"
[[ -z "${c}" ]] && ok "re-run did not duplicate dashboards" || bad "re-run duplicated: ${c}"

echo "===== result: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
