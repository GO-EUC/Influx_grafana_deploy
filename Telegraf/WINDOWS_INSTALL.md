# Telegraf Windows Install

Use this after the appliance setup has completed and the web file host is available.

## 1) Download files from appliance

From a Windows machine, open:

- `http://<appliance-ip>/telegraf/`

Download:

- latest Telegraf package (`.tar.gz`)
- `telegraf.conf` (Windows host metrics)
- `telegraf_vsphere.conf` (vSphere metrics collector)

`telegraf.conf` and `telegraf_vsphere.conf` are generated with:

- `TELEGRAF_ORGANISATION` = your Influx org
- `TELEGRAF_URL` = `http://<appliance-ip>:8086`
- `TELEGRAF_TOKEN` = generated Influx token

## 2) Install Telegraf on Windows

Open PowerShell as Administrator:

```powershell
New-Item -ItemType Directory -Force -Path C:\Telegraf | Out-Null
tar -xzf .\telegraf-*.tar.gz -C C:\Telegraf --strip-components=1
```

Copy the desired config:

- For endpoint metrics:
  - copy downloaded `telegraf.conf` to `C:\Telegraf\telegraf.conf`
- For vSphere collector:
  - copy downloaded `telegraf_vsphere.conf` to `C:\Telegraf\telegraf.conf`
  - then set `<<VSPHERE_URL>>`, `<<VSPHERE_USERNAME>>`, `<<VSPHERE_PASSWORD>>`

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
