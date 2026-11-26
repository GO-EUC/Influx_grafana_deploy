# Testing with benchmarkle

The landing page's **Testing** section connects the appliance to [GO-EUC/benchmarkle](https://github.com/GO-EUC/benchmarkle), the GO-EUC research framework. benchmarkle deploys short-lived Windows VMs in Azure, runs the OBUX benchmark on them, writes the results to InfluxDB and destroys the VMs again, all from GitHub Actions. The appliance:

1. creates **your GitHub environment** in the benchmarkle repository, with everything it needs to write to this appliance's InfluxDB,
2. signs you in to **Azure** and runs benchmarkle's `Setup.ps1` for the Azure side,
3. **starts research runs** and lists them.

The results show up in the appliance's Grafana dashboards (Analyzing, Comparing New, Windows Process Test Runs).

## Before you start

| You need | Why |
|---|---|
| Membership of the GO-EUC organisation, with **admin** on the benchmarkle repository | Creating an environment needs admin. |
| The appliance **reachable from the internet** with a **trusted certificate**: a public host name and Let's Encrypt, or a reverse proxy with its own certificate ([External access](external-access.md)) | GitHub's runners and the Azure test VMs write to the appliance's InfluxDB directly, and verify its certificate. |
| *Maintenance → Public host name* set (or an active Let's Encrypt certificate) | That address becomes `INFLUX_URL` in your environment. |
| An Azure subscription where you are **Owner** (or User Access Administrator) | `Setup.ps1` creates a managed identity and gives it Contributor on the subscription. |
| Optional: an **Anthropic API key** | The analysis after each research uses it for a written conclusion and website charts; without it you get the statistics only. |

PowerShell 7, the Azure CLI and the GitHub CLI are installed on the appliance during first boot (`go-euc-install-test-tools.sh`) and updated by *Run Full Appliance Update*. The section shows their versions; if one is missing, run the full update.

## Step by step

### Anthropic API key

Paste the key and *Save key*. The appliance checks it with Anthropic, stores it in `credentials.env` (root-only) and lists it in `config.txt` under `Anthropic`. If your environment already exists, the environment's `ANTHROPIC_API_KEY` secret is updated as well.

### GitHub access

Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new):

- Resource owner: **GO-EUC**; repository access: **Only select repositories → benchmarkle**
- Repository permissions: **Actions**, **Administration**, **Environments**, **Secrets** and **Variables**: read and write; **Contents**: read-only

Paste it and *Save token*. The appliance checks that it can see the repository, that your account is admin, and that it can read environments, then stores it root-only in `/etc/go-euc/benchmarkle.env` (not in `config.txt`). If the organisation reviews fine-grained tokens, an owner has to approve it first.

### 1. Your environment

Enter your full name (and optionally the OBUX contact address) and click *Set up environment*. Your name becomes the environment's name exactly as `Setup.ps1` makes it (`Jane Doe` → `jane-doe`). The appliance:

| Step | Result |
|---|---|
| InfluxDB buckets | `Tests`, `Performance` and `OBUX` exist (`OBUX` is created if needed) |
| InfluxDB token | a token for this environment with read and write on those three buckets (reused when you run it again) |
| GitHub environment | `<your-name>` in GO-EUC/benchmarkle |
| Secrets | `INFLUXDB_TOKEN`, `ANTHROPIC_API_KEY` (when saved on the appliance) |
| Variables | `INFLUX_URL` (the appliance's public address), `INFLUX_ORG` (its InfluxDB organisation), `OBUX_EMAIL` (when given) |

Run it again whenever you change the Anthropic key, the public host name or the web ports.

> `INFLUX_URL`, `INFLUX_ORG` and `OBUX_EMAIL` need a benchmarkle version that reads them (the *Your own InfluxDB* section of its README). Older versions write to the InfluxDB named in the research file instead.

### 2. Azure

1. Optionally enter your tenant (ID or domain), then *Sign in to Azure*.
2. A code appears: open the link, enter the code and sign in with your Azure account. The page continues by itself.
3. Pick the **subscription** and the region for the Terraform state and the identity (default `westeurope`), and click *Run Setup.ps1*.

`Setup.ps1` runs from a fresh copy of the repository and its output appears in the card. It creates (or reuses) the Terraform state storage, your managed identity with its federated credential for your environment, the role assignments, and your environment's Azure variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `TF_STATE_RG`, `TF_STATE_STORAGE`, `TF_STATE_CONTAINER`). It's safe to run again.

The Azure sign-in is stored on the appliance (`/var/lib/go-euc/azure`, root-only). It isn't needed for the research runs themselves: those use the managed identity.

### 3. Run a research

Pick a research file (read live from the repository), then:

- **Validate only** (ticked by default): checks the research file in GitHub Actions without creating anything. Use it first.
- **Analyse afterwards**: statistics, plus a conclusion and charts with the Anthropic key.

Untick *Validate only* for a real run. The page asks for confirmation: a real run deploys the research's VMs in your subscription, which costs money until they are destroyed (always, also on failure). *Recent runs* lists your environment's runs with links to GitHub.

## From the command line

Everything on the page is also available over SSH, with JSON on standard input (secrets never go on the command line):

```bash
sudo go-euc-benchmarkle status
echo '{"name": "Jane Doe"}' | sudo go-euc-benchmarkle setup-environment
echo '{"config": "research/win11-25h2-vs-26h2.json", "validate_only": true}' | sudo go-euc-benchmarkle run-research
```

`sudo go-euc-benchmarkle --help` lists the commands. To use another branch of benchmarkle (for example to try a change before it's merged), add `BENCHMARKLE_REF=<branch>` to `/etc/go-euc/benchmarkle.env`.

## Troubleshooting

| Symptom | Check |
|---|---|
| "The appliance has no public address yet" | Set *Maintenance → Public host name*, or get a Let's Encrypt certificate. |
| Token rejected / "can't read environments" | The token's repository access and permissions (above); organisation approval of the token. |
| `Setup.ps1` fails on role assignments | Your Azure account needs Owner or User Access Administrator on the subscription. |
| Research fails writing to InfluxDB | From outside your network, `https://<public-name>/influx/health` must answer with a valid certificate. Check the environment's `INFLUX_URL`. |
| Data lands in another InfluxDB | The benchmarkle version doesn't read `INFLUX_URL` yet (see the note under step 1). |
