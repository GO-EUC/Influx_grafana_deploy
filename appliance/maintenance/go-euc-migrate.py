#!/usr/bin/env python3
"""Move data from an old GO-EUC appliance to this (new) one, over the network.

    sudo go-euc-migrate <old-appliance-address> [--token TOKEN] [--no-grafana] [--yes]

Run it on the NEW appliance once its setup is complete. The old appliance is only read, never
changed, and nothing needs to be installed on it. Steps:

  1. find the old appliance's InfluxDB API (https://<old>:8086 on current releases,
     http://<old>:8086 on older ones)
  2. get its InfluxDB admin token and Grafana login from http(s)://<old>/config.txt (or use
     --token / ask for it)
  3. back up the old InfluxDB over its API and write every bucket's data into this
     appliance's bucket of the same name (in this appliance's org, keeping its tokens)
  4. copy dashboards that were created in the old Grafana (not the preloaded GO-EUC ones,
     which this appliance already has) into a "Migrated from <old>" folder

Re-running is safe: points with the same series and timestamp are overwritten, dashboards are
updated in place. Infrastructure collector settings are not copied (their passwords never leave
the old appliance): re-enter them on this appliance's landing page.
"""
import argparse
import base64
import getpass
import json
import os
import re
import shlex
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

CREDENTIALS_FILE = "/opt/influx-grafana/credentials.env"
LOCAL_GRAFANA = "http://127.0.0.1:3000/grafana"
WORK = "/tmp/goeuc-migrate"            # inside the influxdb container
TEMP_PREFIX = "goeuc-migrate-"

INSECURE = ssl.create_default_context()
INSECURE.check_hostname = False
INSECURE.verify_mode = ssl.CERT_NONE


def say(msg):
    print(f"[migrate] {msg}", flush=True)


def die(msg):
    print(f"[migrate] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def http(method, url, headers=None, body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, context=INSECURE, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, raw
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()
    except (urllib.error.URLError, OSError) as exc:
        return 0, str(exc).encode()


def http_json(method, url, headers=None, body=None):
    code, raw = http(method, url, headers, body)
    try:
        return code, json.loads(raw) if raw else {}
    except ValueError:
        return code, {"_raw": raw[:200].decode("utf-8", "replace")}


def load_env(path):
    values = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            try:
                parts = shlex.split(line, comments=True)
            except ValueError:
                continue
            if len(parts) == 1 and "=" in parts[0]:
                k, v = parts[0].split("=", 1)
                values[k] = v
    return values


def run(cmd, env=None, check=True):
    """Run a command, passing secrets through the environment (never argv)."""
    result = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, **(env or {})})
    if check and result.returncode != 0:
        die(f"{' '.join(cmd[:6])} ... failed: {(result.stderr or result.stdout).strip()[-400:]}")
    return result


def influx(args, token, host=None, check=True, skip_verify=False):
    env_args = ["-e", "INFLUX_TOKEN"]
    env = {"INFLUX_TOKEN": token}
    if host:
        env_args += ["-e", "INFLUX_HOST"]
        env["INFLUX_HOST"] = host
    cmd = ["docker", "exec", *env_args, "influxdb", "influx", *args]
    if skip_verify:
        cmd.append("--skip-verify")
    return run(cmd, env=env, check=check)


def parse_config_txt(text):
    """config.txt: section title lines followed by Key=Value lines."""
    data, section = {}, None
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            data[(section, key)] = value
        else:
            section = line
    return data


def fetch_old_config(old):
    for url in (f"https://{old}/config.txt", f"http://{old}/config.txt"):
        code, raw = http("GET", url, timeout=10)
        text = raw.decode("utf-8", "replace") if raw else ""
        if code == 200 and "GO-EUC APPLIANCE CONFIG" in text:
            return url, parse_config_txt(text)
        if code == 403:
            say(f"{url}: refused (403). Current appliances only serve config.txt to their own subnet.")
    return None, {}


