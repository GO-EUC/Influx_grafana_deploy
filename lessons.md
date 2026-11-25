# Lessons learned

Things that cost time while building and testing the appliance, and how to avoid them. Read this before changing the appliance scripts, the nginx configuration or the test setup. [docs/development.md](docs/development.md) covers building and releasing; [testing/README.md](testing/README.md) covers the test runs.

## Working on this repo

- **The repo is public: never commit a secret.** A file holding a hypervisor admin credential was once committed and pushed, and `dev` had to be rewritten to remove it. Since then:
  - stage files by name, never `git add -A` or `git add .`;
  - before every commit, search the staged diff (`git diff --cached`) for the actual values in your local test settings (`~/.goeuc-test/`). Report which setting matched, never the value;
  - keep lab IP addresses and host names out of docs; use example addresses such as `192.168.1.50` and `goeuc.example.com`;
  - if a secret does get pushed, rotate it. Rewriting history doesn't help with copies that were already fetched.
- **Keep designs simple.** Offer one default path and at most one alternative. External access is a good example: a design with several access modes was dropped in favour of "landing page behind the appliance login, other services on their own logins, router forwards 80/443 to the appliance", plus an optional alternative port pair.
- **Changes reach `main` through pull requests.** Releases are created only on request (see [Releasing](docs/development.md#releasing)).

## Testing

- **Test on a real deployment, not only with `bash -n`.** Most bugs below only showed up on a deployed appliance. `testing/` deploys to Nutanix AHV unattended and runs the checks.
- **Hot-deploy before a full build.** Copy changed scripts onto an existing test appliance (`/usr/local/bin/`), restart the service involved, and run the relevant checks. A CI build plus deployment takes 40+ minutes; this takes one.
- **Know what an older appliance lacks.** On a hot-patched appliance, checks for files written by first boot can fail because they come from the older first boot. Note these, then confirm them on a fresh build.
- **`bash -n a.sh b.sh` only checks `a.sh`.** The other names are passed to it as arguments. Check one file per call.
- **zsh doesn't split `$VAR` into words.** `SSH="ssh -i key host"; $SSH cmd` fails in zsh. Use `bash -c '...'` and arrays: `SSH=(ssh -i key host); "${SSH[@]}" cmd`.
- **Make checks prove who answered.** A 401 from `/api/v2/write` could be InfluxDB or the appliance login. The check also looks for InfluxDB's `"code":"unauthorized"` body.

## nginx

- **The nginx config is bind-mounted as a single file.** Docker mounts the file's inode, so replacing the file (`install`, `mv`, `sed -i`) leaves the container reading the old content. Rewrite it in place (`cat > file`, or Python `open(path, "r+")` + `truncate()`), or recreate the container.
- **InfluxDB has no base path.** `INFLUXD_HTTP_BASE_PATH` is ignored. `/influx/` works because nginx strips the prefix (API only). The InfluxDB web UI needs the root of a host:port, so nginx serves it on 8086. Tools that take a host and port instead of a URL (OBUX, client libraries) use `/api/v2/` on the web port.
- **Portainer under `/portainer/`** needs the prefix stripped and WebSocket headers for container consoles.
- **A folder without an index file returns 403** unless `autoindex on;` is set (the `/telegraf/` bug in the first v2.0 build).
- **Reach host services through a Unix socket.** nginx in Docker couldn't reliably reach the API backend on the host over TCP (502). It uses `/opt/influx-grafana/run/api.sock`, shared with the container's group.
- **A request can't restart the server that carries it.** `POST /api/ports` schedules the port change as a separate systemd unit a few seconds later (`systemd-run --on-active=3`), answers first, and the page then moves to the new address.
- **Writes need room.** Proxmox Metric Server sends batches up to 25 MB; `/influx/` allows 32 MB. Any reverse proxy in front needs the same.

## Services and images

- **Telegraf 1.38+ is strict about environment variables.** They're only substituted inside quoted strings, and the value is inserted as-is. Booleans can't come from the environment, so the configs use a placeholder that is replaced when the config is rendered.
- **Portainer 2.45 locks itself** if the admin isn't created within 5 minutes. Initialising the admin needs the `X-Setup-Token` from the container log (`setup_token=`).
- **Grafana v2 dashboard exports** aren't accepted by file provisioning as they are; `go-euc-grafana-dashboards.py` wraps them.
- **File modes inside `Dashboards.zip` matter.** One dashboard was packed with mode 0600 and Grafana couldn't read it. Pack with 644, and extract with `chmod -R a+rX`.
- **The Ubuntu cloud image disables SSH passwords** in `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`. The appliance's drop-in `10-go-euc.conf` sorts first and wins (sshd keeps the first value it reads).
- **Internet checks must fail fast.** Sequential probes with long timeouts took about 12 minutes to report "no internet". Probes now run in parallel with a 2-minute deadline.
- **Restarts look like errors.** `go-euc-status` ignores InfluxDB errors in the 2 minutes after a container restart.
- **`influx restore` into another org** needs both `--org <old>` and `--new-org <new>`.

## Ports and addresses

- **Keep the address in one place.** The web ports live in `/etc/go-euc/config.env` (`APPLIANCE_HTTP_PORT`, `APPLIANCE_HTTPS_PORT`). Everything that prints or embeds the appliance URL builds it from there, dropping `:443`. That covers first boot, the Telegraf configs, `config.txt`, `go-euc-status`, `go-euc-change-ip` and `go-euc-migrate`. When you add something that shows the address, add it to `go-euc-set-ports` as well.
- **When rewriting an address, match whole values.** `192.168.1.13` must not match inside `192.168.1.130`, and a port rewrite of `https://<ip>` must leave `:8086` and `:9443` alone.
