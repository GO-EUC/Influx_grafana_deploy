# Switching from an old appliance to a new one

Use this guide when a new release of the GO-EUC appliance comes out and you want to move to it with your data.

**Why a new appliance?** *Run Full Appliance Update* updates Ubuntu, the containers, the dashboards and Telegraf, but not the appliance's own setup scripts. A new release (security fixes, collectors, the landing page) therefore means deploying a new appliance and moving your data across. It takes about 30 minutes plus copy time, and your old appliance stays untouched until you decide to switch it off.

## How it works

1. You deploy the **new** appliance next to the old one.
2. On the new appliance you run **one command**, `sudo go-euc-migrate <old-appliance-address>`. It copies all your data from the old appliance over the network. The old appliance is only read, never changed, and you don't install anything on it.
3. You point your Windows machines (and anything else) at the new appliance.
4. You switch the old appliance off.

## What moves, and what you redo

| Copied by `go-euc-migrate` | You redo on the new appliance |
|---|---|
| All InfluxDB data: every bucket, every point | **Telegraf on the Windows machines**: install the new appliance's config (new address and token) |
| Dashboards you created yourself in Grafana (into a *Migrated from &lt;old&gt;* folder) | **Infrastructure collectors** (vSphere, Nutanix, Proxmox): re-enter them on the landing page, since their passwords never leave the old appliance |
| | **Proxmox Metric Server**, if you use it: point it at the new appliance |
| | **Let's Encrypt**, if you use it: move the DNS name, then request the certificate again |

Not copied: the preloaded GO-EUC dashboards (the new appliance has its own, newer copies), passwords and tokens (the new appliance keeps its own; see its `config.txt`), and Portainer settings.

## Before you start

- [ ] The old appliance is **running**.
- [ ] You have the new release's image (see [Download](getting-started.md#3-download)).
- [ ] A **free IP address** for the new appliance. Both run side by side for a while. To end up on the old appliance's address, follow this guide anyway, then see [Keeping the same IP address](#keeping-the-same-ip-address).
- [ ] The new appliance can reach the old one on **port 8086** (InfluxDB) and **443/80** (to read the old `config.txt`). Easiest: put both on the same subnet.
- [ ] Enough disk space on the new appliance for your data (the default 100 GB is plenty for most test labs).

## Steps

### 1. Deploy the new appliance

Follow [getting-started.md](getting-started.md) sections 4–6 on the **new** IP address: import, setup wizard, first login. Don't set up the infrastructure collectors yet.

### 2. Copy the data

Log in to the **new** appliance's console, or SSH in as `goeucadmin`, and run:

```bash
sudo go-euc-migrate <old-appliance-ip>
```

It finds the old appliance, reads its InfluxDB token from the old `config.txt`, and shows what it will copy:

```
[migrate] old InfluxDB: https://192.168.10.50:8086
[migrate] read https://192.168.10.50/config.txt

  From:  192.168.10.50 (InfluxDB org 'monitoring', buckets: Performance, Proxmox, Tests)
  To:    this appliance (org 'monitoring'), into buckets of the same name
  Grafana dashboards made by hand: copied
  The old appliance is only read, not changed.

Continue? [y/N]
```

Type `y`. It downloads the data, writes it into the new appliance, copies your hand-made dashboards, and finishes with **Done. Next steps**. Large databases take a while.

If it asks for a token, it couldn't read the old `config.txt` (for example, a current appliance on a different subnet refuses it). Get the **InfluxDB admin token** from the old appliance and paste it:
- In the old appliance's `config.txt`: under *InfluxDB*, `AdminToken=` (older releases: under *Telegraf*, `InfluxToken=`).
- Or on the old appliance's console: `sudo cat /opt/influx-grafana/install-summary.txt`.

### 3. Check the new appliance

