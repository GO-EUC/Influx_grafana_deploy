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

| Trigger | What happens |
|---|---|
| Push to `dev` | Build the appliance and upload the images to Azure Blob storage. The run's summary page lists the download links and checksums. |
| Push to `main` | Same, plus publish `Dashboards.zip` to the `files` container (appliances download it during **Run Full Appliance Update**). **No release.** |
| Manual run (*Run workflow*) | Build and upload for the chosen branch. With **Create release** ticked (on `main` only), also create a GitHub Release. See [Releasing](#releasing). |

Images uploaded to the Azure Blob container (`vars.AZURE_STORAGE_CONTAINER`):

- `go-euc-appliance-<timestamp>-<sha>.ova`
- `go-euc-appliance-<timestamp>-<sha>.vhd`
- matching `.sha256` for each image format

The images are too large for GitHub Release assets, so each GitHub Release body contains download links to the Azure Blob files. The Azure prerequisites (storage account, containers, GitHub OIDC identity) are created by the Terraform in `terraform/`.

## Releasing

Releases are created only when you decide, never automatically.

### Versions

| Release type | When | Example |
|---|---|---|
| **major** | New functionality, or anything users need to act on (new appliance, changed URLs) | `v1.0` → `v2.0` |
| **minor** | Fixes and small improvements | `v2.0` → `v2.1` |

The next version is worked out from the latest `vX.Y` tag. An existing version is never overwritten: the run stops before building if the tag already exists.

### Steps

1. **Get the code onto `main`.** Open a pull request from `dev` to `main`, review it and merge it. Before merging:
   - Run the end-to-end test on the `dev` build and record it in `testing/README.md`.
   - In `CHANGELOG.md`, rename `## Unreleased (dev)` to the version you're about to release, e.g. `## v2.0 (2026-11-26)`.
   - Make sure `Dashboards.zip` contains every dashboard appliances should have. The `main` build publishes it, and existing appliances download it during their next full update.
2. **Create the release.** GitHub → *Actions* → *Build Virtual Appliance* → *Run workflow*:
   - **Use workflow from:** `main`
   - **Create a GitHub Release:** ticked
   - **Version bump:** `major` or `minor`
   - **Release notes:** optional; a short summary shown above the generated sections

   Or from a terminal:
   ```bash
   gh workflow run build-appliance.yml --ref main \
     -f create_release=true -f release_type=major \
     -f release_notes="Infrastructure collectors, one-command appliance switching and security hardening."
   ```
3. **Check the release** (about 5 minutes later) on the repository's *Releases* page. It contains:
   - your notes
   - a download table for **that run's** OVA and VHD, with SHA-256 checksums and checksum files
   - links to the getting-started guide, the switching guide and the changelog at that version
   - a comparison link to the previous release
   - GitHub's generated list of merged pull requests

   The release is tagged on the exact commit that was built and marked as *Latest*.

If the run fails before the build with *"Releases can only be created from main"*, you started it on another branch. If it fails with *"Tag vX.Y already exists"*, that version is already released; choose the other release type or fix the tags first.

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
