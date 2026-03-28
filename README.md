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
  - `go-euc-webfiles.service` (local API backend behind nginx)
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

- Appliance landing page: `https://<appliance-ip>/`
- Portainer: `https://<appliance-ip>/portainer/`
- InfluxDB: `https://<appliance-ip>/influx/`
- Grafana: `https://<appliance-ip>/grafana/`
- GO-EUC Web: `https://<appliance-ip>/goeucweb/`
- Legacy direct access remains available:
  - Portainer: `https://<appliance-ip>:9443`
  - InfluxDB: `http://<appliance-ip>:8086/influx/`
  - Grafana: `http://<appliance-ip>:3000/grafana/`

## Telegraf download over appliance web UI (HTTPS)

Dockerized nginx serves `/opt/influx-grafana/public/`, including:

- `/telegraf/telegraf-*_windows_amd64.zip` (latest Telegraf Windows x64 package)
- `/telegraf/telegraf_windows_amd64_latest.zip` (stable filename pointer to latest package)
- `/telegraf/telegraf.exe` (extracted from the downloaded zip for direct download)
- `/telegraf/telegraf.conf`
- `/telegraf/telegraf_vsphere.conf`
- `/telegraf/WINDOWS_INSTALL.md` (Windows deployment instructions)
- `/telegraf/WINDOWS_INSTALL.html` (browser-friendly rendered view of the instructions)
- `/config.txt` (persistent post-install config summary with service endpoints)

`telegraf.conf` files are tokenized at runtime with:

- Influx org
- Influx URL (`https://<appliance-ip>/influx`)
- generated Influx token

The default web page (`https://<appliance-ip>/`) includes a **Fetch latest Telegraf Windows package** button that triggers an on-demand refresh API (`POST /api/refresh-telegraf`) and repopulates `/telegraf/`.

The same page also includes **Run Full Appliance Update** (`POST /api/full-update`) which performs:

- Ubuntu package update/upgrade on the VM
- migration of legacy compose files to include nginx reverse proxy + GO-EUC web services when missing
- container image refresh/redeploy (`influxdb`, `grafana`, `portainer`, `goeuc/webserver`)
- dashboard bundle refresh from configured dashboard URL
- Telegraf package/executable refresh in `/telegraf/`

It also includes **Renew Let's Encrypt Certificate** (`POST /api/renew-letsencrypt`) when Let's Encrypt settings are configured.
It also includes a **Let's Encrypt Setup** web form that accepts domain/email, writes them to appliance config, and immediately attempts certificate request + apply (`POST /api/configure-letsencrypt`).

## TLS certificates

The nginx front end always serves HTTPS and starts with a generated self-signed certificate.

Optional Let's Encrypt automation is enabled when both values are set in `/etc/go-euc/config.env`:

- `APPLIANCE_LETSENCRYPT_DOMAIN=appliance.example.com`
- `APPLIANCE_LETSENCRYPT_EMAIL=admin@example.com`

When configured:

- first-boot attempts automatic certificate issuance
- cert renewal is available from the web UI button
- the active nginx certificate switches from self-signed to Let's Encrypt

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

The appliance image is customized during build using `virt-customize` from libguestfs: [virt-customize documentation](https://libguestfs.org/virt-customize.1.html).

Output is written to `dist/`.