- Run `sudo go-euc-status` on the new appliance. Everything should be `OK`.
- In the new Grafana (`https://<new-ip>/grafana/`), open a dashboard and set the time range to cover your old data (e.g. *Last 30 days*). The old data should be there.

### 4. Move everything over to the new appliance

- **Windows machines.** On each one, download the new `telegraf.conf` from `https://<new-ip>/telegraf/` (sign in as `goeucadmin`) and replace the old one:
  ```powershell
  Copy-Item .\telegraf.conf C:\Telegraf\telegraf.conf -Force
  Restart-Service telegraf
  ```
- **Infrastructure collectors.** Fill in their cards on the new landing page and click *Save and Start*.
- **Proxmox Metric Server.** In Proxmox, edit the metric server (Datacenter → Metric Server), or remove it and re-add it with the values from the new appliance's Proxmox card.
- **Let's Encrypt.** Point the DNS name at the new appliance, then use *Certificates → Let's Encrypt setup* on the new landing page.
- Update any bookmarks or documentation that use the old address.

### 5. Catch up and switch the old appliance off

Data that reached the old appliance after step 2 isn't on the new one yet. Just before you switch the old appliance off, run the same command again on the new appliance. It's safe to repeat: data already copied is simply overwritten, never doubled.

```bash
sudo go-euc-migrate <old-appliance-ip> --yes
```

Then shut the old appliance down. Keep it powered off for a week or two as a fallback before deleting it.

**Going back:** until you delete it, you can power the old appliance on again and reinstall its Telegraf configs on the Windows machines.

## Keeping the same IP address

Two appliances can't share an address while both are running, so move the new appliance onto the old address at the end:

1. Do steps 1–3 above with the new appliance on a **temporary** address.
2. Do step 5 (catch-up copy), then **shut the old appliance down**.
3. On the **new** appliance's **console** (an SSH session would be cut off when the address changes), run:
   ```bash
   sudo go-euc-change-ip <old-ip>/<prefix>          # e.g. sudo go-euc-change-ip 192.168.10.50/24
   ```
   Gateway and DNS stay as they are, unless you add them: `sudo go-euc-change-ip 192.168.10.50/24 192.168.10.1 192.168.10.1`. The command refuses to run while another device still answers on that address. It updates the network settings, the `config.txt` subnet list, the Telegraf downloads and the console banner.
4. Do step 4. Windows machines still need the new appliance's Telegraf config: the address is the same, but the token is new.

## Troubleshooting

| Message | Meaning and fix |
|---|---|
| `no InfluxDB answering on https://<old>:8086 or http://<old>:8086` | The old appliance is off, the address is wrong, or a firewall blocks port 8086 between the two. |
| `the old InfluxDB rejected the token` | The token pasted isn't the old appliance's **admin** token (for example, the write-only Telegraf token from a current release). Use `AdminToken` from the old `config.txt`, or `install-summary.txt`. |
| `config.txt: refused (403)` | Current appliances only serve `config.txt` to their own subnet. Paste the token when asked, or run with `--token <token>`. |
| `old Grafana login not available` | Your data is still copied; only hand-made dashboards aren't. Export them from the old Grafana (*Dashboard → Share → Export*) and import them into the new one. |
| `dashboard '...': copy failed` | Same: export and import that dashboard by hand. |

## Tested so far

The switch has been tested between appliances of the current release, including a different InfluxDB organisation on each side (see [testing/README.md](../testing/README.md)). Appliances from releases **before November 2026** read the same way (InfluxDB on `http://<old>:8086`, token in `http://<old>/config.txt`), but that path hasn't been tested on a real old appliance yet. If `go-euc-migrate` fails against one, use the messages above, or report it with the command's output.

## Other ways to move data

`go-euc-backup.sh` / `go-euc-restore.sh` (see the [README](../README.md#updates-and-maintenance)) also cover collector settings and Grafana's full database, and work without a network path between the appliances. They need SSH or console file transfer to move the archive, so they suit regular backups better than switching.
