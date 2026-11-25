#!/usr/bin/env python3

import http.server
import ipaddress
import json
import os
import pathlib
import re
import shlex
import socketserver
import subprocess
import urllib.parse

PUBLIC_DIR = "/opt/influx-grafana/public"
CREDENTIALS_FILE = "/opt/influx-grafana/credentials.env"
NGINX_CERT_DIR = "/opt/influx-grafana/nginx/certs"
PROXMOX_PUSH_BUCKET = "Proxmox"
CONFIG_ENV_FILE = "/etc/go-euc/config.env"
REFRESH_CMD = ["/usr/local/bin/go-euc-refresh-telegraf.sh"]
FULL_UPDATE_CMD = ["/usr/local/bin/go-euc-appliance-update.sh"]
LE_RENEW_CMD = ["/usr/local/bin/go-euc-renew-letsencrypt.sh"]
PORT = 18080
BIND_HOST = "127.0.0.1"
# nginx (in its container) reaches the API only through this Unix socket; the directory is
# bind-mounted into the nginx container at /run/go-euc. Group 101 = nginx workers in the image.
SOCKET_PATH = "/opt/influx-grafana/run/api.sock"
NGINX_GID = 101


def _load_text(path):
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def _upsert_env_value(content, key, value):
    # config.env is sourced by root shell scripts: always shell-quote the value.
    escaped = re.escape(key)
    line = f"{key}={shlex.quote(value)}"
    pattern = re.compile(rf"(?m)^(?:export\s+)?{escaped}=.*$")
    if pattern.search(content):
        return pattern.sub(lambda _match: line, content)
    suffix = "" if content.endswith("\n") or content == "" else "\n"
    return f"{content}{suffix}{line}\n"


