# Telegraf Windows Install

Use this after the appliance setup has completed and the web file host is available.

## 1) Download files from appliance

From a Windows machine, open:

- `https://<appliance-ip>/telegraf/`

Sign in with the appliance login (`goeucadmin` and the password set in the console wizard).
While the appliance uses its self-signed certificate, the browser will show a certificate warning; accept it to continue.

Download:

- latest Telegraf package (`*_windows_amd64.zip`), or `telegraf.exe` on its own
- `telegraf.conf` (Windows host metrics)
- `telegraf_vsphere.conf` (vSphere metrics collector)
- `telegraf_nutanix.conf` (Nutanix Prism Element metrics collector)
- `telegraf_proxmox.conf` (Proxmox VE metrics collector)

All the `.conf` files are generated with:

- `TELEGRAF_ORGANISATION` = your Influx org
- `TELEGRAF_URL` = `https://<appliance-ip>/influx` (or `https://<your-domain>/influx` once Let's Encrypt is active)
- `TELEGRAF_TOKEN` = a write-only Influx token scoped to the `Performance` bucket
- `insecure_skip_verify` = `true` while the appliance uses its self-signed certificate, `false` once a Let's Encrypt certificate is active

If you enable Let's Encrypt after deploying Telegraf, download the configs again so clients use the domain name and verify TLS.

## 2) Install Telegraf on Windows

Open PowerShell as Administrator:

```powershell
New-Item -ItemType Directory -Force -Path C:\Telegraf | Out-Null
Expand-Archive -Path .\telegraf-*_windows_amd64.zip -DestinationPath C:\Telegraf -Force
```

Copy the desired config:

- For endpoint metrics:
  - copy downloaded `telegraf.conf` to `C:\Telegraf\telegraf.conf`
- For infrastructure collectors (vSphere, Nutanix, Proxmox VE):
  - simplest option: skip Windows entirely and use the **Infrastructure collectors** section of the appliance landing page (`https://<appliance-ip>/`), which runs each collector in a container on the appliance (and discovers every Proxmox node automatically)
  - to run one on Windows instead, copy the downloaded file to `C:\Telegraf\telegraf.conf` and fill in its placeholders:
    - `telegraf_vsphere.conf`: `<<VSPHERE_URL>>`, `<<VSPHERE_USERNAME>>`, `<<VSPHERE_PASSWORD>>`
    - `telegraf_nutanix.conf`: `<<NUTANIX_PRISM_ELEMENT_ADDRESS>>` (the cluster's Prism Element virtual IP or name, not Prism Central), `<<NUTANIX_USERNAME>>`, `<<NUTANIX_PASSWORD>>`
    - `telegraf_proxmox.conf`: `<<PROXMOX_ADDRESS>>`, `<<PROXMOX_TOKEN_ID>>` (`user@realm!tokenname`), `<<PROXMOX_TOKEN_SECRET>>`, `<<PROXMOX_NODE>>`. For a cluster, copy the "Proxmox node" section once per node. The token needs the PVEAuditor role on `/`.

## 3) Validate config

```powershell
cd C:\Telegraf
.\telegraf.exe --config .\telegraf.conf --test
```

## 4) Install and start as Windows service

```powershell
cd C:\Telegraf
.\telegraf.exe --service install --config "C:\Telegraf\telegraf.conf"
Start-Service telegraf
Set-Service -Name telegraf -StartupType Automatic
Get-Service telegraf
```

## 5) Troubleshooting

- Service logs (default from supplied config): `C:\Windows\Temp\telegraf.log`
- Check service state:

```powershell
Get-Service telegraf
Get-Content C:\Windows\Temp\telegraf.log -Tail 100
```

- `x509: certificate signed by unknown authority`: the config has `insecure_skip_verify = false` but the appliance is serving its self-signed certificate. Download the configs again from `/telegraf/`.
- `401 Unauthorized` from InfluxDB: the token in the config is no longer valid. Download the configs again from `/telegraf/`.
