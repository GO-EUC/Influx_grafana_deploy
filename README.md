# GO-EUC Virtual Appliance

This repository builds and publishes a deployable OVA virtual appliance that installs and configures:

- Portainer CE
- InfluxDB 2.x
- Grafana
- dashboard provisioning
- downloadable Telegraf Windows client/config bundle over HTTP

The preferred way to use this project is the appliance image, not running the installer script manually.

## What the appliance contains

The appliance is built from Ubuntu Noble cloud image and includes:

- build-time injected assets:
  - `scripts/step1_install_base.sh`
  - `Dashboards.zip`
  - `Telegraf/*`
  - first-boot and maintenance services under `appliance/firstboot/` and `appliance/maintenance/`
- first-boot automation:
  - `go-euc-firstboot.service` (main provisioning orchestrator)
  - `go-euc-autogrow.service` (disk/filesystem growth fallback)
  - `go-euc-ensure-ssh.service` (SSH availability safety net)
  - `go-euc-webfiles.service` (port 80 file host)
- credential and status output:
  - `/opt/influx-grafana/credentials.env`
  - `/opt/influx-grafana/install-summary.txt`
  - `/var/log/go-euc-install.log`
  - `/etc/issue` status banner (`PENDING-CONSOLE-CONFIG`, `INITIALIZING`, `COMPLETE`, `FAILED`)

## Installation and first-boot flow

1. Deploy the generated OVA in your hypervisor.
2. Boot the VM and log in on local console.
3. The console wizard (`go-euc-console-wizard.sh`) prompts for:
   - hostname
   - interface
   - static IP/CIDR
   - gateway
   - DNS
   - optional appliance admin password
4. Wizard writes `/etc/go-euc/config.env`, marks config complete, and reboots.
5. On reboot, first-boot provisioning runs automatically:
   - network/host setup
   - Docker install
   - Portainer + InfluxDB + Grafana deployment
   - Influx buckets creation (`Performance`, `Tests`)
   - datasource and dashboards provisioning
6. Completion details are written to console and summary files.

Optional: you can pre-seed or manually edit `/etc/go-euc/config.env` using `appliance/firstboot/config.env.example`.

## Service endpoints after provisioning

- Portainer: `https://<appliance-ip>:9443`
- InfluxDB: `http://<appliance-ip>:8086`
- Grafana: `http://<appliance-ip>:3000`
- Web file host: `http://<appliance-ip>:80`

## Telegraf download over web UI (port 80)

The built-in web file host serves `/opt/influx-grafana/public/`, including:

- `/telegraf/telegraf-*_windows_amd64.zip` (latest Telegraf Windows x64 package)
- `/telegraf/telegraf_windows_amd64_latest.zip` (stable filename pointer to latest package)
- `/telegraf/telegraf.exe` (extracted from the downloaded zip for direct download)
- `/telegraf/telegraf.conf`
- `/telegraf/telegraf_vsphere.conf`
- `/config.txt` (temporary post-install config summary)

`telegraf.conf` files are tokenized at runtime with:

- Influx org
- Influx URL (`http://<appliance-ip>:8086`)
- generated Influx token

The default web page (`http://<appliance-ip>/`) includes a **Fetch latest Telegraf Windows package** button that triggers an on-demand refresh API (`POST /api/refresh-telegraf`) and repopulates `/telegraf/`.

The same page also includes **Run Full Appliance Update** (`POST /api/full-update`) which performs:

- Ubuntu package update/upgrade on the VM
- container image refresh/redeploy (`influxdb`, `grafana`, `portainer`)
- dashboard bundle refresh from configured dashboard URL
- Telegraf package/executable refresh in `/telegraf/`

For Windows install steps, see `Telegraf/WINDOWS_INSTALL.md`.

## Build and release workflow

Workflow file: `.github/workflows/build-appliance.yml`

Triggers:

- push to `dev`: build appliance + upload workflow artifacts
- push to `main`: build appliance + auto-create next GitHub Release (`v1.0`, `v1.1`, `v1.2`, ...)
- manual run: `workflow_dispatch`

Release assets:

- `go-euc-appliance-<timestamp>-<sha>.ova`
- `go-euc-appliance-<timestamp>-<sha>.vhd`
- matching `.sha256` for each image format

The workflow uses GitHub Releases (not Azure blob storage).

## Local build (optional)

From repo root:

```bash
bash appliance/build-appliance.sh
```

Output is written to `dist/`.
