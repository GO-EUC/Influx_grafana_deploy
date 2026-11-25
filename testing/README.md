# GO-EUC appliance testing

This folder holds the end-to-end test for the GO-EUC appliance:
1. deploy a CI-built image to Nutanix AHV, unattended
2. let first boot provision it
3. check every feature from the appliance itself and from a client machine

It was written to verify the security hardening, the infrastructure collectors (vSphere, Nutanix Prism Element, Proxmox VE) and the reorganised landing page. Run it against every build you plan to release.

## Contents

| Path | Runs on | Purpose |
|------|---------|---------|
| `nutanix.env.example` | – | Template for the test settings file (`~/.goeuc-test/nutanix.env`). |
| `nutanix/deploy.py` | client | Imports the VHD into Prism Element from a URL, creates the VM with cloud-init setup data, powers it on. |
| `nutanix/wait_for_provisioning.sh` | client | Waits for SSH and first boot; prints each banner/service state change, exits when `/var/lib/go-euc/.installed` appears or the banner shows `FAILED`. |
| `nutanix/prism.py` | client | `list` (cluster, networks, containers, test VMs/images), `vm <name>`, `teardown <name>`. |
| `checks/remote_checks.sh` | appliance (root) | Provisioning, file permissions, credentials, containers, listening ports, `nginx -t`, InfluxDB buckets and token scopes, Grafana datasource/dashboards, rendered Telegraf downloads. |
| `checks/http_checks.sh` | client | HTTPS redirect, login on the landing page, `/telegraf/` and `/api/`, the `config.txt` subnet rule, proxied services, closed direct ports, API routing and input validation. |
| `checks/collector_checks.sh` | client | Starts the Nutanix collector against a real Prism Element and checks `nutanix_host` data in InfluxDB. Checks that vSphere and Proxmox fail cleanly against unreachable addresses, and that a blank password keeps the saved one. |
| `checks/wizard_check.sh` | appliance (root) | Runs a sandboxed copy of the console wizard with scripted answers: validation, `config.env` quoting, marker. |
| `checks/migrate_checks.sh` | client | Runs `go-euc-migrate <old>` on the new appliance. Checks every old point arrived (across orgs), hand-made dashboards were copied, preloaded ones weren't duplicated, the old appliance is unchanged, and a re-run is harmless. |
| `checks/backup_restore_checks.sh` | client | Restores a `go-euc-backup.sh` archive from another appliance (`--with-grafana`). Checks every point arrived in the target's own org, collectors restored, Grafana login and data source after the DB restore, and that a second restore is harmless. |
| `checks/maintenance_checks.sh` | client | Fetch latest Telegraf, **Run Full Appliance Update**, reboot, and every on-box check again. |
| `checks/public_checks.sh` | client | Through the appliance's public host name (router forward or reverse proxy): certificate, logins, every service, `config.txt` and `:8086` not reachable, 20 MB upload not refused, WebSocket upgrade, and a write through the name that lands in this appliance's InfluxDB. Needs NAT loopback, or run it from outside. |
| `checks/ports_checks.sh` | client | Switches the web ports to the alternative 8080/4443 through the landing page API, checks every route, the redirect, the old port closed, Telegraf configs, `config.txt`, `config.env`, Compose and `go-euc-status`; switches back to 80/443 with `go-euc-set-ports` and checks again. |

Every check prints `PASS`, `FAIL` or `INFO`, and nothing prints passwords or tokens. Secrets are read from files and handed to `curl` through temporary config files, so they never appear on the command line.

## Prerequisites

