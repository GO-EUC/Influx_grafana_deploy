#!/usr/bin/env python3

import http.server
import json
import os
import pathlib
import re
import socketserver
import subprocess

PUBLIC_DIR = "/opt/influx-grafana/public"
CONFIG_ENV_FILE = "/etc/go-euc/config.env"
REFRESH_CMD = ["/usr/local/bin/go-euc-refresh-telegraf.sh"]
FULL_UPDATE_CMD = ["/usr/local/bin/go-euc-appliance-update.sh"]
LE_RENEW_CMD = ["/usr/local/bin/go-euc-renew-letsencrypt.sh"]
PORT = 18080
BIND_HOST = "127.0.0.1"


def _load_text(path):
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def _upsert_env_value(content, key, value):
    escaped = re.escape(key)
    line = f"{key}={value}"
    pattern = re.compile(rf"(?m)^(?:export\s+)?{escaped}=.*$")
    if pattern.search(content):
        return pattern.sub(line, content)
    suffix = "" if content.endswith("\n") or content == "" else "\n"
    return f"{content}{suffix}{line}\n"


def _persist_letsencrypt_config(domain, email):
    content = _load_text(CONFIG_ENV_FILE)
    content = _upsert_env_value(content, "APPLIANCE_LETSENCRYPT_DOMAIN", domain)
    content = _upsert_env_value(content, "APPLIANCE_LETSENCRYPT_EMAIL", email)
    os.makedirs(os.path.dirname(CONFIG_ENV_FILE), exist_ok=True)
    with open(CONFIG_ENV_FILE, "w", encoding="utf-8") as fh:
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


def _is_valid_email(value):
    if not value or len(value) > 320:
        return False
    return re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", value) is not None


class GoEucHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=PUBLIC_DIR, **kwargs)

    def do_POST(self):
        if self.path not in (
            "/api/refresh-telegraf",
            "/api/full-update",
            "/api/renew-letsencrypt",
            "/api/configure-letsencrypt",
        ):
            self.send_error(404, "Unknown API endpoint")
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        raw_body = b""
        if content_length > 0:
            raw_body = self.rfile.read(content_length)

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


class ReuseTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


def main():
    with ReuseTCPServer((BIND_HOST, PORT), GoEucHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
