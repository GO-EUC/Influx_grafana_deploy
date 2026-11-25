# Developing and releasing the GO-EUC appliance

Maintainer documentation: how the appliance image is built, released and tested. If you want to *use* the appliance, see [getting-started.md](getting-started.md).

## Repository layout

| Path | Contents |
|------|----------|
| `appliance/build-appliance.sh` | Builds the OVA and VHD from the Ubuntu Noble cloud image with `virt-customize` |
| `appliance/firstboot/` | First-boot provisioning, console wizard, login hook, `config.env.example` |
| `appliance/maintenance/` | Tools installed in `/usr/local/bin`: updates, collectors, status, backup/restore, Telegraf publishing, local access, Let's Encrypt hook, dashboard normaliser, API backend |
| `appliance/collectors/` | Telegraf configs for the infrastructure collectors |
| `scripts/step1_install_base.sh` | The installer first boot runs: Docker, Portainer, InfluxDB, Grafana, nginx, GO-EUC Web |
| `Telegraf/` | Windows Telegraf config templates and install guide (published under `/telegraf/` on the appliance) |
| `Dashboards.zip` | Grafana dashboard bundle (published to Azure on `main` builds) |
| `terraform/` | Azure prerequisites for CI (storage, OIDC identity); see [terraform/README.md](../terraform/README.md) |
| `testing/` | End-to-end test suite; see [testing/README.md](../testing/README.md) |

## Build and release workflow

Workflow file: `.github/workflows/build-appliance.yml`

Triggers:

- push to `dev`: build appliance + upload images to Azure Blob storage
- push to `main`: build appliance + upload images to Azure Blob storage + publish `Dashboards.zip` to the `files` container + auto-create the next GitHub Release (`v1.0`, `v1.1`, `v1.2`, ...)
- manual run: `workflow_dispatch`

Images uploaded to the Azure Blob container (`vars.AZURE_STORAGE_CONTAINER`):

- `go-euc-appliance-<timestamp>-<sha>.ova`
- `go-euc-appliance-<timestamp>-<sha>.vhd`
- matching `.sha256` for each image format

The images are too large for GitHub Release assets, so each GitHub Release body contains download links to the Azure Blob files. The Azure prerequisites (storage account, containers, GitHub OIDC identity) are created by the Terraform in `terraform/`.

## Local build (optional)

From repo root:

```bash
bash appliance/build-appliance.sh
```

The appliance image is customized during build using `virt-customize` from libguestfs: [virt-customize documentation](https://libguestfs.org/virt-customize.1.html).

Output is written to `dist/`.

Optional build environment variables:

- `BREAK_GLASS_USER` / `BREAK_GLASS_PASSWORD`: build-time recovery account (random password by default; rotated per VM on first boot)
- `DASHBOARDS_ZIP_URL`: dashboard bundle location used by the appliance's full update
- `DISK_SIZE_GB`, `VHD_SUBFORMAT`, `UBUNTU_IMAGE_URL`

## Testing

`testing/` contains the end-to-end test. It deploys a CI-built image to Nutanix AHV unattended, waits for provisioning, then runs on-box, HTTP, collector, console-wizard and maintenance checks. It also lists the manual checks and records past test runs. See [testing/README.md](../testing/README.md).

Before releasing (merging to `main`), run the end-to-end test on the CI-built image and record the result in `testing/README.md`. Also make sure `Dashboards.zip` contains every dashboard appliances should have: `main` builds publish it, and appliances download it during **Run Full Appliance Update**.
