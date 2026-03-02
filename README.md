# Influx Grafana Deploy

Automated Ubuntu installer for Docker, Portainer, InfluxDB 2.x, and Grafana with datasource and dashboard provisioning.

## What the installer does

The script `scripts/step1_install_base.sh` performs the following:

- Installs Docker Engine and Docker Compose plugin from the official Docker Ubuntu repository.
- Creates a shared Docker network: `monitoring_net`.
- Deploys Portainer CE container and initializes admin credentials automatically.
- Deploys InfluxDB 2.7 and Grafana using a generated compose file at:
  - `/opt/influx-grafana/stack/docker-compose.yml`
- Initializes Influx with:
  - admin username/password
  - org
  - initial bucket (`bootstrap`)
  - admin token
- Ensures these Influx buckets exist:
  - `Performance`
  - `Tests`
- Provisions Grafana datasource:
  - name: `DS_GO`
  - uid: `DS_GO`
  - type: InfluxDB (Flux)
- Downloads dashboards ZIP from the hardcoded URL in script and provisions dashboards from JSON files.
- Verifies Grafana datasource via API (fallback creation if missing).
- Prints service URLs, credential details, provisioning status, and readiness checks.

## Credentials and persistence

- Generated credentials are saved to:
  - `/opt/influx-grafana/credentials.env`
- On rerun, existing saved values are reused unless overridden with environment variables.

## Dashboard source URL

Dashboard ZIP source is currently hardcoded in the script:

- `DASHBOARDS_ZIP_URL="https://web.leeejeffries.com/Dashboards.zip"`

Update this value in `scripts/step1_install_base.sh` if the artifact location changes.

## Usage

From the repository root:

```bash
chmod +x scripts/step1_install_base.sh
sudo ./scripts/step1_install_base.sh
```

## Service endpoints

- Portainer: `https://<vm-ip>:9443`
- InfluxDB: `http://<vm-ip>:8086`
- Grafana: `http://<vm-ip>:3000`

## Notes

- Target OS: Ubuntu.
- Script must be run as root or with `sudo`.
- Re-running the script is supported (idempotent behavior for core setup/provisioning).

## Virtual Appliance Automation (GitHub Actions)

This repository now includes an automated OVA appliance build and publish flow.

### What gets built

- Base image: Ubuntu Noble cloud image
- Disk size: fixed to a minimum of `100GB` at build time
- Injected assets:
  - `scripts/step1_install_base.sh`
  - `Dashboards.zip`
  - first-boot service files under `appliance/firstboot/`
- First boot behavior:
  - `go-euc-firstboot.service` runs once at boot
  - executes installer and writes `/var/lib/go-euc/.installed`
  - logs to `/var/log/go-euc-install.log`
  - supports appliance identity/network config from `/etc/go-euc/config.env`
  - includes cloud-init growpart config so root filesystem can expand when virtual disk grows
  - includes `go-euc-autogrow.service` for boot-time fallback resize of root partition/filesystem

### Build script (local/manual)

```bash
bash appliance/build-appliance.sh
```

Artifacts are created in `dist/`:
- `go-euc-appliance-<timestamp>-<sha>.ova`
- matching `.sha256` file

### GitHub Actions workflow

Workflow file: `.github/workflows/build-appliance.yml`

Triggers:
- On every push
- Manual run (`workflow_dispatch`)

Pipeline steps:
- Build appliance OVA
- Upload build files as GitHub Actions artifacts
- Upload OVA + checksum to Azure Blob Storage

### Required GitHub settings

Secrets:
- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Repository variables:
- `AZURE_STORAGE_ACCOUNT`
- `AZURE_STORAGE_CONTAINER`

### GitHub setup checklist

1. Add repository secrets:
   - `AZURE_CLIENT_ID`
   - `AZURE_TENANT_ID`
   - `AZURE_SUBSCRIPTION_ID`
2. Add repository variables:
   - `AZURE_STORAGE_ACCOUNT`
   - `AZURE_STORAGE_CONTAINER`
3. Commit and push this repository (workflow file must exist in GitHub).
4. Confirm Actions are enabled for the repository.
5. Trigger workflow:
   - push a commit, or
   - run manually from Actions > `Build Virtual Appliance`.

### GitHub Environment name

The workflow uses a GitHub Environment named:

- `appliance-build`

Make sure the required secrets and variables are set inside that environment.

The workflow job already includes:

```yaml
environment: appliance-build
```

### Appliance import customization (name/IP/DNS)

The OVA exposes import-time properties (vApp/OVF) so these values can be entered during hypervisor import:

- `APPLIANCE_NAME` or `APPLIANCE_HOSTNAME`
- `APPLIANCE_NET_IFACE` (optional; auto-detected if omitted)
- `APPLIANCE_STATIC_IP_CIDR` (example: `192.168.1.50/24`)
- `APPLIANCE_GATEWAY`
- `APPLIANCE_DNS` (comma-separated, example: `1.1.1.1,8.8.8.8`)

At first boot, the appliance reads OVF properties through VMware guestinfo and applies hostname/network automatically.

Optional fallback:
- You can still provide `/etc/go-euc/config.env` for non-OVF environments.
- Template: `appliance/firstboot/config.env.example`

### Upgrading container versions on appliance

Manual upgrade script on VM:

```bash
sudo /usr/local/bin/go-euc-upgrade.sh
```

This pulls latest images and redeploys:
- `influxdb`
- `grafana`
- `portainer/portainer-ce:latest`

Optional automatic upgrades:
- set `AUTO_UPGRADE_ENABLED=true` in `/etc/go-euc/config.env` before first boot
- first boot enables `go-euc-upgrade.timer` (daily)

### Credential display on appliance console

When first-boot setup completes, the appliance writes a credential summary to:

- `/dev/tty1` (VM console)
- `/dev/console`
- `/opt/influx-grafana/install-summary.txt`

It includes:
- Appliance login username/password
- Portainer credentials
- Influx credentials
- Grafana credentials

Optional appliance login override:
- `APPLIANCE_LOGIN_USER`
- `APPLIANCE_LOGIN_PASSWORD`

### Break-glass login

The image includes a fixed recovery account available immediately at first boot:

- Username: `recovery`
- Password: `Recover-ChangeMe-Now!`

This is intended for emergency access only; rotate or disable after deployment.