def _persist_letsencrypt_config(domain, email):
    content = _load_text(CONFIG_ENV_FILE)
    content = _upsert_env_value(content, "APPLIANCE_LETSENCRYPT_DOMAIN", domain)
    content = _upsert_env_value(content, "APPLIANCE_LETSENCRYPT_EMAIL", email)
    os.makedirs(os.path.dirname(CONFIG_ENV_FILE), exist_ok=True)
    fd = os.open(CONFIG_ENV_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(content)


def _is_valid_domain(value):
    if not value or len(value) > 253:
        return False
    if value.endswith("."):
        value = value[:-1]
    labels = value.split(".")
    if len(labels) < 2:
        return False
    label_pattern = re.compile(r"^[A-Za-z0-9-]{1,63}$")
    for label in labels:
        if not label_pattern.match(label):
            return False
        if label.startswith("-") or label.endswith("-"):
            return False
    return True


EMAIL_PATTERN = re.compile(r"^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,63}$")


def _is_valid_email(value):
    if not value or len(value) > 254:
        return False
    return EMAIL_PATTERN.fullmatch(value) is not None


HOSTNAME_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$")
COLLECTOR_CMD = "/usr/local/bin/go-euc-collector.sh"


def _parse_https_address(value, allowed_paths):
    """Parse 'host', 'host:port' or 'https://host[:port][/path]'. Returns (host, port) or None."""
    value = (value or "").strip()
    if not value or len(value) > 300:
        return None
    if "://" not in value:
        value = f"https://{value}"
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except ValueError:
        return None
    host = parsed.hostname or ""
    if parsed.scheme.lower() != "https" or not host:
        return None
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        return None
    try:
        ipaddress.IPv4Address(host)
    except ValueError:
        if not HOSTNAME_PATTERN.fullmatch(host):
            return None
    if parsed.path.rstrip("/") not in allowed_paths:
        return None
    return host, port


def _normalize_vcenter_url(value):
    """vCenter: 'vcenter.lab.local' or 'https://vcenter.lab.local[:port][/sdk]' -> https://host[:port]/sdk."""
    parsed = _parse_https_address(value, ("", "/sdk"))
    if not parsed:
        return None
    host, port = parsed
    netloc = host if port is None else f"{host}:{port}"
    return f"https://{netloc}/sdk"


def _normalize_prism_url(value):
    """Nutanix Prism Element (cluster address, not Prism Central): 'cluster.lab.local' or
    'https://cluster.lab.local[:9440][/api/nutanix/v2.0/hosts]'
    -> https://host:port (port defaults to 9440; the collector appends the API path)."""
    parsed = _parse_https_address(value, ("", "/api/nutanix/v2.0/hosts"))
    if not parsed:
        return None
    host, port = parsed
    return f"https://{host}:{port or 9440}"


def _normalize_proxmox_url(value):
    """Proxmox VE: 'pve.lab.local' or 'https://pve.lab.local[:8006][/api2/json]'
    -> https://host:port (port defaults to 8006; the collector appends /api2/json)."""
    parsed = _parse_https_address(value, ("", "/api2/json"))
    if not parsed:
        return None
    host, port = parsed
    return f"https://{host}:{port or 8006}"


# Proxmox API token ID (user@realm!tokenname) and secret (a UUID).
PROXMOX_TOKEN_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+![A-Za-z0-9._-]+$")
PROXMOX_TOKEN_SECRET_PATTERN = re.compile(r"^[A-Za-z0-9-]{8,128}$")

# Infrastructure collectors managed by go-euc-collector.sh (Telegraf containers telegraf-<type>).
COLLECTORS = {
    "vsphere": {
        "label": "vSphere",
        "normalize": _normalize_vcenter_url,
        "address_error": "Invalid vCenter address. Use a hostname, IP or https:// URL, e.g. vcenter.lab.local.",
    },
    "nutanix": {
        "label": "Nutanix Prism Element",
        "normalize": _normalize_prism_url,
        "address_error": "Invalid Prism Element address. Use the cluster's virtual IP or name (not Prism Central), e.g. ntnx-cluster.lab.local or 10.0.0.5:9440.",
    },
    "proxmox": {
        "label": "Proxmox VE",
        "normalize": _normalize_proxmox_url,
        "address_error": "Invalid Proxmox address. Use a hostname, IP or https:// URL, e.g. pve.lab.local or 10.0.0.6:8006.",
        "username_pattern": PROXMOX_TOKEN_ID_PATTERN,
        "username_error": "Use the API token ID in the form user@realm!tokenname, e.g. telegraf@pve!monitoring.",
        "password_pattern": PROXMOX_TOKEN_SECRET_PATTERN,
        "password_error": "The API token secret should look like a UUID, e.g. 8f2c1e2a-....",
    },
}


def _collector_settings_file(collector_type):
    return f"/etc/go-euc/collector-{collector_type}.env"


def _is_safe_text(value, max_length):
    if not value or len(value) > max_length:
        return False
    return all(32 <= ord(ch) != 127 for ch in value)


def _load_collector_settings(collector_type):
    settings = {}
    for line in _load_text(_collector_settings_file(collector_type)).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            parts = shlex.split(line)
        except ValueError:
            continue
        if len(parts) == 1 and "=" in parts[0]:
            key, value = parts[0].split("=", 1)
            settings[key] = value
    return settings


def _save_collector_settings(collector_type, settings):
    # Sourced by go-euc-collector.sh (root): shell-quote every value.
    path = _collector_settings_file(collector_type)
    content = "".join(f"{key}={shlex.quote(value)}\n" for key, value in settings.items())
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(path, 0o600)


def _docker_output(args, timeout=20):
    try:
        result = subprocess.run(["docker", *args], check=False, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def _collector_status(collector_type):
    settings = _load_collector_settings(collector_type)
    container = f"telegraf-{collector_type}"
    code, state = _docker_output(["inspect", "-f", "{{.State.Status}}", container])
    container_status = state.strip() if code == 0 else "not-created"
    logs = ""
    if code == 0:
        _code, logs = _docker_output(["logs", "--tail", "25", container])
    return {
        "type": collector_type,
        "label": COLLECTORS[collector_type]["label"],
        "configured": bool(settings.get("COLLECTOR_URL")),
        "enabled": settings.get("COLLECTOR_ENABLED") == "true",
        "address": settings.get("COLLECTOR_URL", ""),
        "username": settings.get("COLLECTOR_USERNAME", ""),
        "password_set": bool(settings.get("COLLECTOR_PASSWORD")),
        "verify_tls": settings.get("COLLECTOR_INSECURE_SKIP_VERIFY", "true") != "true",
        "container": container,
        "container_status": container_status,
        "logs": logs,
    }


def _read_env_file(path):
    values = {}
    for line in _load_text(path).splitlines():
        try:
            parts = shlex.split(line, comments=True)
        except ValueError:
            continue
        if len(parts) == 1 and "=" in parts[0]:
            key, value = parts[0].split("=", 1)
            values[key] = value
    return values


def _letsencrypt_active():
    try:
        with open(os.path.join(NGINX_CERT_DIR, "cert.pem"), "rb") as cert, \
                open(os.path.join(NGINX_CERT_DIR, "letsencrypt.crt"), "rb") as le_cert:
            return cert.read() == le_cert.read()
    except OSError:
        return False


def _proxmox_metric_server(request_host):
    """Settings for Proxmox VE's built-in Metric Server (InfluxDB, HTTPS) pushing to this appliance."""
    credentials = _read_env_file(CREDENTIALS_FILE)
    config = _read_env_file(CONFIG_ENV_FILE)
    le_active = _letsencrypt_active() and bool(config.get("APPLIANCE_LETSENCRYPT_DOMAIN"))
    server = config.get("APPLIANCE_LETSENCRYPT_DOMAIN") if le_active else (request_host or "").split(":")[0]
    return {
        "server": server,
        "port": 443,
        "protocol": "https",
        "api_path_prefix": "/influx",
        "organization": credentials.get("SAVED_INFLUX_ADMIN_ORG", ""),
        "bucket": PROXMOX_PUSH_BUCKET,
        "token": credentials.get("SAVED_PROXMOX_WRITE_TOKEN", ""),
        "verify_certificate": le_active,
    }


COLLECTOR_ROUTE = re.compile(r"^/api/collectors/([a-z]+)/(status|configure|disable)$")


def _match_collector_route(path):
    match = COLLECTOR_ROUTE.fullmatch(urllib.parse.urlsplit(path).path)
    if not match or match.group(1) not in COLLECTORS:
        return None
    return match.group(1), match.group(2)


class GoEucHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=PUBLIC_DIR, **kwargs)

    def _send_json(self, status, payload):
        body = json.dumps(payload, indent=2).encode("utf-8", "replace")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _run_json_command(self, cmd, timeout, ok_message, fail_message, extra=None):
        try:
            result = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            self._send_json(504, {"ok": False, "message": f"Timed out after {timeout} seconds."})
            return
        payload = {
            "ok": result.returncode == 0,
            "message": ok_message if result.returncode == 0 else fail_message,
            "output": (result.stdout or "") + (result.stderr or ""),
        }
        payload.update(extra or {})
        self._send_json(200 if result.returncode == 0 else 500, payload)

    def do_GET(self):
        route = _match_collector_route(self.path)
        if route and route[1] == "status":
            self._send_json(200, _collector_status(route[0]))
            return
        if urllib.parse.urlsplit(self.path).path == "/api/proxmox-metric-server":
            self._send_json(200, _proxmox_metric_server(self.headers.get("Host", "")))
            return
        if urllib.parse.urlsplit(self.path).path.startswith("/api/"):
            self.send_error(404, "Unknown API endpoint")
            return
        super().do_GET()

    def _handle_configure_collector(self, collector_type, raw_body):
        spec = COLLECTORS[collector_type]
        try:
            payload = json.loads(raw_body.decode("utf-8")) if raw_body else {}
        except Exception:
            self._send_json(400, {"ok": False, "message": "Invalid JSON payload."})
            return

        label = spec["label"]
        current = _load_collector_settings(collector_type)
        address = spec["normalize"](str(payload.get("address", "")))
        username = str(payload.get("username", "")).strip()
        password = str(payload.get("password", ""))
        verify_tls = bool(payload.get("verify_tls", False))

        if not address:
            self._send_json(400, {"ok": False, "message": spec["address_error"]})
            return
        if not _is_safe_text(username, 256):
            self._send_json(400, {"ok": False, "message": f"A {label} username is required (no control characters)."})
            return
        if spec.get("username_pattern") and not spec["username_pattern"].fullmatch(username):
            self._send_json(400, {"ok": False, "message": spec["username_error"]})
            return
        if not password:
            # Blank password keeps the saved one, so settings can be changed without retyping it.
            password = current.get("COLLECTOR_PASSWORD", "")
            if not password:
                self._send_json(400, {"ok": False, "message": f"A {label} password is required."})
                return
        if not _is_safe_text(password, 256):
            self._send_json(400, {"ok": False, "message": f"The {label} password contains unsupported control characters."})
            return
        if spec.get("password_pattern") and not spec["password_pattern"].fullmatch(password):
            self._send_json(400, {"ok": False, "message": spec["password_error"]})
            return

        _save_collector_settings(collector_type, {
            "COLLECTOR_URL": address,
            "COLLECTOR_USERNAME": username,
            "COLLECTOR_PASSWORD": password,
            "COLLECTOR_INSECURE_SKIP_VERIFY": "false" if verify_tls else "true",
            "COLLECTOR_ENABLED": "true",
        })
        self._run_json_command(
            [COLLECTOR_CMD, collector_type, "apply"],
            600,
            f"{label} collector started.",
            f"{label} collector settings saved, but the collector failed to start or reported errors.",
            {"address": address},
        )

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(content_length) if content_length > 0 else b""

        route = _match_collector_route(self.path)
        if route and route[1] == "configure":
            self._handle_configure_collector(route[0], raw_body)
            return
        if route and route[1] == "disable":
            label = COLLECTORS[route[0]]["label"]
            self._run_json_command(
                [COLLECTOR_CMD, route[0], "disable"],
                120,
                f"{label} collector stopped.",
                f"Failed to stop the {label} collector.",
            )
            return

        if self.path not in (
            "/api/refresh-telegraf",
            "/api/full-update",
            "/api/renew-letsencrypt",
            "/api/configure-letsencrypt",
        ):
            self.send_error(404, "Unknown API endpoint")
            return

        if self.path == "/api/configure-letsencrypt":
            try:
                payload = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except Exception:
                self.send_response(400)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    json.dumps(
                        {
                            "ok": False,
                            "message": "Invalid JSON payload.",
                        },
                        indent=2,
                    ).encode("utf-8")
                )
                return

            domain = str(payload.get("domain", "")).strip().lower()
            email = str(payload.get("email", "")).strip()
            if not _is_valid_domain(domain):
                self.send_response(400)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    json.dumps(
                        {
                            "ok": False,
                            "message": "Invalid domain. Use a public FQDN such as appliance.example.com.",
                        },
                        indent=2,
                    ).encode("utf-8")
                )
                return
            if not _is_valid_email(email):
                self.send_response(400)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.end_headers()
                self.wfile.write(
                    json.dumps(
                        {
                            "ok": False,
                            "message": "Invalid email address format.",
                        },
                        indent=2,
                    ).encode("utf-8")
                )
                return

            try:
                _persist_letsencrypt_config(domain, email)
                result = subprocess.run(
                    LE_RENEW_CMD,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=600,
                )
                output = (result.stdout or "") + (result.stderr or "")
                response_payload = {
                    "ok": result.returncode == 0,
                    "message": (
                        "Let's Encrypt details saved and certificate applied."
                        if result.returncode == 0
                        else "Let's Encrypt details saved, but certificate request/apply failed."
                    ),
                    "domain": domain,
                    "email": email,
                    "output": output,
                }
                status = 200 if result.returncode == 0 else 500
            except subprocess.TimeoutExpired:
                response_payload = {
                    "ok": False,
                    "message": "Let's Encrypt request timed out after 600 seconds.",
                    "domain": domain,
                    "email": email,
                }
                status = 504
            except Exception as exc:
                response_payload = {
                    "ok": False,
                    "message": f"Failed to save/apply Let's Encrypt config: {exc}",
                }
                status = 500

            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(json.dumps(response_payload, indent=2).encode("utf-8", "replace"))
            return

        try:
            if self.path == "/api/refresh-telegraf":
                cmd = REFRESH_CMD
                timeout = 300
            elif self.path == "/api/full-update":
                cmd = FULL_UPDATE_CMD
                timeout = 7200
            else:
                cmd = LE_RENEW_CMD
                timeout = 600

            result = subprocess.run(
                cmd,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            body = ""
            if self.path == "/api/renew-letsencrypt":
                output = (result.stdout or "") + (result.stderr or "")
                payload = {
                    "ok": result.returncode == 0,
                    "message": "Let's Encrypt certificate renewal completed." if result.returncode == 0 else "Let's Encrypt renewal failed.",
                    "output": output,
                }
                body = json.dumps(payload, indent=2)
                status = 200 if result.returncode == 0 else 500
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.end_headers()
                self.wfile.write(body.encode("utf-8", "replace"))
                return

            body = (result.stdout or "") + (result.stderr or "")
            body += "\nCurrent /telegraf files:\n"
            try:
                files = sorted(
                    p.name
                    for p in pathlib.Path(os.path.join(PUBLIC_DIR, "telegraf")).glob("*")
                    if p.is_file()
                )
                body += "\n".join(files) + ("\n" if files else "")
            except Exception as exc:
                body += f"<failed to list files: {exc}>\n"

            status = 200 if result.returncode == 0 else 500
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(body.encode("utf-8", "replace"))
        except subprocess.TimeoutExpired:
            self.send_response(504)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(f"Request timed out after {timeout} seconds.\n".encode("utf-8"))


class ReuseTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    # Threaded so a long-running full update does not block other requests.
    allow_reuse_address = True
    daemon_threads = True


class UnixHandler(GoEucHandler):
    # Unix-socket peers have no (host, port) address; the client IP comes from nginx instead.
    def address_string(self):
        return self.headers.get("X-Real-IP", "nginx") if hasattr(self, "headers") else "nginx"


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def get_request(self):
        request, _ = super().get_request()
        return request, ("unix", 0)


def main():
    import threading

    # Replace a stale socket from a previous run, keeping the directory (and so the
    # nginx container's bind mount of it) in place.
    os.makedirs(os.path.dirname(SOCKET_PATH), exist_ok=True)
    os.chmod(os.path.dirname(SOCKET_PATH), 0o755)
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)
    unix_server = ThreadingUnixServer(SOCKET_PATH, UnixHandler)
    os.chown(SOCKET_PATH, 0, NGINX_GID)
    os.chmod(SOCKET_PATH, 0o660)
    threading.Thread(target=unix_server.serve_forever, daemon=True).start()

    # Local access on the appliance itself (e.g. curl http://127.0.0.1:18080/config.txt).
    with ReuseTCPServer((BIND_HOST, PORT), GoEucHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