- A client machine (macOS or Linux) with `python3`, `curl`, `openssl`, `ssh` and network access to Prism Element and the appliance subnet.
- A Prism Element (AHV) account that can create images and VMs, plus an account for the Nutanix collector (the Viewer role is enough).
- A CI build of the appliance. Push to `dev` and copy the `.vhd` URL from the workflow's **Print Azure Blob download URLs** step.
- The settings file:

  ```bash
  mkdir -p ~/.goeuc-test && chmod 700 ~/.goeuc-test
  cp testing/nutanix.env.example ~/.goeuc-test/nutanix.env && chmod 600 ~/.goeuc-test/nutanix.env
  # edit ~/.goeuc-test/nutanix.env
  python3 testing/nutanix/prism.py list      # shows the exact AHV network and container names
  ```

  `deploy.py` creates a throwaway SSH key (`~/.goeuc-test/id_goeuc_test`) and a random appliance password (`~/.goeuc-test/goeucadmin.password`) on first use. Set `GOEUC_TEST_DIR` to keep them somewhere else.

## Unattended setup (instead of the console wizard)

The console wizard only writes `/etc/go-euc/config.env` and the marker `/var/lib/go-euc/console-config.done`. `deploy.py` passes cloud-init user-data (an AHV config drive) that does the same before first boot starts. Cloud-init finishes before `network-online.target`, which is what `go-euc-firstboot.service` waits for. It:

- writes `/etc/go-euc/config.env` with the hostname (the VM name), static IP, gateway, DNS and the `goeucadmin` password
- writes the wizard marker, so first boot provisions on its first run without the console wizard or its reboot
- creates `goeucadmin` with the test SSH key and `NOPASSWD` sudo; first boot then adds the password and groups

Everything after that is the normal first-boot code path. The wizard itself is covered by `checks/wizard_check.sh`, plus a short manual check (below).

## Running the test

```bash
VHD_URL="https://<storage-account>.blob.core.windows.net/appliances/go-euc-appliance-<build>.vhd"
VM=goeuc-appliance-test-<build-sha>
IP=192.168.102.130                         # APPLIANCE_IP_CIDR without the prefix
SSH="ssh -i ~/.goeuc-test/id_goeuc_test -o UserKnownHostsFile=$HOME/.goeuc-test/known_hosts -o StrictHostKeyChecking=accept-new goeucadmin@$IP"

# 1. Deploy (image import ~1-2 min, VM create + power on <1 min)
python3 testing/nutanix/deploy.py "$VHD_URL" "$VM" '<AHV network name>' 4 8192

# 2. Wait for provisioning (~10-20 min): banner turns COMPLETE
testing/nutanix/wait_for_provisioning.sh "$IP"

# 3. Checks
$SSH "sudo EXPECTED_IP=$IP EXPECTED_HOST=$VM bash -s" < testing/checks/remote_checks.sh
$SSH 'sudo bash -s' < testing/checks/wizard_check.sh
testing/checks/http_checks.sh "$IP" 403     # 403: client NOT on the appliance subnet; use 200 if it is
testing/checks/collector_checks.sh "$IP"
testing/checks/ports_checks.sh "$IP"          # standard -> alternative (8080/4443) -> standard
testing/checks/public_checks.sh goeuc.example.com "$IP"   # only when a public name points at the appliance
testing/checks/maintenance_checks.sh "$IP" "$VM"   # long: full update upgrades Ubuntu packages, then reboots

# Moving data: back up a source appliance, restore it onto this one
$SSH_OLD 'sudo go-euc-backup.sh'      # then copy /var/backups/go-euc/*.tar.gz to the client
testing/checks/backup_restore_checks.sh "$IP" ./go-euc-backup-<host>-<time>.tar.gz

# 4. Clean up (or keep the VM to look around)
python3 testing/nutanix/prism.py teardown "$VM"
```

The appliance login for the landing page is `goeucadmin` with the password in `~/.goeuc-test/goeucadmin.password`.

## Scenarios

`deploy.py` options for testing behaviour that a default deployment doesn't exercise:

