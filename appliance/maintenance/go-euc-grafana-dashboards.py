#!/usr/bin/env python3
"""Normalise the GO-EUC dashboard bundle for Grafana file provisioning.

Grafana file provisioning accepts classic dashboard JSON and complete v2 resources
({"apiVersion": "dashboard.grafana.app/v2", "kind": "Dashboard", "metadata": {...}, "spec": {...}}).
It rejects a *bare* v2 spec (top-level "elements"/"layout" with no apiVersion), which is what
some Grafana exports produce ("dashboard appears to be in v2 format").

This script wraps every bare v2 spec under <dashboards-dir> into a complete v2 resource, in
place, so all dashboards stay file-provisioned. The resource name (the dashboard uid) is taken
from the spec's uid if present, otherwise derived from the file name, so it is stable across
re-runs. Classic dashboards and complete v2 resources are left untouched.

usage: go-euc-grafana-dashboards.py <dashboards-dir>
Safe to re-run. Run it after extracting the bundle and before (re)starting Grafana.
"""
import json
import os
import re
import sys


def is_bare_v2(doc):
    return (isinstance(doc, dict) and "apiVersion" not in doc
            and "elements" in doc and "layout" in doc and "panels" not in doc)


def resource_name(path, spec):
    uid = str(spec.get("uid") or "").strip()
    if re.fullmatch(r"[A-Za-z0-9._-]{1,40}", uid):
        return uid
    stem = os.path.splitext(os.path.basename(path))[0].lower()
    return ("goeuc-" + re.sub(r"[^a-z0-9]+", "-", stem).strip("-"))[:40].rstrip("-")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    wrapped = 0
    for root, _dirs, files in os.walk(sys.argv[1]):
        for name in sorted(files):
            if not name.endswith(".json"):
                continue
            path = os.path.join(root, name)
            try:
                with open(path, encoding="utf-8") as fh:
                    doc = json.load(fh)
            except (OSError, ValueError) as exc:
                print(f"[dashboards] WARN: skipping unreadable {name}: {exc}", file=sys.stderr)
                continue
            if not is_bare_v2(doc):
                continue
            resource = {
                "apiVersion": "dashboard.grafana.app/v2",
                "kind": "Dashboard",
                "metadata": {"name": resource_name(path, doc)},
                "spec": doc,
            }
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(resource, fh, indent=2)
            os.replace(tmp, path)
            wrapped += 1
            print(f"[dashboards] wrapped bare v2 spec {name} as dashboard.grafana.app/v2 '{resource['metadata']['name']}'")
    print(f"[dashboards] {wrapped} bare v2 dashboard(s) normalised")
    return 0


if __name__ == "__main__":
    sys.exit(main())
