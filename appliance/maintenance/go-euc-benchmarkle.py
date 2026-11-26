#!/usr/bin/env python3
"""GO-EUC appliance <-> GO-EUC/benchmarkle (the landing page's Testing section).

    go-euc-benchmarkle <command>            JSON in on stdin (secrets only ever arrive this way), JSON out

Commands:
    status                    tools, GitHub access, Anthropic key, environment, Azure sign-in and jobs
    set-github-token          {"token"}     check and store a GitHub token (root-only)
    clear-github-token
    set-anthropic-key         {"key"}       store the Anthropic API key (credentials.env and config.txt)
    clear-anthropic-key
    setup-environment         {"name", "obux_email"}
                                            InfluxDB bucket and token, then the person's GitHub environment
                                            with INFLUXDB_TOKEN, ANTHROPIC_API_KEY, INFLUX_URL, INFLUX_ORG, OBUX_EMAIL
    azure-login               {"tenant"}    start an Azure device sign-in (code shown by status)
    azure-cancel                            stop a pending sign-in or setup
    azure-subscriptions                     subscriptions of the signed-in account
    azure-setup               {"subscription", "location"}
                                            run benchmarkle's scripts/Setup.ps1 for the person (background job)
    research-list                           research files in the repository
    run-research              {"config", "validate_only", "analyse"}
                                            start the Research workflow in the person's environment
    runs                                    recent Research runs of the person's environment

Runs as root (the landing page's API backend runs as root). Settings: /etc/go-euc/benchmarkle.env.
"""

import json
import os
import re
import shlex
import ssl
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

SETTINGS_FILE = "/etc/go-euc/benchmarkle.env"
CREDENTIALS_FILE = "/opt/influx-grafana/credentials.env"
CONFIG_TXT = "/opt/influx-grafana/public/config.txt"
PUBLIC_URL_CMD = "/usr/local/bin/go-euc-public-url.sh"
STATE_DIR = "/var/lib/go-euc/benchmarkle"
CLONE_DIR = os.path.join(STATE_DIR, "repo")
GH_CONFIG_DIR = "/var/lib/go-euc/gh"
AZURE_CONFIG_DIR = "/var/lib/go-euc/azure"
INFLUX_LOCAL = "https://127.0.0.1:8086"
GITHUB_API = "https://api.github.com"
DEFAULT_REPO = "GO-EUC/benchmarkle"
DEFAULT_REF = "main"
WORKFLOW = "research.yml"
BUCKETS = ("Tests", "Performance", "OBUX")
JOBS = {"azure-login": "goeuc-benchmarkle-azure-login", "azure-setup": "goeuc-benchmarkle-azure-setup"}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,29}$")
CONFIG_PATH_RE = re.compile(r"^research/[A-Za-z0-9._-]+\.json$")
EMAIL_RE = re.compile(r"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$")
UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")
LOCATION_RE = re.compile(r"^[a-z0-9]{2,40}$")
TENANT_RE = re.compile(r"^[A-Za-z0-9.-]{3,100}$")


class Fail(Exception):
    """An error to report to the user (message only, never a secret)."""


# ----------------------------------------------------------------------------- files

def read_env(path):
    values = {}
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return values
    for line in text.splitlines():
        try:
            parts = shlex.split(line, comments=True)
        except ValueError:
            continue
        if len(parts) == 1 and "=" in parts[0]:
            key, value = parts[0].split("=", 1)
            values[key] = value
    return values


def upsert_env(path, updates, mode=0o600):
    """Set (value) or remove (None) keys in a KEY=value file, keeping everything else."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        lines = []
    keys = set(updates)
    kept = [line for line in lines if not re.match(r"^(?:export\s+)?(%s)=" % "|".join(map(re.escape, keys)), line)]
    kept += [f"{key}={shlex.quote(value)}" for key, value in updates.items() if value is not None]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("\n".join(kept) + "\n")
    try:
        st = os.stat(path)
        os.chown(path + ".tmp", st.st_uid, st.st_gid)
    except OSError:
        pass
    os.chmod(path + ".tmp", mode)
    os.replace(path + ".tmp", path)


def config_txt_section(name, values):
    """Replace (or add, or with values=None remove) one section of config.txt, in place (keeps owner and mode)."""
    try:
        text = open(CONFIG_TXT, encoding="utf-8").read()
    except OSError:
        return
    blocks = text.rstrip("\n").split("\n\n")
    blocks = [b for b in blocks if b.split("\n", 1)[0].strip() != name]
    if values:
        blocks.append("\n".join([name] + [f"{k}={v}" for k, v in values.items()]))
    new = "\n\n".join(blocks) + "\n"
    with open(CONFIG_TXT, "r+", encoding="utf-8") as fh:
        fh.seek(0)
        fh.write(new)
        fh.truncate()


def settings():
    s = read_env(SETTINGS_FILE)
    s.setdefault("BENCHMARKLE_REPO", DEFAULT_REPO)
    s.setdefault("BENCHMARKLE_REF", DEFAULT_REF)
    return s


def save_settings(**updates):
    upsert_env(SETTINGS_FILE, updates)


def slugify(name):
    """Same as benchmarkle's ConvertTo-Slug (environment names must match Setup.ps1)."""
    ascii_name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", ascii_name.lower())).strip("-")


