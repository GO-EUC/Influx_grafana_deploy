# Getting started with the GO-EUC appliance

This guide takes you from nothing to a working appliance, assuming you have never used it before. The [README](../README.md) is the reference for every feature.

## 1. What the appliance is

The GO-EUC appliance is a ready-made Ubuntu virtual machine that collects and shows performance data for EUC (end-user computing) testing. You import it into your hypervisor and answer a few questions on its console. It then sets itself up with:

- **InfluxDB**, the database that stores the metrics
- **Grafana**, with the GO-EUC dashboards preloaded
- **Telegraf** packages and ready-made configs for the Windows machines you test
- optional **infrastructure collectors**: the appliance itself gathers VMware vSphere, Nutanix Prism Element or Proxmox VE metrics
- **Portainer**, for managing the appliance's containers
- a **landing page** at `https://<appliance-ip>/` that ties it all together

## 2. Requirements

**Virtual machine**

| | Minimum | Recommended (with collectors) |
|---|---|---|
| vCPU | 2 | 4 |
| Memory | 4 GB | 8 GB |
| Disk | 100 GB thin-provisioned (included in the image; grows automatically if you enlarge it) | |
| Boot | Legacy BIOS | |

**Network**
- A free **static IPv4 address**, plus the subnet's gateway and a DNS server. The setup wizard asks for these.
- **Internet access** during first boot and for updates. There is no proxy support. Outbound access needed:

  | To | Port | Why |
  |---|---|---|
  | `archive.ubuntu.com`, `security.ubuntu.com` | 80 | Ubuntu packages |
  | `download.docker.com` | 443 | Docker installation |
  | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` | 443 | container images |
  | `github.com`, `api.github.com`, `objects.githubusercontent.com` | 443 | Telegraf for Windows downloads (optional) |
  | `goeucartifacts4hiu9i.blob.core.windows.net` | 443 | dashboard updates (optional) |

  First boot checks the required sites before installing anything. If they aren't reachable, setup stops with a clear message instead of failing halfway (see [Troubleshooting](#8-troubleshooting)).

- **Inbound** to the appliance, from your admin machine and the machines being tested:

  | Port | Used for |
  |---|---|
  | 443 | Landing page, Grafana, Portainer, GO-EUC Web, and the InfluxDB API that Telegraf writes to |
  | 8086 | InfluxDB web UI and API (HTTPS) |
  | 80 | Redirects to HTTPS; needed for Let's Encrypt |
  | 9443 | Portainer direct (optional) |
  | 22 | SSH for administration (optional) |

- **Outbound to monitored systems**, only if you use the collectors: vCenter on 443, Prism Element on 9440, Proxmox VE on 8006.

## 3. Download

Open the [Releases page](https://github.com/GO-EUC/Influx_grafana_deploy/releases). Each release lists download links for:

- `go-euc-appliance-<build>.ova`, for VMware
- `go-euc-appliance-<build>.vhd`, for Hyper-V, Nutanix AHV, Proxmox VE and other KVM hypervisors
- a `.sha256` file for each

To check a download, compare its hash with the first value in the matching `.sha256` file:

```bash
shasum -a 256 go-euc-appliance-<build>.vhd                     # macOS / Linux
Get-FileHash go-euc-appliance-<build>.vhd -Algorithm SHA256    # Windows PowerShell
```

## 4. Import the appliance

Use the steps for your hypervisor. Only the Nutanix AHV steps have been tested end to end so far; the others are standard imports, marked *not yet tested*.

**Nutanix AHV (tested)**
1. Prism Element → Settings → Image Configuration → Upload Image. Choose **From URL**, paste the `.vhd` link, and set the type to *Disk*.
2. Create a VM: 4 vCPU and 8 GB RAM (or 2 / 4), **Legacy BIOS**. Add a disk cloned from the image, and a NIC on the network where the appliance will live.
3. Power it on and open the VM console.

**VMware vSphere / ESXi (not yet tested)**
1. vSphere Client → Deploy OVF Template, and select the `.ova`. Choose thin provisioning and the right network.
2. Adjust CPU and memory if needed, power on, and open the console.

**Microsoft Hyper-V (not yet tested)**
1. Create a **Generation 1** VM (the image boots BIOS, not UEFI) with 4 GB+ RAM, connected to the right virtual switch.
2. Choose "Use an existing virtual hard disk" and select the `.vhd`.
3. Set the processor count, start the VM, and connect to its console.

**Proxmox VE / other KVM (not yet tested)**
1. Copy the `.vhd` to the Proxmox host and create a VM without a disk (SeaBIOS, VirtIO network), for example `qm create 9000 --name go-euc --memory 8192 --cores 4 --net0 virtio,bridge=vmbr0`.
2. Import the disk with `qm importdisk 9000 go-euc-appliance-<build>.vhd local-lvm`. Attach it as `scsi0`, make it the boot disk, then start the VM and open its console.

## 5. First boot and the setup wizard

1. On the VM console, log in as **`goeucadmin`** with password **`goeucadmin`**. The setup wizard starts by itself. If it first asks `[sudo] password for goeucadmin`, type `goeucadmin` again.
2. Answer the prompts: hostname, network interface (the default is usually right), static IP in CIDR form (e.g. `192.168.10.50/24`), gateway, DNS servers, and a **new password for `goeucadmin`** (at least 8 characters). This password is also your login for the appliance web page, so write it down.
3. The appliance reboots and sets itself up. The console banner shows `INITIALIZING`, then `COMPLETE`. That usually takes 5–20 minutes, depending on your internet connection.

To deploy many appliances, or skip the console entirely, see [Unattended deployment](../README.md#unattended-deployment-cloud-init).

## 6. First login

1. Browse to **`https://<appliance-ip>/`**. Your browser will warn that the connection isn't private. That's expected: the appliance starts with a *self-signed* certificate. Continue anyway (*Advanced → Proceed* or similar). You can replace it with a trusted Let's Encrypt certificate later; see [Let's Encrypt](#7-next-steps).
2. Sign in as **`goeucadmin`** with the password you chose in the wizard.
3. Find the logins for the individual services. Each appliance gets its own random passwords, in one of two places:
   - **Services → config.txt** on the landing page. It opens from a computer on the **same subnet** as the appliance; elsewhere it's refused, which is deliberate.
   - On the appliance console or over SSH: `sudo cat /opt/influx-grafana/install-summary.txt`.

   | Service | Address | Username |
   |---|---|---|
   | Grafana | `https://<ip>/grafana/` | `admin` |
   | InfluxDB | `https://<ip>:8086/` | `influxadmin` |
   | Portainer | `https://<ip>/portainer/` | `admin` |