def find_old_influx(old):
    for base, tls in ((f"https://{old}:8086", True), (f"http://{old}:8086", False)):
        code, body = http_json("GET", f"{base}/health")
        if code == 200 and body.get("status") == "pass":
            return base, tls
    return None, False


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("old", help="address (IP or name) of the old appliance; add :<port> if its web server "
                                    "uses non-standard ports (e.g. 192.168.1.50:4443)")
    parser.add_argument("--token", help="old appliance's InfluxDB admin token (default: read from its config.txt, or ask)")
    parser.add_argument("--no-grafana", action="store_true", help="do not copy Grafana dashboards")
    parser.add_argument("--yes", action="store_true", help="do not ask for confirmation")
    args = parser.parse_args()

    if os.geteuid() != 0:
        os.execvp("sudo", ["sudo", sys.executable, *sys.argv])
    if not os.path.exists("/var/lib/go-euc/.installed"):
        die("this appliance has not finished its setup yet")
    local = load_env(CREDENTIALS_FILE)
    new_org, new_token = local["SAVED_INFLUX_ADMIN_ORG"], local["SAVED_INFLUX_ADMIN_TOKEN"]

    # 1. Old InfluxDB.
    # "host:port" = web server port (config.txt, Grafana); InfluxDB is always on host:8086.
    old_host = args.old.rsplit(":", 1)[0] if re.fullmatch(r"[^:]+:\d+", args.old) else args.old
    old_influx, old_tls = find_old_influx(old_host)
    if not old_influx:
        die(f"no InfluxDB answering on https://{old_host}:8086 or http://{old_host}:8086. "
            "Check the address, that the old appliance is running, and that port 8086 is reachable from here.")
    say(f"old InfluxDB: {old_influx}")

    # 2. Credentials.
    cfg_url, cfg = fetch_old_config(args.old)
    token = args.token or cfg.get(("InfluxDB", "AdminToken")) or cfg.get(("Telegraf", "InfluxToken"))
    if cfg_url:
        say(f"read {cfg_url}")
    if not token:
        if not sys.stdin.isatty():
            die("could not read the old appliance's config.txt; pass --token <old InfluxDB admin token>")
        print("Paste the OLD appliance's InfluxDB admin token. It is in the old appliance's config.txt "
              "(InfluxDB > AdminToken, or Telegraf > InfluxToken on older releases) or in "
              "/opt/influx-grafana/install-summary.txt there.")
        token = getpass.getpass("Old InfluxDB admin token: ").strip()
    auth = {"Authorization": f"Token {token}"}
    code, orgs = http_json("GET", f"{old_influx}/api/v2/orgs", auth)
    if code != 200 or not orgs.get("orgs"):
        die(f"the old InfluxDB rejected the token (HTTP {code}). It must be the admin token, not a write-only Telegraf token.")
    old_org = orgs["orgs"][0]
    code, buckets = http_json("GET", f"{old_influx}/api/v2/buckets?orgID={old_org['id']}&limit=100", auth)
    names = sorted(b["name"] for b in buckets.get("buckets", []) if not b["name"].startswith("_"))
    if not names:
        die("the old InfluxDB has no buckets to migrate")

    grafana_old = None
    if not args.no_grafana:
        g_user, g_pass = cfg.get(("Grafana", "Username")), cfg.get(("Grafana", "Password"))
        if g_user and g_pass:
            g_auth = {"Authorization": "Basic " + base64.b64encode(f"{g_user}:{g_pass}".encode()).decode()}
            for base in (f"https://{args.old}/grafana", f"http://{old_host}:3000/grafana"):
                code, _ = http_json("GET", f"{base}/api/user", g_auth)
                if code == 200:
                    grafana_old = (base, g_auth)
                    break
        if not grafana_old:
            say("old Grafana login not available from config.txt: dashboards will not be copied")

    # 3. Confirm.
    print()
    print(f"  From:  {args.old} (InfluxDB org '{old_org['name']}', buckets: {', '.join(names)})")
    print(f"  To:    this appliance (org '{new_org}'), into buckets of the same name")
    print(f"  Grafana dashboards made by hand: {'copied' if grafana_old else 'not copied'}")
    print("  The old appliance is only read, not changed.")
    print()
    if not args.yes:
        if not sys.stdin.isatty() or input("Continue? [y/N] ").strip().lower() not in ("y", "yes"):
            die("cancelled")

    # 4. Data: remote backup, then per bucket restore into a temporary bucket, export it as line
    #    protocol and write it into this appliance's bucket (keeps its bucket IDs and tokens).
    run(["docker", "exec", "influxdb", "rm", "-rf", WORK])
    say("downloading a backup from the old InfluxDB (this can take a while for large databases)...")
    influx(["backup", WORK, "--org", old_org["name"]], token, host=old_influx, skip_verify=old_tls)
    size = run(["docker", "exec", "influxdb", "du", "-sh", WORK]).stdout.split()[0]
    say(f"backup downloaded ({size})")

    for name in names:
        temp = TEMP_PREFIX + name
        influx(["bucket", "delete", "--name", temp, "--org", new_org], new_token, check=False)
        # --org is the bucket's ORIGINAL org (on the old appliance); --new-org the target here.
        influx(["restore", WORK, "--org", old_org["name"], "--bucket", name, "--new-bucket", temp,
                "--new-org", new_org], new_token)
        listed = influx(["bucket", "list", "--name", temp, "--org", new_org, "--hide-headers"], new_token).stdout.split()
        temp_id = listed[0]
        out = f"/tmp/{temp}.lp.gz"
        run(["docker", "exec", "influxdb", "influxd", "inspect", "export-lp", "--bucket-id", temp_id,
             "--engine-path", "/var/lib/influxdb2/engine", "--output-path", out, "--compress", "--log-level", "error"])
        points = run(["docker", "exec", "influxdb", "sh", "-c", f"gzip -dc {out} | wc -l"]).stdout.strip()
        if points != "0":
            if influx(["bucket", "find", "--name", name, "--org", new_org], new_token, check=False).returncode != 0:
                influx(["bucket", "create", "--name", name, "--org", new_org], new_token)
                say(f"bucket {name}: created")
            influx(["write", "--bucket", name, "--org", new_org, "--file", out, "--compression", "gzip", "--format", "lp"], new_token)
        run(["docker", "exec", "influxdb", "rm", "-f", out])
        influx(["bucket", "delete", "--name", temp, "--org", new_org], new_token)
        say(f"bucket {name}: {points} points copied")
    run(["docker", "exec", "influxdb", "rm", "-rf", WORK])

    # 5. Dashboards made by hand in the old Grafana.
    copied = 0
    if grafana_old:
        base, g_auth = grafana_old
        local_auth = {"Authorization": "Basic " + base64.b64encode(
            f"{local['SAVED_GRAFANA_ADMIN_USER']}:{local['SAVED_GRAFANA_ADMIN_PASSWORD']}".encode()).decode()}
        _, found = http_json("GET", f"{base}/api/search?type=dash-db&limit=5000", g_auth)
        folder_uid = None
        for item in found if isinstance(found, list) else []:
            code, full = http_json("GET", f"{base}/api/dashboards/uid/{item['uid']}", g_auth)
            if code != 200:
                say(f"dashboard '{item.get('title')}': could not read it from the old Grafana (HTTP {code}), skipped")
                continue
            if full.get("meta", {}).get("provisioned"):
                continue  # preloaded GO-EUC dashboards: this appliance has its own copies
            if folder_uid is None:
                title = f"Migrated from {args.old}"
                _, folders = http_json("GET", f"{LOCAL_GRAFANA}/api/folders?limit=1000", local_auth)
                folder_uid = next((f["uid"] for f in folders if f.get("title") == title), None) if isinstance(folders, list) else None
                if not folder_uid:
                    _, made = http_json("POST", f"{LOCAL_GRAFANA}/api/folders", local_auth, {"title": title})
                    folder_uid = made.get("uid")
            dash = full["dashboard"]
            dash["id"] = None
            code, res = http_json("POST", f"{LOCAL_GRAFANA}/api/dashboards/db", local_auth,
                                  {"dashboard": dash, "folderUid": folder_uid, "overwrite": True,
                                   "message": f"migrated from {args.old}"})
            if code == 200:
                copied += 1
                say(f"dashboard '{dash.get('title')}' copied")
            else:
                say(f"dashboard '{dash.get('title')}': copy failed (HTTP {code}: {str(res)[:150]})")
        say(f"{copied} hand-made dashboard(s) copied" if copied else "no hand-made dashboards to copy")

    print()
    say("Done. Next steps:")
    print("  - Windows machines: install this appliance's Telegraf config from https://<this-appliance>/telegraf/")
    print("    (new address and token), then Restart-Service telegraf.")
    print("  - Infrastructure collectors: enter their settings on this appliance's landing page.")
    print("  - Proxmox Metric Server / Let's Encrypt: point them at this appliance (see the landing page).")
    print("  - Check Grafana shows the old data, then shut the old appliance down.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