def public_address():
    try:
        out = subprocess.run([PUBLIC_URL_CMD], capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def tool_versions():
    def run(cmd):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            return r.stdout.strip() if r.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            return None
    gh = run(["gh", "--version"])
    return {
        "pwsh": run(["pwsh", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"]),
        "az": run(["az", "version", "--query", '"azure-cli"', "-o", "tsv"]) if os.path.exists("/usr/bin/az") else None,
        "gh": gh.split()[2] if gh else None,
    }


# ----------------------------------------------------------------------------- HTTP

def http(method, url, headers=None, body=None, timeout=30, verify=True):
    data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    ctx = None if verify else ssl._create_unverified_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw and raw[:1] in (b"{", b"[") else raw)
    except urllib.error.HTTPError as err:
        raw = err.read()
        try:
            return err.code, json.loads(raw)
        except ValueError:
            return err.code, raw
    except (urllib.error.URLError, OSError) as err:
        raise Fail(f"cannot reach {urllib.parse.urlsplit(url).netloc}: {getattr(err, 'reason', err)}")


def github(method, path, token, body=None, raw=False):
    headers = {"Authorization": f"Bearer {token}", "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "go-euc-appliance", "Accept": "application/vnd.github.raw" if raw else "application/vnd.github+json"}
    return http(method, f"{GITHUB_API}{path}", headers, body)


def need_token(s):
    token = s.get("GITHUB_TOKEN")
    if not token:
        raise Fail("Add a GitHub token first (Testing > GitHub access).")
    return token


def need_environment(s):
    slug = s.get("BENCHMARKLE_ENV")
    if not slug:
        raise Fail("Set up your environment first (Testing > 1. Your environment).")
    return slug


def influx(method, path, body=None):
    cred = read_env(CREDENTIALS_FILE)
    token = cred.get("SAVED_INFLUX_ADMIN_TOKEN")
    if not token:
        raise Fail("InfluxDB admin token not found on the appliance.")
    code, data = http(method, f"{INFLUX_LOCAL}{path}", {"Authorization": f"Token {token}"}, body, verify=False)
    return code, data, cred


def gh_env():
    env = dict(os.environ, GH_TOKEN=need_token(settings()), GH_CONFIG_DIR=GH_CONFIG_DIR,
               GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1", NO_COLOR="1")
    os.makedirs(GH_CONFIG_DIR, mode=0o700, exist_ok=True)
    return env


def az(*args, timeout=120):
    env = dict(os.environ, AZURE_CONFIG_DIR=AZURE_CONFIG_DIR, AZURE_CORE_LOGIN_EXPERIENCE_V2="off",
               AZURE_CORE_COLLECT_TELEMETRY="false", AZURE_CORE_ONLY_SHOW_ERRORS="true")
    os.makedirs(AZURE_CONFIG_DIR, mode=0o700, exist_ok=True)
    try:
        return subprocess.run(["az", *args], capture_output=True, text=True, timeout=timeout, env=env)
    except FileNotFoundError:
        raise Fail("The Azure CLI isn't installed yet: run Maintenance > Run Full Appliance Update.")


# ----------------------------------------------------------------------------- background jobs

def job_paths(job):
    return os.path.join(STATE_DIR, f"{job}.log"), os.path.join(STATE_DIR, f"{job}.rc")


def start_job(job, argv, env, cwd=None):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    unit = JOBS[job]
    subprocess.run(["systemctl", "stop", unit], capture_output=True)
    subprocess.run(["systemctl", "reset-failed", unit], capture_output=True)
    log, rc = job_paths(job)
    envfile = os.path.join(STATE_DIR, f"{job}.env")
    for path in (log, rc):
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    # Secrets (GH_TOKEN) go through a root-only environment file, never the command line; removed when done.
    fd = os.open(envfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("".join(f"{k}={shlex.quote(v)}\n" for k, v in env.items()))
    script = (f"set -a; . {shlex.quote(envfile)}; set +a; rm -f {shlex.quote(envfile)}; "
              f"{shlex.join(argv)} >>{shlex.quote(log)} 2>&1; echo $? >{shlex.quote(rc)}")
    cmd = ["systemd-run", "--unit", unit, "--collect", "--quiet", "-p", "TimeoutStopSec=10"]
    if cwd:
        cmd += ["-p", f"WorkingDirectory={cwd}"]
    cmd += ["/bin/bash", "-c", script]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise Fail(f"could not start {job}: {result.stderr.strip()[:200]}")


def job_status(job):
    log, rc = job_paths(job)
    active = subprocess.run(["systemctl", "is-active", JOBS[job]], capture_output=True, text=True).stdout.strip()
    try:
        text = open(log, encoding="utf-8", errors="replace").read()
    except OSError:
        text = None
    try:
        code = int(open(rc).read().strip())
    except (OSError, ValueError):
        code = None
    state = "running" if active in ("active", "activating") else ("none" if text is None else ("succeeded" if code == 0 else "failed"))
    return {"state": state, "exit_code": code, "log": "\n".join((text or "").splitlines()[-80:])}


# ----------------------------------------------------------------------------- commands

def cmd_status(_):
    s = settings()
    pub = public_address()
    cred = read_env(CREDENTIALS_FILE)
    key = cred.get("SAVED_ANTHROPIC_API_KEY", "")
    login = job_status("azure-login")
    device = None
    if login["state"] == "running":
        m = re.search(r"(https://\S*(?:devicelogin|/device)\S*)\D+?code ([A-Z0-9]{6,12})", login["log"])
        if m:
            device = {"url": m.group(1), "code": m.group(2)}
    account = None
    if os.path.exists("/usr/bin/az"):
        r = az("account", "show", "-o", "json", timeout=30)
        if r.returncode == 0:
            a = json.loads(r.stdout)
            account = {"user": a.get("user", {}).get("name"), "subscription": a.get("name"),
                       "subscription_id": a.get("id"), "tenant_id": a.get("tenantId")}
    repo, slug = s["BENCHMARKLE_REPO"], s.get("BENCHMARKLE_ENV")
    return {
        "ok": True,
        "tools": tool_versions(),
        "repo": repo, "ref": s["BENCHMARKLE_REF"],
        "github": {"configured": bool(s.get("GITHUB_TOKEN")), "login": s.get("GITHUB_LOGIN", "")},
        "anthropic": {"configured": bool(key), "hint": f"...{key[-4:]}" if len(key) > 8 else ""},
        "environment": {"name": s.get("BENCHMARKLE_NAME", ""), "slug": slug or "", "obux_email": s.get("OBUX_EMAIL", ""),
                        "set_up": s.get("BENCHMARKLE_SETUP_UTC", ""),
                        "url": f"https://github.com/{repo}/settings/environments" if slug else ""},
        "public": {"base_url": pub.get("PUBLIC_BASE", ""), "source": pub.get("PUBLIC_SOURCE", ""),
                   "tls_verify": pub.get("PUBLIC_TLS_VERIFY") == "true"},
        "azure": {"account": account, "device": device, "login": login, "setup": job_status("azure-setup"),
                  "setup_done": s.get("AZURE_SETUP_UTC", "")},
    }


def cmd_set_github_token(data):
    token = str(data.get("token", "")).strip()
    if not re.fullmatch(r"[A-Za-z0-9_]{20,255}", token):
        raise Fail("That doesn't look like a GitHub token (github_pat_... or ghp_...).")
    s = settings()
    repo = s["BENCHMARKLE_REPO"]
    code, user = github("GET", "/user", token)
    if code == 401:
        raise Fail("GitHub rejected the token (401): check it hasn't expired.")
    code, info = github("GET", f"/repos/{repo}", token)
    if code != 200:
        raise Fail(f"The token can't see {repo} ({code}). Give it access to that repository.")
    if not info.get("permissions", {}).get("admin"):
        raise Fail(f"Your account needs admin on {repo} to create environments.")
    code, _ = github("GET", f"/repos/{repo}/environments", token)
    if code != 200:
        raise Fail(f"The token can't read environments of {repo} ({code}): grant Administration and Environments (read and write).")
    login = user.get("login", "") if isinstance(user, dict) else ""
    save_settings(GITHUB_TOKEN=token, GITHUB_LOGIN=login)
    return {"ok": True, "message": f"GitHub token saved: signed in as {login}, admin on {repo}."}


def cmd_clear_github_token(_):
    save_settings(GITHUB_TOKEN=None, GITHUB_LOGIN=None)
    return {"ok": True, "message": "GitHub token removed from the appliance."}


def cmd_set_anthropic_key(data):
    key = str(data.get("key", "")).strip()
    if not re.fullmatch(r"sk-ant-[A-Za-z0-9_-]{20,300}", key):
        raise Fail("That doesn't look like an Anthropic API key (sk-ant-...).")
    note = ""
    try:
        code, _ = http("GET", "https://api.anthropic.com/v1/models?limit=1",
                       {"x-api-key": key, "anthropic-version": "2023-06-01", "User-Agent": "go-euc-appliance"}, timeout=15)
        if code in (401, 403):
            raise Fail("Anthropic rejected the key: check it in the Anthropic console.")
        note = " Checked with Anthropic." if code == 200 else ""
    except Fail as err:
        if "rejected" in str(err):
            raise
        note = " (Not checked: Anthropic wasn't reachable.)"
    upsert_env(CREDENTIALS_FILE, {"SAVED_ANTHROPIC_API_KEY": key})
    config_txt_section("Anthropic", {"ApiKey": key})
    s = settings()
    if s.get("GITHUB_TOKEN") and s.get("BENCHMARKLE_ENV"):
        set_secret(s["BENCHMARKLE_REPO"], s["BENCHMARKLE_ENV"], "ANTHROPIC_API_KEY", key)
        note += f" Also updated in your environment '{s['BENCHMARKLE_ENV']}'."
    return {"ok": True, "message": "Anthropic API key saved." + note}


def cmd_clear_anthropic_key(_):
    upsert_env(CREDENTIALS_FILE, {"SAVED_ANTHROPIC_API_KEY": None})
    config_txt_section("Anthropic", None)
    return {"ok": True, "message": "Anthropic API key removed from the appliance (a copy in a GitHub environment stays until you remove it there)."}


def set_secret(repo, slug, name, value):
    try:
        r = subprocess.run(["gh", "secret", "set", name, "--env", slug, "--repo", repo], input=value,
                           capture_output=True, text=True, env=gh_env(), timeout=60)
    except FileNotFoundError:
        raise Fail("The GitHub CLI isn't installed yet: run Maintenance > Run Full Appliance Update.")
    if r.returncode != 0:
        raise Fail(f"could not set the secret {name}: {r.stderr.strip()[:200]}")


def set_variable(repo, slug, token, name, value):
    path = f"/repos/{repo}/environments/{urllib.parse.quote(slug)}/variables"
    code, _ = github("PATCH", f"{path}/{name}", token, {"name": name, "value": value})
    if code == 404:
        code, _ = github("POST", path, token, {"name": name, "value": value})
    if code not in (200, 201, 204):
        raise Fail(f"could not set the variable {name} ({code})")


def ensure_influx_token(slug):
    """Buckets Tests/Performance/OBUX exist; a token with read+write on them for this environment (reused if valid)."""
    code, orgs, cred = influx("GET", "/api/v2/orgs?org=" + urllib.parse.quote(read_env(CREDENTIALS_FILE).get("SAVED_INFLUX_ADMIN_ORG", "")))
    if code != 200 or not orgs.get("orgs"):
        raise Fail(f"InfluxDB org not found ({code}).")
    org = orgs["orgs"][0]
    ids, created = {}, []
    for name in BUCKETS:
        code, found, _ = influx("GET", f"/api/v2/buckets?orgID={org['id']}&name={name}")
        buckets = found.get("buckets", []) if code == 200 else []
        if buckets:
            ids[name] = buckets[0]["id"]
            continue
        code, made, _ = influx("POST", "/api/v2/buckets", {"orgID": org["id"], "name": name, "retentionRules": []})
        if code not in (200, 201):
            raise Fail(f"could not create the InfluxDB bucket {name} ({code}).")
        ids[name] = made["id"]
        created.append(name)
    s = settings()
    token_id, token = s.get("INFLUX_TOKEN_ID"), s.get("INFLUX_TOKEN")
    if token_id and token and s.get("INFLUX_TOKEN_ENV") == slug:
        code, auth, _ = influx("GET", f"/api/v2/authorizations/{token_id}")
        if code == 200 and auth.get("status") == "active":
            return org["name"], token, created, False
    perms = [{"action": action, "resource": {"type": "buckets", "id": ids[b], "orgID": org["id"]}}
             for b in BUCKETS for action in ("read", "write")]
    code, auth, _ = influx("POST", "/api/v2/authorizations",
                           {"orgID": org["id"], "description": f"benchmarkle {slug} (read/write Tests, Performance, OBUX)",
                            "permissions": perms})
    if code not in (200, 201):
        raise Fail(f"could not create the InfluxDB token ({code}).")
    save_settings(INFLUX_TOKEN_ID=auth["id"], INFLUX_TOKEN=auth["token"], INFLUX_TOKEN_ENV=slug)
    return org["name"], auth["token"], created, True


def cmd_setup_environment(data):
    name = " ".join(str(data.get("name", "")).split())
    slug = slugify(name)
    if not name or not SLUG_RE.match(slug):
        raise Fail("Enter your full name (letters, digits and spaces; it becomes the environment name, max 30 characters).")
    email = str(data.get("obux_email", "")).strip()
    if email and not EMAIL_RE.match(email):
        raise Fail("The OBUX email address isn't valid.")
    s = settings()
    token, repo = need_token(s), s["BENCHMARKLE_REPO"]
    pub = public_address()
    if pub.get("PUBLIC_SOURCE", "ip") == "ip":
        raise Fail("The appliance has no public address yet. GitHub's runners and the Azure test VMs write to its "
                   "InfluxDB over the internet: set Maintenance > Public host name (or get a Let's Encrypt certificate) first.")
    steps = []
    org, influx_token, created, new = ensure_influx_token(slug)
    if created:
        steps.append(f"created InfluxDB bucket(s): {', '.join(created)}")
    steps.append(("created" if new else "reused") + " the InfluxDB token for this environment (read/write Tests, Performance, OBUX)")

    code, _ = github("PUT", f"/repos/{repo}/environments/{urllib.parse.quote(slug)}", token, {})
    if code not in (200, 201):
        raise Fail(f"could not create the GitHub environment '{slug}' ({code}).")
    steps.append(f"GitHub environment '{slug}' ready")
    set_secret(repo, slug, "INFLUXDB_TOKEN", influx_token)
    steps.append("secret INFLUXDB_TOKEN set")
    key = read_env(CREDENTIALS_FILE).get("SAVED_ANTHROPIC_API_KEY")
    if key:
        set_secret(repo, slug, "ANTHROPIC_API_KEY", key)
        steps.append("secret ANTHROPIC_API_KEY set")
    else:
        steps.append("no Anthropic API key on the appliance: the analysis will produce statistics only (add one and run this again)")
    variables = {"INFLUX_URL": pub["PUBLIC_BASE"], "INFLUX_ORG": org}
    if email:
        variables["OBUX_EMAIL"] = email
    for var, value in variables.items():
        set_variable(repo, slug, token, var, value)
        steps.append(f"variable {var} = {value}")
    save_settings(BENCHMARKLE_NAME=name, BENCHMARKLE_ENV=slug, OBUX_EMAIL=email or None,
                  BENCHMARKLE_SETUP_UTC=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    if not pub.get("PUBLIC_TLS_VERIFY") == "true":
        steps.append(f"note: make sure {pub['PUBLIC_BASE']} has a trusted certificate (Let's Encrypt here or on your reverse proxy): runners and test VMs verify it")
    return {"ok": True, "slug": slug, "message": f"Environment '{slug}' is ready in {repo}. Next: Azure setup.",
            "output": "\n".join(f"- {line}" for line in steps)}


def cmd_azure_login(data):
    tenant = str(data.get("tenant", "")).strip()
    if tenant and not TENANT_RE.match(tenant):
        raise Fail("The tenant must be a tenant ID or a domain such as contoso.onmicrosoft.com.")
    if not os.path.exists("/usr/bin/az"):
        raise Fail("The Azure CLI isn't installed yet: run Maintenance > Run Full Appliance Update.")
    argv = ["az", "login", "--use-device-code", "--output", "none"] + (["--tenant", tenant] if tenant else [])
    start_job("azure-login", argv, {"AZURE_CONFIG_DIR": AZURE_CONFIG_DIR, "AZURE_CORE_LOGIN_EXPERIENCE_V2": "off",
                                    "AZURE_CORE_COLLECT_TELEMETRY": "false"})
    return {"ok": True, "message": "Azure sign-in started: the code appears in a few seconds."}


def cmd_azure_cancel(_):
    for unit in JOBS.values():
        subprocess.run(["systemctl", "stop", unit], capture_output=True)
    return {"ok": True, "message": "Stopped."}


def cmd_azure_subscriptions(_):
    r = az("account", "list", "--query", "[?state=='Enabled'].{id:id,name:name,tenantId:tenantId,isDefault:isDefault}", "-o", "json")
    if r.returncode != 0:
        raise Fail("Not signed in to Azure.")
    return {"ok": True, "subscriptions": json.loads(r.stdout or "[]")}


def cmd_azure_setup(data):
    s = settings()
    token, repo = need_token(s), s["BENCHMARKLE_REPO"]
    slug, name = need_environment(s), s.get("BENCHMARKLE_NAME", "")
    sub = str(data.get("subscription", "")).strip()
    location = str(data.get("location", "westeurope")).strip().lower() or "westeurope"
    if not UUID_RE.match(sub):
        raise Fail("Pick a subscription.")
    if not LOCATION_RE.match(location):
        raise Fail("The location must be an Azure region name such as westeurope.")
    for tool in ("pwsh", "az", "gh"):
        if subprocess.run(["which", tool], capture_output=True).returncode != 0:
            raise Fail(f"{tool} isn't installed yet: run Maintenance > Run Full Appliance Update.")
    r = az("account", "set", "--subscription", sub)
    if r.returncode != 0:
        raise Fail("Not signed in to Azure, or the subscription isn't available to you.")
    # A fresh copy of the repository for Setup.ps1 (small, shallow).
    subprocess.run(["rm", "-rf", "--one-file-system", CLONE_DIR], capture_output=True)
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    clone = subprocess.run(["gh", "repo", "clone", repo, CLONE_DIR, "--", "--depth", "1", "--branch", s["BENCHMARKLE_REF"], "-q"],
                           capture_output=True, text=True, env=gh_env(), timeout=120)
    if clone.returncode != 0:
        raise Fail(f"could not download {repo}: {clone.stderr.strip()[:200]}")
    argv = ["pwsh", "-NoProfile", "-NonInteractive", "-File", os.path.join(CLONE_DIR, "scripts", "Setup.ps1"),
            "-Name", name, "-Repo", repo, "-Location", location]
    env = {"GH_TOKEN": token, "GH_CONFIG_DIR": GH_CONFIG_DIR, "GH_PROMPT_DISABLED": "1", "NO_COLOR": "1",
           "AZURE_CONFIG_DIR": AZURE_CONFIG_DIR, "AZURE_CORE_LOGIN_EXPERIENCE_V2": "off", "AZURE_CORE_ONLY_SHOW_ERRORS": "true"}
    start_job("azure-setup", argv, env, cwd=CLONE_DIR)
    save_settings(AZURE_SUBSCRIPTION=sub, AZURE_LOCATION=location)
    return {"ok": True, "message": f"Setup.ps1 started for '{slug}' in subscription {sub}: follow it below (a few minutes)."}


def research_files(s, token):
    repo, ref = s["BENCHMARKLE_REPO"], s["BENCHMARKLE_REF"]
    code, listing = github("GET", f"/repos/{repo}/contents/research?ref={urllib.parse.quote(ref)}", token)
    if code != 200 or not isinstance(listing, list):
        raise Fail(f"could not list research files in {repo} ({code}).")
    files = []
    for item in listing:
        path = item.get("path", "")
        if not CONFIG_PATH_RE.match(path) or path.endswith("config.schema.json"):
            continue
        code, raw = github("GET", f"/repos/{repo}/contents/{path}?ref={urllib.parse.quote(ref)}", token, raw=True)
        entry = {"config": path, "title": path, "scenarios": 0, "vms": 0}
        try:
            cfg = json.loads(raw)
            defaults = cfg.get("defaults", {})
            entry.update(title=cfg["research"].get("title", path), description=cfg["research"].get("description", ""),
                         scenarios=len(cfg.get("scenarios", [])),
                         vms=sum(int(sc.get("vm_count", defaults.get("vm_count", 1))) for sc in cfg.get("scenarios", [])))
        except (ValueError, KeyError, TypeError, AttributeError):
            pass
        files.append(entry)
    return files


def cmd_research_list(_):
    s = settings()
    return {"ok": True, "research": research_files(s, need_token(s)), "repo": s["BENCHMARKLE_REPO"], "ref": s["BENCHMARKLE_REF"]}


def recent_runs(s, token, slug, limit=10):
    code, data = github("GET", f"/repos/{s['BENCHMARKLE_REPO']}/actions/workflows/{WORKFLOW}/runs?per_page=50", token)
    if code != 200:
        raise Fail(f"could not list workflow runs ({code}).")
    runs = [r for r in data.get("workflow_runs", []) if f"({slug})" in (r.get("display_title") or "")]
    return [{"id": r["id"], "title": r.get("display_title"), "status": r.get("status"), "conclusion": r.get("conclusion"),
             "created": r.get("created_at"), "url": r.get("html_url")} for r in runs[:limit]]


def cmd_run_research(data):
    s = settings()
    token, slug = need_token(s), need_environment(s)
    config = str(data.get("config", ""))
    if not CONFIG_PATH_RE.match(config):
        raise Fail("Pick a research file.")
    if config not in {f["config"] for f in research_files(s, token)}:
        raise Fail(f"{config} isn't in the repository.")
    validate_only = bool(data.get("validate_only"))
    analyse = bool(data.get("analyse", True))
    started = time.time()
    code, body = github("POST", f"/repos/{s['BENCHMARKLE_REPO']}/actions/workflows/{WORKFLOW}/dispatches", token,
                        {"ref": s["BENCHMARKLE_REF"],
                         "inputs": {"environment": slug, "config": config,
                                    "validate_only": str(validate_only).lower(), "analyse": str(analyse).lower()}})
    if code not in (200, 204):
        msg = body.get("message", "") if isinstance(body, dict) else ""
        raise Fail(f"GitHub didn't start the workflow ({code}) {msg}".strip())
    run = None
    for _ in range(10):
        time.sleep(3)
        for r in recent_runs(s, token, slug, limit=5):
            created = datetime.strptime(r["created"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
            if config in (r["title"] or "") and created >= started - 10:
                run = r
                break
        if run:
            break
    what = "Validation" if validate_only else "Research"
    if run:
        return {"ok": True, "run": run, "message": f"{what} started: {run['url']}"}
    return {"ok": True, "message": f"{what} requested; it will show up under Recent runs shortly."}


def cmd_runs(_):
    s = settings()
    slug = s.get("BENCHMARKLE_ENV")
    if not (s.get("GITHUB_TOKEN") and slug):
        return {"ok": True, "runs": []}
    return {"ok": True, "runs": recent_runs(s, s["GITHUB_TOKEN"], slug)}


COMMANDS = {
    "status": cmd_status, "set-github-token": cmd_set_github_token, "clear-github-token": cmd_clear_github_token,
    "set-anthropic-key": cmd_set_anthropic_key, "clear-anthropic-key": cmd_clear_anthropic_key,
    "setup-environment": cmd_setup_environment, "azure-login": cmd_azure_login, "azure-cancel": cmd_azure_cancel,
    "azure-subscriptions": cmd_azure_subscriptions, "azure-setup": cmd_azure_setup,
    "research-list": cmd_research_list, "run-research": cmd_run_research, "runs": cmd_runs,
}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", sys.executable, *sys.argv])
    raw = "" if sys.stdin.isatty() else sys.stdin.read()
    try:
        data = json.loads(raw) if raw.strip() else {}
        if not isinstance(data, dict):
            raise ValueError
    except ValueError:
        print(json.dumps({"ok": False, "message": "Invalid JSON input."}))
        sys.exit(2)
    try:
        result = COMMANDS[sys.argv[1]](data)
    except Fail as err:
        result = {"ok": False, "message": str(err)}
    except subprocess.TimeoutExpired:
        result = {"ok": False, "message": "A step took too long; try again."}
    print(json.dumps(result))
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