## 7. Next steps

**Collect data from the machines you test (Windows)**
Download Telegraf and its config from **Telegraf for Windows** on the landing page, and follow [WINDOWS_INSTALL.md](../Telegraf/WINDOWS_INSTALL.md). The configs are already filled in with this appliance's address and a write-only token, and the data appears in the `Performance` bucket.

**Look at the dashboards**
In Grafana, open *Dashboards*. The GO-EUC dashboards (Windows Performance Realtime, Windows Process Realtime/Analysis/Test Runs, Analyzing, Comparing) are preloaded:
- The realtime and process dashboards work as soon as Telegraf data arrives.
- *Analyzing* and *Comparing* also use test-run information from the `Tests` bucket, which the GO-EUC test tooling writes.
- The appliance's InfluxDB organisation is `monitoring`. If your test tooling expects a different organisation (the GO-EUC lab uses `GO`), set it **before completing the setup wizard**, because it can't be changed afterwards. At the wizard's first prompt, press `Ctrl+C`, then run:

  ```bash
  echo 'INFLUX_ADMIN_ORG=GO' | sudo tee -a /etc/go-euc/config.env
  sudo go-euc-console-wizard.sh
  ```

  The wizard keeps extra settings in `config.env`. The same works for the other overrides in `appliance/firstboot/config.env.example`, or put them in the [cloud-init data](../README.md#unattended-deployment-cloud-init).

**Collect hypervisor metrics (optional)**
Under **Infrastructure collectors** on the landing page, fill in the card for VMware vSphere, Nutanix Prism Element or Proxmox VE and click *Save and Start*. See [Infrastructure collectors](../README.md#infrastructure-collectors-vsphere-nutanix-proxmox-ve).

**Trusted certificate (optional)**
If the appliance has a public DNS name, use **Certificates → Let's Encrypt setup** on the landing page. Renewals are automatic.

**Keep it up to date**
Use **Maintenance → Run Full Appliance Update** now and then. It updates Ubuntu, the containers, the dashboards and Telegraf.

## 8. Troubleshooting

Start with **`sudo go-euc-status`** on the appliance console or over SSH. It checks setup, network, services, containers, collectors and every web address, and tells you where to look next. The console banner also shows the setup state.

| Symptom | What to do |
|---|---|
| Banner says `FAILED: No internet access` | The appliance couldn't reach the sites in [Requirements](#2-requirements). Check the gateway, DNS and firewall (no proxy support), fix it, then reboot. Setup carries on automatically. |
| Banner says `FAILED` with another reason | Run `sudo go-euc-status` and `sudo tail -100 /var/log/go-euc-install.log`. During setup, the banner also shows the **break-glass** account (`recovery`) for logging in if `goeucadmin` doesn't work. |
| Web page doesn't load | Check the VM has the IP you expect (`ip a` on the console) and that port 443 is reachable from your PC. |
| Browser certificate warning | Expected with the default self-signed certificate (see [First login](#6-first-login)). |
| Forgot the `goeucadmin` password | From a computer on the appliance's subnet, open `https://<ip>/config.txt`. It lists the appliance login and the break-glass account. |
| A collector shows an error | The card's message and the Activity panel show the reason. Also try `sudo go-euc-collector.sh <vsphere\|nutanix\|proxmox> status`. |
| Portainer shows "timed out" | Restart it with `sudo docker restart portainer`. Current releases create the Portainer admin automatically during setup. |

Logs: first boot `sudo journalctl -u go-euc-firstboot.service`, installer `/var/log/go-euc-install.log`, full update `/var/log/go-euc-appliance-update.log`, containers `sudo docker logs <name>`.

## 9. Moving from an older appliance

New releases are installed by deploying a new appliance and copying your data across with one command on the new appliance:

```bash
sudo go-euc-migrate <old-appliance-ip>
```

The old appliance is only read, so you can switch back until you delete it. The full step-by-step guide, including keeping the same IP address, is [switching-appliances.md](switching-appliances.md).