| Scenario | How | Expected |
|---|---|---|
| Non-default InfluxDB org (e.g. the GO-EUC lab's `GO`) | `GOEUC_DEPLOY_EXTRA_CONFIG='INFLUX_ADMIN_ORG=GO' python3 testing/nutanix/deploy.py ...` | Provisioning completes; `SAVED_INFLUX_ADMIN_ORG=GO`; every check passes |
| Switching appliances (new IP) | Deploy a second appliance with `GOEUC_DEPLOY_IP_CIDR`, then `testing/checks/migrate_checks.sh <new-ip> <old-ip>` | 9/9 pass; data and hand-made dashboards on the new appliance |
| Switching appliances (same IP) | After the migration: `python3 testing/nutanix/prism.py poweroff <old-vm>`, then on the new appliance `sudo go-euc-change-ip <old-ip>/<prefix>`; then `http_checks.sh <old-ip>` | New appliance answers on the old address; subnet list, Telegraf downloads and `config.txt` show the new address |
| No internet access during first boot | `GOEUC_DEPLOY_DNS=192.0.2.53 python3 testing/nutanix/deploy.py ...` (unreachable DNS server) | `wait_for_provisioning.sh` reports `FAILED`; the banner says `No internet access: cannot reach ...`; nothing was installed (`go-euc-status` shows docker missing) |

## Manual checks

A few things can't be scripted against the test environment:

| Area | How to check |
|------|--------------|
| Console wizard on a real console | Deploy without `deploy.py`'s cloud-init data (import the VHD by hand). Log in on the VM console as `goeucadmin` / `goeucadmin`, complete the wizard, and confirm it reboots into provisioning. |
| Landing page in a browser | Open `https://<ip>/`. Check every section renders, the collector cards show live status, actions write to the Activity panel, and the Proxmox card's Metric Server panel fills in. |
| `config.txt` from the appliance subnet | From a machine on the appliance's subnet, `https://<ip>/config.txt` opens without a login (the client check expects 403 when run from another subnet). |
| Windows Telegraf client | Install the package and `telegraf.conf` from `/telegraf/` on a Windows VM (see `Telegraf/WINDOWS_INSTALL.md`) and confirm data arrives in the `Performance` bucket. |
| vSphere and Proxmox VE collectors | Configure them against a real vCenter / Proxmox VE with read-only credentials; the badge turns *running* and data appears. |
| Proxmox Metric Server | Run the `pvesh` command from the Proxmox card on a Proxmox node; data arrives in the `Proxmox` bucket. |
| Let's Encrypt | Needs a public DNS name pointing at the appliance. |

## Test runs

Environment for both runs:
- Nutanix cluster NCE1: AOS 6.8.1, AHV, 1 node
- VM: 4 vCPU, 8 GiB, AHV network `192.168.102.1/24` (VLAN 102), static IP `192.168.102.130/24`
- Client: macOS on `192.168.2.0/24`, a different subnet from the appliance, so `/config.txt` must return 403
- Collector target: the cluster's Prism Element

### 2026-11-25 run 1: build `20261125-143650-9ccba7a1` (commit `9ccba7a`): failed, bugs fixed

Deployment and unattended setup worked: image import 78 s, provisioning complete about 5 minutes after power-on. The checks found:

| Area | Finding | Fix |
|------|---------|-----|
| InfluxDB API | `/influx/*` returned the InfluxDB web UI (200 HTML) for every request, because InfluxDB 2.7 has no base-path setting. Telegraf clients, collectors and Proxmox push all silently failed, and the installer's health check was fooled too. | nginx strips `/influx` for the API; UI and API over TLS on `:8086`; collectors write to `influxdb:8086`; health via `influx ping`. |
| Landing page API | Every `/api/*` call returned 502: nginx used the Docker gateway, but the backend only listened on `127.0.0.1`. | nginx reaches the backend through a Unix socket shared only with its container. |
| Portainer | `/portainer/` returned 404 (`--base-url` only affects generated links). | nginx strips the prefix and adds WebSocket headers. |
| Collectors | Telegraf 1.40 rejected the configs: strict environment handling only substitutes inside quoted strings, and inserts values raw. | Raw env values; TLS setting rendered into the config. |
| Grafana | 5 of 6 dashboards: `GO-EUC-Windows-Process-Analysis.json` is a bare v2 spec; the Test Runs dashboard reused the Process Analysis title. | `go-euc-grafana-dashboards.py` wraps bare v2 specs; title fixed in `Dashboards.zip`. |
| Test suite | `config.txt` group is gid 101, which the host names `messagebus`. | Check compares numeric ids. |

Console wizard (sandboxed): 8/8 passed.

### 2026-11-25 run 2: build `20261125-151739-c4f1c519` (commit `c4f1c51`): passed

Provisioning complete 255 s after power-on (unattended).

| Suite | Result |
|-------|--------|
| `remote_checks.sh` (on-box) | 84 passed, 0 failed |
| `http_checks.sh` (client) | 49 passed, 0 failed |
| `wizard_check.sh` | 8 passed, 0 failed |
| `collector_checks.sh` | 17 passed, 0 failed (after the pre-flight fix below) |
| `maintenance_checks.sh` | Telegraf refresh, full update (77 s), collector refresh and reboot all passed. On-box checks after the reboot: 84 passed, 0 failed (after the bundle-aware dashboard check below). |

Nutanix collector against the real Prism Element: one `nutanix_host` series for host `NTNX-e109371f-A`, all 27 fields stored as numbers. That's the 21 from the API plus the 6 derived `*_pct` / `*_Bps` / `memory_used_bytes` fields, for example `cpu_usage_pct` 7.1, `memory_usage_pct` 32.4, `vm_count` 15, `storage_usage_pct` 7.7.

Found and fixed during run 2, verified on the running appliance (hot-patched), and included in the next build:
- **An unreachable vCenter looked healthy.** The vSphere plugin only connects on its first collection, after the 45 s startup check. Collectors now run a pre-flight check (vCenter reachability and TLS; Prism Element login). The unreachable vCenter now fails in seconds with "Cannot reach ... collector not started".
- **Test-only:** the full update correctly switched Grafana to the *published* bundle (`files/Dashboards.zip`, dated 2026-03-28: Analyzing, Comparing New, Troubleshooting). The dashboard check now compares Grafana with the bundle files actually on disk, not a fixed count of 6.

### 2026-11-25 run 3: build `20261125-155700-ea4ae295` (commit `ea4ae29`): passed after fixes

- VM #3, `INFLUX_ADMIN_ORG=GO`: provisioned in 129 s with org `GO`. On-box 88/88, HTTP 49/49, wizard 8/8, collectors 18/18. Restoring VM #2's backup (org `monitoring`) passed 11/11. Full update and reboot passed, and on-box was 88/88 afterwards (after the `go-euc-status` fix below).
- VM #4, unreachable DNS server: the banner showed `FAILED: No internet access: cannot reach …` and nothing was installed. After fixing the DNS in `config.env` and rebooting, setup resumed and completed by itself.

Found and fixed:

| Finding | Fix |
|---|---|
| **Portainer admin never created**: Portainer 2.45 requires a one-time setup token (403), then locks itself after 5 minutes. Run 2's HTTP check passed only because it ran inside that window. | Installer reads `setup_token=` from Portainer's log; checks for an existing admin; retries after a restart. Regression checks added. |
| **SSH password login never worked**: the cloud image's `60-cloudimg-settings.conf` overrides `sshd_config`. | `10-go-euc.conf` drop-in; check of the effective `sshd -T` setting. |
| Internet check took ~12.5 minutes to give up (sequential 10 s probes × 12 attempts); banner showed DNS `127.0.0.53`. | Parallel probes, 2-minute deadline, progress on the banner, real DNS servers. |
| `go-euc-status` flagged the collector after an update: transient write errors while InfluxDB restarted. | Errors in the 2 minutes after InfluxDB starts are ignored (Telegraf retries them). |
| `go-euc-migrate` restored nothing: `influx restore --org` is the *original* org. | `--org <old> --new-org <new>`. |

Switching tests (VM #3 as old at `.130`, org `GO`; VM #4 as new at `.131`, org `monitoring`): `migrate_checks.sh` passed 9/9 (all points, the hand-made dashboard, old appliance unchanged, re-run harmless). Then VM #3 was powered off, and `go-euc-change-ip 192.168.102.130/24` moved VM #4 onto the old address, with the subnet list, Telegraf downloads, `config.txt` and banner updated. HTTP was 49/49 at the new address.

### 2026-11-25 run 4: build `20261125-162413-e75d1ce5` (commit `e75d1ce`): passed

Fresh VM #5 (`.131`), provisioned in 129 s.

| Suite | Result |
|-------|--------|
| `remote_checks.sh` | 89 passed, 0 failed (incl. SSH password login, Portainer admin, `go-euc-status`) |
| SSH password login from a client (no key) | OK |
| `http_checks.sh` | 49 passed, 0 failed |
| `wizard_check.sh` | 8 passed, 0 failed |
| `collector_checks.sh` | 18 passed, 0 failed |
| `migrate_checks.sh` (old = VM #4, previous build `ea4ae295`) | 9 passed, 0 failed |
| `maintenance_checks.sh` | update (75 s) and reboot passed; on-box after reboot 89/89 (after counting only file-provisioned dashboards: migrated ones live alongside them) |

Open items:
- ~~Dashboard bundles differ~~: resolved for v2.0. *Troubleshooting* was added to the repo's `Dashboards.zip` (data source placeholder resolved). All 7 dashboards were verified to provision on the final build with no errors.
- **Switching from appliances built before November 2026** (InfluxDB on `http://<old>:8086`, token in the old `config.txt`'s Telegraf section) is implemented but not yet tested on a real old appliance.
- Not covered by this environment: the manual checks above (real console wizard, browser walkthrough, `config.txt` from the appliance subnet, Windows client, real vCenter / Proxmox VE, Proxmox Metric Server push, Let's Encrypt).

### 2026-11-25 run 5: build `20261125-225247-9566c857` (commit `9566c85`): passed

Web ports option, `/api/v2` route, and access through a public host name. Fresh VM #6 (`.130`). The public name pointed at a reverse proxy (Nginx Proxy Manager style: one host name to `https://<appliance>:443`, the proxy holds the Let's Encrypt certificate), on a different subnet from the appliance.

| Suite | Result |
|-------|--------|
| `remote_checks.sh` | 90 passed, 0 failed (incl. a write through `/api/v2` on the appliance) |
| `wizard_check.sh` | 8 passed, 0 failed |
| `http_checks.sh` | 58 passed, 0 failed |
| `ports_checks.sh` | 49 passed, 0 failed (standard → alternative through the landing page API → standard with `go-euc-set-ports`) |
| `collector_checks.sh` | 18 passed, 0 failed |
| `public_checks.sh <public-name> <ip>` | 24 passed, 0 failed (Let's Encrypt certificate on the proxy, logins, all services, `config.txt` 403, `:8086` closed, 20 MB write not refused, WebSocket reaches Portainer, writes via `/influx` and `/api/v2` land in this appliance) |

Found during development, before this build: `go-euc-set-ports` didn't update `HTTPPort`, `HTTPSPort` and the Proxmox Metric Server `Port` inside `config.txt` (found with a hot-patched run-4 appliance; fixed).

Open items:
- Grafana's own URL is `http://localhost/grafana/` (`GF_SERVER_ROOT_URL` with the default domain). Navigation uses relative paths and works everywhere, but links Grafana generates (*Share → Copy link*, alert notifications) show `localhost`.
- The landing page's InfluxDB tile links to `:8086`, which isn't reachable through a public name or reverse proxy. Expected and documented; the InfluxDB API works through `/influx` and `/api/v2`.
