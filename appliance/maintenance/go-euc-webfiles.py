#!/usr/bin/env python3

import http.server
import os
import pathlib
import socketserver
import subprocess

PUBLIC_DIR = "/opt/influx-grafana/public"
REFRESH_CMD = ["/usr/local/bin/go-euc-refresh-telegraf.sh"]
FULL_UPDATE_CMD = ["/usr/local/bin/go-euc-appliance-update.sh"]
PORT = 80


class GoEucHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=PUBLIC_DIR, **kwargs)

    def do_POST(self):
        if self.path not in ("/api/refresh-telegraf", "/api/full-update"):
            self.send_error(404, "Unknown API endpoint")
            return

        # Consume request body if present.
        content_length = int(self.headers.get("Content-Length", "0"))
        if content_length > 0:
            _ = self.rfile.read(content_length)

        try:
            cmd = REFRESH_CMD if self.path == "/api/refresh-telegraf" else FULL_UPDATE_CMD
            timeout = 300 if self.path == "/api/refresh-telegraf" else 7200
            result = subprocess.run(
                cmd,
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
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
    with ReuseTCPServer(("", PORT), GoEucHandler) as httpd:
        httpd.serve_forever()


if __name__ == "__main__":
    main()
