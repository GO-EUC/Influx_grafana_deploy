"""Small Prism Element v2.0 helper for the GO-EUC appliance tests (see testing/README.md).

usage:
  python3 prism.py list                 cluster, AHV networks, storage containers, test VMs/images
  python3 prism.py vm <vm-name>         power state and NICs of a VM
  python3 prism.py teardown <vm-name>   power off and delete the VM and its "<vm-name>-image" image

Reads $GOEUC_TEST_DIR/nutanix.env (default ~/.goeuc-test). Never prints secrets.
"""
import base64
import json
import os
import shlex
import ssl
import sys
import time
import urllib.error
import urllib.request

STATE_DIR = os.path.expanduser(os.environ.get("GOEUC_TEST_DIR", "~/.goeuc-test"))


def load_env(path):
    values = {}
    for line in open(path, encoding="utf-8"):
        parts = shlex.split(line, comments=True)
        if parts and "=" in parts[0]:
            key, value = parts[0].split("=", 1)
            values[key] = value
    return values


ENV = load_env(os.path.join(STATE_DIR, "nutanix.env"))
BASE = f"https://{ENV['PRISM_HOST']}:9440/PrismGateway/services/rest/v2.0"
AUTH = "Basic " + base64.b64encode(f"{ENV['PRISM_USER']}:{ENV['PRISM_PASSWORD']}".encode()).decode()
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Authorization": AUTH, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        sys.exit(f"API {method} {path} -> HTTP {exc.code}: {exc.read()[:300]!r}")


def wait_task(task_uuid, what):
    for _ in range(360):
        task = api("GET", f"/tasks/{task_uuid}")
        if task.get("progress_status") == "Succeeded":
            print(f"  {what}: Succeeded")
            return task
        if task.get("progress_status") in ("Failed", "Aborted"):
            sys.exit(f"{what} failed: {task.get('meta_response', {}).get('error_detail')}")
        time.sleep(5)
    sys.exit(f"{what}: timed out")


def by_name(path, name):
    return [e for e in api("GET", path).get("entities", []) if e.get("name") == name]


def cmd_list():
    c = api("GET", "/cluster")
    print(f"cluster {c.get('name')} | AOS {c.get('version')} | nodes {c.get('num_nodes')} | VIP {c.get('cluster_external_ipaddress')}")
    print("networks:")
    for n in api("GET", "/networks").get("entities", []):
        print(f"  {n.get('name')!r} vlan={n.get('vlan_id')}")
    print("storage containers:")
    for s in api("GET", "/storage_containers").get("entities", []):
        print(f"  {s.get('name')!r}")
    print("GO-EUC test VMs / images:")
    for v in api("GET", "/vms").get("entities", []):
        if v.get("name", "").startswith("goeuc-appliance-test"):
            print(f"  vm    {v['name']} {v.get('power_state')} {v.get('uuid')}")
    for i in api("GET", "/images").get("entities", []):
        if i.get("name", "").startswith("goeuc-appliance-test"):
            print(f"  image {i['name']} {i.get('image_state')} {i.get('uuid')}")


def cmd_vm(name):
    for v in by_name("/vms", name):
        full = api("GET", f"/vms/{v['uuid']}?include_vm_nic_config=true")
        nics = [(n.get("mac_address"), n.get("requested_ip_address") or n.get("ip_address")) for n in full.get("vm_nics", [])]
        print(f"{name}: power_state={full.get('power_state')} vcpus={full.get('num_vcpus')} memory_mb={full.get('memory_mb')} nics={nics}")


def cmd_teardown(name):
    for v in by_name("/vms", name):
        if v.get("power_state") == "on":
            wait_task(api("POST", f"/vms/{v['uuid']}/set_power_state", {"transition": "OFF"})["task_uuid"], f"power off {name}")
        wait_task(api("DELETE", f"/vms/{v['uuid']}")["task_uuid"], f"delete VM {name}")
    for i in by_name("/images", f"{name}-image"):
        wait_task(api("DELETE", f"/images/{i['uuid']}")["task_uuid"], f"delete image {name}-image")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("list", "vm", "teardown"):
        sys.exit(__doc__)
    if sys.argv[1] == "list":
        cmd_list()
    elif len(sys.argv) < 3:
        sys.exit(__doc__)
    elif sys.argv[1] == "vm":
        cmd_vm(sys.argv[2])
    else:
        cmd_teardown(sys.argv[2])
