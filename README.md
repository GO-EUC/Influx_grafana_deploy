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
  - includes `go-euc-ensure-ssh.service` to keep SSH available even if provisioning fails

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

### Console-first network setup

The appliance now uses a first-console-login wizard (no OVA property prompts required):

- On first local console login, `go-euc-console-wizard.sh` prompts for:
  - hostname
  - network interface
  - static IP (CIDR)
  - gateway
  - DNS servers
  - optional new password for `goeucadmin` (leave blank to keep default)
- Wizard writes `/etc/go-euc/config.env`, marks setup complete, and reboots.
- After reboot, firstboot provisioning runs using those values.

Optional fallback:
- You can still edit `/etc/go-euc/config.env` manually.
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

The login banner (`/etc/issue`) now shows:
- `INITIALIZING` during provisioning
- `COMPLETE` with runtime network details after provisioning
- `FAILED` with error context if provisioning exits unexpectedly

### Built-in web file host (port 80)

The appliance runs a simple web server on port `80` serving:

- directory listing of `/opt/influx-grafana/public/`
- `/opt/influx-grafana/public/config.txt`
- `/opt/influx-grafana/public/telegraf/*`

`config.txt` includes appliance/service credentials and is automatically deleted on the first reboot after setup completion.

Telegraf artifacts:
- latest Windows x64 Telegraf package (`*_windows_amd64.zip`) is downloaded into `/opt/influx-grafana/public/telegraf/`
- `telegraf.conf` and `telegraf_vsphere.conf` are copied from `Telegraf/` and placeholders are replaced with:
  - `TELEGRAF_ORGANISATION` = Influx organization
  - `TELEGRAF_URL` = `http://<appliance-ip>:8086`
  - `TELEGRAF_TOKEN` = generated Influx token

### Break-glass login

The image includes a fixed recovery account available immediately at first boot:

- Username: `recovery`
- Password: `Recover-ChangeMe-Now!`

This is intended for emergency access only; rotate or disable after deployment.

Optional override values:
- `BREAK_GLASS_USER`
- `BREAK_GLASS_PASSWORD`
