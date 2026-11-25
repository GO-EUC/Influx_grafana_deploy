# GO-EUC Virtual Appliance

This repository builds and publishes the GO-EUC virtual appliance as an OVA (VMware) and a VHD (Hyper-V, Nutanix AHV and other hypervisors). The appliance installs and configures:

- Portainer CE, for managing all of the appliance's containers
- InfluxDB 2.x
- Grafana
- GO-EUC web container (`goeuc/webserver`)
- nginx HTTPS reverse proxy for all of the above
- dashboard provisioning
- downloadable Telegraf Windows client/config bundle over HTTPS
- optional infrastructure collectors for VMware vSphere, Nutanix Prism Element and Proxmox VE (Telegraf containers on the appliance), plus a ready-made Proxmox Metric Server target
- a landing page (`https://<appliance-ip>/`) that ties it all together

## Start here

- **New to the appliance?** Follow [docs/getting-started.md](docs/getting-started.md): requirements, download, import on VMware, Hyper-V, Nutanix or Proxmox, setup, first login, next steps and troubleshooting.
- **Download:** [Releases](https://github.com/GO-EUC/Influx_grafana_deploy/releases), with OVA (VMware) and VHD (Hyper-V, Nutanix AHV, Proxmox VE/KVM) links and checksums in each release.
- **How it fits together:** [docs/architecture.md](docs/architecture.md): ports, request routing, data flow, and what to forward on a router.
- **Reaching it from the internet:** [docs/external-access.md](docs/external-access.md): DNS, port forwarding (direct, through a reverse proxy such as nginx on Unraid, or on the alternative ports 8080/4443), Let's Encrypt.
- **Something not working?** Run `sudo go-euc-status` on the appliance; see [Troubleshooting](docs/getting-started.md#8-troubleshooting).
- **Moving to a new release?** Follow [docs/switching-appliances.md](docs/switching-appliances.md): deploy the new appliance, run `sudo go-euc-migrate <old-ip>` on it, switch clients over, switch the old one off.
- **What changed:** [CHANGELOG.md](CHANGELOG.md). **Building, releasing and testing the appliance:** [docs/development.md](docs/development.md), and [lessons.md](lessons.md) for pitfalls found along the way. Releases are created on demand from the workflow; see [Releasing](docs/development.md#releasing).

The rest of this README is the reference for each feature.

## What the appliance contains

The appliance is built from Ubuntu Noble cloud image and includes:

- build-time injected assets:
  - `scripts/step1_install_base.sh`
  - `Dashboards.zip`
  - `Telegraf/*`
  - first-boot and maintenance services under `appliance/firstboot/` and `appliance/maintenance/`
  - infrastructure collector Telegraf configs under `appliance/collectors/` (installed at `/opt/go-euc-installer/collectors/`)
- first-boot automation:
  - `go-euc-firstboot.service` (main provisioning orchestrator)
  - `go-euc-autogrow.service` (disk/filesystem growth fallback)
  - `go-euc-ensure-ssh.service` (SSH availability safety net)
  - `go-euc-webfiles.service` (API backend behind nginx: reached by nginx only through the Unix socket `/opt/influx-grafana/run/api.sock`; also `127.0.0.1:18080` for local use on the appliance)
- maintenance tools in `/usr/local/bin`:
  - `go-euc-appliance-update.sh` (full update), `go-euc-upgrade.sh` (container refresh, optional daily timer)
  - `go-euc-collector.sh` (infrastructure collectors)
  - `go-euc-publish-telegraf-config.sh` (renders the Telegraf downloads)
  - `go-euc-local-access.sh` (local-subnet allow-list for `config.txt`)
  - `go-euc-letsencrypt-deploy-hook.sh` (applies renewed certificates to nginx)
  - `go-euc-grafana-dashboards.py` (wraps bare Grafana v2 dashboard exports so file provisioning accepts them)
  - `go-euc-status` (one-command health check and troubleshooting pointers)
  - `go-euc-migrate` (copy all data and hand-made dashboards from an old appliance, over the network)
  - `go-euc-change-ip` (change the static IP address after setup, e.g. to take over an old appliance's address)
  - `go-euc-set-ports` (web server on the standard ports 80/443 or the alternative 8080/4443)
  - `go-euc-backup.sh` / `go-euc-restore.sh` (file-based backup and restore)
- credential and status output (all root-only, mode 600):
  - `/opt/influx-grafana/credentials.env`
  - `/opt/influx-grafana/appliance-login.env`
  - `/opt/influx-grafana/install-summary.txt` (`sudo cat` this for every login and token)
  - `/etc/go-euc/break-glass.env`
  - `/var/log/go-euc-install.log`
- `/etc/issue` status banner (`PENDING-CONSOLE-CONFIG`, `INITIALIZING`, `COMPLETE`, `FAILED`)

## Installation and first-boot flow

1. Deploy the generated image in your hypervisor: the OVA for VMware, or the VHD for Hyper-V or Nutanix AHV. For AHV, use Prism → Image Configuration → Upload Image → From URL with the VHD link, then create a VM with a disk cloned from the image. Minimum 2 vCPU / 4 GB RAM; use 4 vCPU / 8 GB if collectors will run.
2. Boot the VM and log in on the local console as `goeucadmin` / `goeucadmin`.
3. The console wizard (`go-euc-console-wizard.sh`) prompts for:
   - hostname
   - interface
   - static IP/CIDR
   - gateway
   - DNS
   - a new `goeucadmin` password (required, minimum 8 characters; also used for the web page login)
4. Wizard writes `/etc/go-euc/config.env`, marks config complete, and reboots.
5. On reboot, first-boot provisioning runs automatically:
   - network/host setup
   - Docker install
   - Portainer + InfluxDB + Grafana deployment
   - Influx buckets creation (`Performance`, `Tests`, `Proxmox`) and write-only tokens (Telegraf → `Performance`, Proxmox Metric Server → `Proxmox`)
   - datasource and dashboards provisioning
6. Completion details are written to the console once and to `/opt/influx-grafana/install-summary.txt`.

## Credentials and access

- `goeucadmin`: appliance console/SSH login (sudo) and the HTTP basic-auth login for the landing page, `/telegraf/` and `/api/` (`/config.txt` is local-subnet only, no login). The web login is stored separately as a hash, so if you later change the OS password, update the web login too (prompts for the new password):

  ```bash
  sudo sh -c 'printf "goeucadmin:%s\n" "$(openssl passwd -6)" > /opt/influx-grafana/nginx/auth/htpasswd'
  ```
- Break-glass account (`recovery`): a random password is generated per VM on first boot. It is shown on the local console banner only while setup is pending, running or failed; afterwards it is in `/etc/go-euc/break-glass.env`.
- Portainer, InfluxDB and Grafana admin passwords are random per VM and stored in the root-only files above. They are not published over HTTP.
- Infrastructure collector settings (including vCenter/Prism Element passwords and the Proxmox token secret) are kept root-only in `/etc/go-euc/collector-<type>.env` and `/etc/go-euc/telegraf-<type>.env`.
- `https://<appliance-ip>/config.txt` (`/opt/influx-grafana/public/config.txt`) is the appliance's full configuration and credential record: service endpoints plus every login (appliance, break-glass, Portainer, InfluxDB, Grafana), the InfluxDB admin token, the Telegraf write-only token and the Proxmox Metric Server settings and token. It is served **without a login, but only to clients on the appliance's local IPv4 subnet(s)**; requests from anywhere else get `403 Forbidden`.
  - The allow-list is generated by `go-euc-local-access.sh` from the appliance's own interface addresses (Docker networks excluded) into `/opt/influx-grafana/nginx/auth/local-subnets.conf`. First boot and **Run Full Appliance Update** refresh it; after changing the appliance IP manually, run `sudo go-euc-local-access.sh`.
  - Requests that reach the appliance over IPv6 are always refused, because Docker's proxy hides their real source address.
  - The file itself is mode 640 (root and the nginx container only). On the appliance: `sudo cat /opt/influx-grafana/public/config.txt`, or `curl http://127.0.0.1:18080/config.txt`.
- Telegraf clients get a write-only token scoped to the `Performance` bucket, not the InfluxDB admin token.
- SSH password login (for `goeucadmin` and the break-glass account) is enabled once the console wizard has replaced the default password. A drop-in, `/etc/ssh/sshd_config.d/10-go-euc.conf`, overrides the Ubuntu cloud image's `60-cloudimg-settings.conf`, which disables password login.

Optional: you can pre-seed or manually edit `/etc/go-euc/config.env` using `appliance/firstboot/config.env.example`.

## Unattended deployment (cloud-init)

The console wizard only writes `/etc/go-euc/config.env` and the marker `/var/lib/go-euc/console-config.done`. The image runs cloud-init, which finishes before first boot starts, so a hypervisor's cloud-init data can do the same. First boot then provisions on its first run, without the console step or the wizard's reboot. Example user-data:

```yaml
#cloud-config
users:
  - name: goeucadmin
    shell: /bin/bash
    groups: [sudo]
    lock_passwd: false
    ssh_authorized_keys: ["ssh-ed25519 AAAA... you@example"]   # optional
write_files:
  - path: /etc/go-euc/config.env
    permissions: "0600"
    content: |
      APPLIANCE_NAME=goeuc-appliance
      APPLIANCE_STATIC_IP_CIDR=192.168.10.50/24
      APPLIANCE_GATEWAY=192.168.10.1
      APPLIANCE_DNS=192.168.10.1
      APPLIANCE_LOGIN_PASSWORD='<new goeucadmin password>'
  - path: /var/lib/go-euc/console-config.done
    permissions: "0600"
    content: "cloud-init\n"
```

On Nutanix AHV, pass this as the VM's guest customization (cloud-init); on VMware, use a cloud-init datasource such as guestinfo. `testing/nutanix/deploy.py` deploys to AHV this way. Cloud-init data can stay readable on the VM (for example on AHV's config drive), so change the password afterwards if that matters in your environment.

## Service endpoints after provisioning

- Appliance landing page: `https://<appliance-ip>/`
- Portainer: `https://<appliance-ip>/portainer/`
- InfluxDB UI and API: `https://<appliance-ip>:8086/`, served over TLS by nginx. InfluxDB's web UI can't run under a sub-path.
- InfluxDB API for clients: `https://<appliance-ip>/influx`. nginx strips the `/influx` prefix; this is the URL in the Telegraf downloads and the Proxmox Metric Server "API Path Prefix".
- Grafana: `https://<appliance-ip>/grafana/`
- GO-EUC Web: `https://<appliance-ip>/goeucweb/`
- Portainer direct access remains available: `https://<appliance-ip>:9443`. Portainer is the tool for managing the appliance's containers, including the collectors.
- InfluxDB API at the root, for tools that take a host and port instead of a URL (OBUX, InfluxDB client libraries): `https://<appliance-ip>/api/v2/...` (token required).
- The InfluxDB container isn't published on the host (nginx serves `:8086` with TLS), and Grafana (`3000`) is bound to localhost; use the HTTPS addresses above.
- **Web ports:** the addresses above use the standard ports 80/443. With the alternative ports they become `https://<appliance-ip>:4443/...` (HTTP on 8080). Switch on the landing page (*Maintenance → Web ports*), with `sudo go-euc-set-ports standard|alternative`, or before first boot with `APPLIANCE_HTTP_PORT` / `APPLIANCE_HTTPS_PORT` in `config.env` or cloud-init. The Telegraf downloads, `config.txt` and the Proxmox Metric Server settings follow the change; Windows machines already running Telegraf need the new config. 8086, 9443 and 22 don't change. See [docs/external-access.md](docs/external-access.md#setup-3-the-appliance-on-the-alternative-ports-8080--4443).

## Landing page

`https://<appliance-ip>/` (login: `goeucadmin`) ties the appliance together in one page:

- **Services**: Grafana, InfluxDB, Portainer, GO-EUC Web and `config.txt`
- **Infrastructure collectors**: one card each for VMware vSphere, Nutanix Prism Element and Proxmox VE (see [Infrastructure collectors](#infrastructure-collectors-vsphere-nutanix-proxmox-ve))
- **Telegraf for Windows**: downloads, the install guide, and **Fetch latest Telegraf package**
- **Maintenance**: **Run Full Appliance Update**, and **Web ports** (standard 80/443 or alternative 8080/4443)
- **Certificates**: Let's Encrypt setup and **Renew Let's Encrypt Certificate**
- **Activity**: the output of every action on the page

## Telegraf download over appliance web UI (HTTPS)

Dockerized nginx serves `/opt/influx-grafana/public/` behind HTTP basic auth (the `goeucadmin` login), including:

- `/telegraf/telegraf-*_windows_amd64.zip` (latest Telegraf Windows x64 package)
- `/telegraf/telegraf_windows_amd64_latest.zip` (stable filename pointer to latest package)
- `/telegraf/telegraf.exe` (extracted from the downloaded zip for direct download)
- `/telegraf/telegraf.conf`
- `/telegraf/telegraf_vsphere.conf`
- `/telegraf/telegraf_nutanix.conf`
- `/telegraf/telegraf_proxmox.conf`
- `/telegraf/WINDOWS_INSTALL.md` (Windows deployment instructions)
- `/telegraf/WINDOWS_INSTALL.html` (browser-friendly rendered view of the instructions)

`/config.txt` is the exception to the login: it needs no password but is restricted to the appliance's local subnet (see [Credentials and access](#credentials-and-access)).

`telegraf.conf` files are rendered by `go-euc-publish-telegraf-config.sh` with:

- Influx org
- Influx URL (`https://<appliance-ip>/influx`, or `https://<domain>/influx` once Let's Encrypt is active)
- write-only Influx token for the `Performance` bucket
- `insecure_skip_verify` (`true` with the self-signed certificate, `false` with Let's Encrypt)

**Fetch latest Telegraf package** (`POST /api/refresh-telegraf`) downloads the latest Telegraf Windows x64 release into `/telegraf/`.

## Updates and maintenance

**Run Full Appliance Update** (`POST /api/full-update`) performs:

- Ubuntu package update/upgrade on the VM
- migration of legacy compose files to include nginx reverse proxy + GO-EUC web services when missing
- container image refresh/redeploy of the pinned image versions (`influxdb`, `grafana`, `portainer`, `goeuc/webserver`) and every enabled infrastructure collector
- dashboard bundle refresh from the dashboard URL baked in at build time (`/etc/go-euc/dashboard-url`, overridable with `DASHBOARDS_ZIP_URL` in `config.env`)
- Telegraf package/executable refresh and config re-publish in `/telegraf/`
- re-run of the local-subnet allow-list for `config.txt`

Container images are pinned:

| Image | Pinned in |
|-------|-----------|
| `influxdb:2.7`, `grafana/grafana:13.3`, `goeuc/webserver:2004.01`, `nginx:1.27-alpine`, `portainer/portainer-ce:2.45.4` | `scripts/step1_install_base.sh` |
| `portainer/portainer-ce:2.45.4` | `appliance/maintenance/go-euc-upgrade.sh` (`PORTAINER_IMAGE`) |
| `telegraf:1.40` (collectors) | `appliance/maintenance/go-euc-collector.sh` (`TELEGRAF_IMAGE`) |

Bump them deliberately: Grafana and Portainer data can't be downgraded safely.

Optional daily container refresh: set `AUTO_UPGRADE_ENABLED=true` in `/etc/go-euc/config.env` before first boot to enable `go-euc-upgrade.timer`. It pulls the pinned images, recreates the stack and refreshes enabled collectors. It doesn't upgrade Ubuntu packages; use **Run Full Appliance Update** for that.

**Status:** `sudo go-euc-status` shows setup state, network and internet access, services, containers, collectors, the health of every web address, recent errors, and where each log is. The console banner points to it.

**Moving to a new appliance:** a full update doesn't replace the appliance's own scripts, so a new release means deploying a new appliance. On the new appliance, `sudo go-euc-migrate <old-ip>` reads the old appliance's InfluxDB token from its `config.txt` (or asks for it). It copies every bucket over the InfluxDB API into the new appliance's own buckets and org, keeping the new tokens, plus dashboards made by hand in the old Grafana. The old appliance is only read. `sudo go-euc-change-ip <ip/prefix>` moves the new appliance onto the old address afterwards. Full guide: [docs/switching-appliances.md](docs/switching-appliances.md).

**File-based backup:** `sudo go-euc-backup.sh` exports every InfluxDB bucket (as line protocol), the collector settings, the carry-over settings and Grafana's database into one root-only archive. It's standalone, so it also runs when copied onto older appliances. `sudo go-euc-restore.sh <archive> [--with-grafana]` writes the data into the new appliance's own buckets and org, keeping its tokens. It then starts the restored collectors and, with `--with-grafana`, restores Grafana's database and resets its admin password to the new appliance's. It needs a way to move the archive (SSH/`scp` or the console), so it suits regular backups; for switching appliances, `go-euc-migrate` is simpler.

**First-boot internet check:** before installing anything, first boot checks that the Ubuntu mirrors and Docker are reachable. If not, it stops with `FAILED: No internet access …` on the console, naming the unreachable sites. Fix the network and reboot to resume. Required and optional sites: [Requirements](docs/getting-started.md#2-requirements).

The landing page's Certificates section has the **Let's Encrypt Setup** form (`POST /api/configure-letsencrypt`) and **Renew Let's Encrypt Certificate** (`POST /api/renew-letsencrypt`). See [TLS certificates](#tls-certificates).

## Infrastructure collectors (vSphere, Nutanix, Proxmox VE)

The appliance can collect hypervisor metrics itself, so no Windows machine is needed for infrastructure monitoring. Each collector is a Telegraf container (`telegraf:1.40`, pinned in `go-euc-collector.sh`) on the appliance's Docker network. Each writes to the `Performance` bucket using the Telegraf write-only token.

Configure them from the **Infrastructure collectors** section of `https://<appliance-ip>/`. Each collector has its own card: fill it in and click **Save and Start**.

- Before starting, the appliance checks the target:
  - **vSphere**: vCenter is reachable with valid TLS
  - **Nutanix**: the Prism Element API accepts the credentials
  - **Proxmox**: node discovery works with the token

  An unreachable address or bad TLS fails within seconds, and the container isn't started. Starting then takes about a minute: the appliance waits for the first collection and shows the container log in the **Activity** panel, so a rejected login or other collection error is reported straight away.
- **Stop** removes the container but keeps the settings. Each card shows the current status.
- Leave the password blank to keep the saved one when changing other settings.
- **Verify the … TLS certificate**: leave unticked for systems with self-signed certificates.

| Collector | Container | Source | Measurements | Collection |
|-----------|-----------|--------|--------------|------------|
| VMware vSphere | `telegraf-vsphere` | vCenter (`inputs.vsphere`), address normalised to `https://<host>/sdk` | Telegraf vSphere plugin measurements (`vsphere_vm_*`, `vsphere_host_*`, ...) | VM and host (realtime) every 20 s; cluster, datastore and datacenter (historical) every 5 min |
| Nutanix Prism Element | `telegraf-nutanix` | Prism Element v2.0 API `GET /api/nutanix/v2.0/hosts/` (`inputs.http` + `json_v2`), port 9440 by default | `nutanix_host`: one series per host (`host`, `host_uuid`, `hypervisor_ip` tags) with CPU, memory, IOPS, bandwidth, latency, network and storage capacity, plus derived `*_pct` / `*_Bps` fields | every 5 s |
| Proxmox VE | `telegraf-proxmox` | Proxmox API with an API token, port 8006 by default | `proxmox` (per VM/LXC, from `inputs.proxmox`), `proxmox_node` (node status: CPU, iowait, load, memory, swap, rootfs, KSM, CPU info), `proxmox_node_rrd` (1-minute node history incl. network throughput, ZFS ARC, pressure stalls), `proxmox_resource` (every node, VM, LXC and storage in the cluster), `proxmox_cluster` (membership and quorum) | 10 s; history 60 s; quorum 30 s |

Notes per collector:

- **vSphere**: a read-only vCenter account is enough.
- **Nutanix Prism Element**: the form asks for the **Prism Element** address: the cluster's virtual IP or name, **not Prism Central**. The v2.0 hosts API is served by each cluster's Prism Element. A read-only Prism Element account (Viewer role) is enough.
- **Proxmox VE**: the username/password fields are the API token ID (`user@realm!tokenname`) and secret. Nodes are discovered through the API when the collector starts, and the config gets one section per node. Save again (or run a full update) after adding nodes. Create a read-only token on any node:

  ```bash
  pveum user add telegraf@pve
  pveum acl modify / -role PVEAuditor -user telegraf@pve
  pveum user token add telegraf@pve monitoring -privsep 1
  pveum acl modify / -role PVEAuditor -token 'telegraf@pve!monitoring'
  ```

### Proxmox VE Metric Server (push)

Proxmox can also push its own built-in metrics directly to the appliance's InfluxDB, alongside the collector. These go to the separate `Proxmox` bucket with their own write-only token: Proxmox's measurement names (`system`, `cpustat`, `memory`, ...) would otherwise clash with the Windows Telegraf data in `Performance`.

The Proxmox card's **Also push Proxmox's own metrics** panel shows the exact values and a ready-to-run command, also recorded in `config.txt` under `ProxmoxMetricServer`. In Proxmox: Datacenter → Metric Server → Add → InfluxDB:

- Server: the appliance address, Port: `443` (`4443` with the alternative web ports), Protocol: `HTTPS`
- Organization: the Influx org, Bucket: `Proxmox`, Token: the Proxmox write-only token
- Advanced: API Path Prefix `/influx`, Verify Certificate off while the appliance uses its self-signed certificate

```bash
pvesh create /cluster/metrics/server/goeuc --type influxdb --server <appliance> --port 443 \
  --influxdbproto https --api-path-prefix /influx --organization <org> --bucket Proxmox \
  --token <proxmox-token> --verify-certificate 0
```

### How the collectors work

- Settings, including passwords and token secrets, are kept root-only in `/etc/go-euc/collector-<type>.env`. They are passed to the container through a root-only Docker env-file, `/etc/go-euc/telegraf-<type>.env`.
- The Telegraf configs in `appliance/collectors/` (installed at `/opt/go-euc-installer/collectors/`) hold no secrets. The Proxmox config is rendered per cluster into `/opt/influx-grafana/collectors/telegraf-proxmox.conf`.
- The collectors appear in **Portainer** like every other container, so their logs and state can be viewed and they can be stopped or restarted there. Changes made to a collector container in Portainer are replaced the next time it is started from the landing page or refreshed by an update.
- The daily upgrade timer and **Run Full Appliance Update** refresh every enabled collector (`go-euc-collector.sh all apply-enabled`).
- API endpoints (behind the same basic auth): `GET /api/collectors/<type>/status`, `POST /api/collectors/<type>/configure`, `POST /api/collectors/<type>/disable`, and `GET /api/proxmox-metric-server`.

From the appliance shell (`<type>` is `vsphere`, `nutanix` or `proxmox`):

```bash
sudo go-euc-collector.sh <type> status     # settings (no password), container state, recent log
sudo go-euc-collector.sh <type> apply      # recreate from saved settings (re-discovers Proxmox nodes)
sudo go-euc-collector.sh <type> disable    # stop and remove the container
```

Windows alternatives: `telegraf_vsphere.conf`, `telegraf_nutanix.conf` and `telegraf_proxmox.conf` from `/telegraf/` run the same collection on a Windows machine (see `Telegraf/WINDOWS_INSTALL.md`).

## TLS certificates

The nginx front end always serves HTTPS and starts with a generated self-signed certificate.

Optional Let's Encrypt automation is enabled when both values are set in `/etc/go-euc/config.env`:

- `APPLIANCE_LETSENCRYPT_DOMAIN=appliance.example.com`
- `APPLIANCE_LETSENCRYPT_EMAIL=admin@example.com`

When configured:

- first-boot attempts automatic certificate issuance
- `certbot.timer` renews automatically; a deploy hook (`go-euc-letsencrypt-deploy-hook.sh`) copies renewed certificates into nginx, reloads it and re-publishes the Telegraf configs
- cert renewal is also available from the web UI button
- the active nginx certificate switches from self-signed to Let's Encrypt

Let's Encrypt validates over port 80 from the internet. DNS, port forwarding and reverse-proxy setups are covered in [docs/external-access.md](docs/external-access.md).

For Windows install steps, see `Telegraf/WINDOWS_INSTALL.md`.
