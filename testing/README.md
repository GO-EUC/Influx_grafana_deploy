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
| `checks/maintenance_checks.sh` | client | Fetch latest Telegraf, **Run Full Appliance Update**, reboot, and every on-box check again. |

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
testing/checks/maintenance_checks.sh "$IP" "$VM"   # long: full update upgrades Ubuntu packages, then reboots

# 4. Clean up (or keep the VM to look around)
python3 testing/nutanix/prism.py teardown "$VM"
```

The appliance login for the landing page is `goeucadmin` with the password in `~/.goeuc-test/goeucadmin.password`.

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

### 2026-11-25: build `20261125-143650-9ccba7a1` (commit `9ccba7a`)

Environment:
- Nutanix cluster NCE1: AOS 6.8.1, AHV, 1 node
- VM: 4 vCPU, 8 GiB, AHV network `192.168.102.1/24` (VLAN 102), static IP `192.168.102.130/24`
- Client: macOS on `192.168.2.0/24`, a different subnet from the appliance, so `/config.txt` must return 403

Results: *in progress*
