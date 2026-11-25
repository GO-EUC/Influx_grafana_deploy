"""Deploy a GO-EUC appliance test VM on Nutanix AHV via the Prism Element v2.0 API.

Unattended setup: cloud-init (AHV config drive) writes /etc/go-euc/config.env and the
console-wizard marker exactly as the console wizard would, and creates goeucadmin with a
throwaway SSH key + NOPASSWD sudo. See testing/README.md.

Inputs (never printed):
  $GOEUC_TEST_DIR/nutanix.env        Prism + network settings (see testing/nutanix.env.example)
  $GOEUC_TEST_DIR/id_goeuc_test(.pub) SSH key for goeucadmin  (generated if missing)
  $GOEUC_TEST_DIR/goeucadmin.password appliance login password (generated if missing)
GOEUC_TEST_DIR defaults to ~/.goeuc-test.

Optional (test scenarios):
  GOEUC_DEPLOY_DNS            override APPLIANCE_DNS (e.g. an unreachable resolver to test the
                              first-boot internet check)
  GOEUC_DEPLOY_EXTRA_CONFIG   extra lines appended to config.env (e.g. INFLUX_ADMIN_ORG=GO)

usage: python3 deploy.py <vhd-url> <vm-name> <ahv-network-name> [vcpus] [memory_mb]
"""
import base64
import json
import os
import secrets
import shlex
import ssl
import string
import subprocess
import sys
import time
import urllib.error
import urllib.request

if len(sys.argv) < 4:
    sys.exit(__doc__)
VHD_URL, VM_NAME, NETWORK_NAME = sys.argv[1:4]
VCPUS = int(sys.argv[4]) if len(sys.argv) > 4 else 4
MEMORY_MB = int(sys.argv[5]) if len(sys.argv) > 5 else 8192
STATE_DIR = os.path.expanduser(os.environ.get("GOEUC_TEST_DIR", "~/.goeuc-test"))
KEY_PATH = os.path.join(STATE_DIR, "id_goeuc_test")
PASSWORD_PATH = os.path.join(STATE_DIR, "goeucadmin.password")


def load_env(path):
    values = {}
    for line in open(os.path.expanduser(path), encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = shlex.split(line, comments=True)
        if parts and "=" in parts[0]:
            key, value = parts[0].split("=", 1)
            values[key] = value
    return values


ENV = load_env(os.path.join(STATE_DIR, "nutanix.env"))

# Throwaway SSH key and appliance password for the test VM.
if not os.path.exists(KEY_PATH):
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "goeuc-appliance-test", "-f", KEY_PATH], check=True)
if not os.path.exists(PASSWORD_PATH):
    alphabet = string.ascii_letters + string.digits
    fd = os.open(PASSWORD_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("".join(secrets.choice(alphabet) for _ in range(20)) + "\n")
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
        sys.exit(f"API {method} {path} -> HTTP {exc.code}: {exc.read()[:500]!r}")


def wait_task(task_uuid, what, timeout=3600):
    start = time.time()
    last = None
    while time.time() - start < timeout:
        task = api("GET", f"/tasks/{task_uuid}")
        status, pct = task.get("progress_status"), task.get("percentage_complete")
        if (status, pct) != last:
            print(f"  [{int(time.time() - start):4d}s] {what}: {status} {pct}%", flush=True)
            last = (status, pct)
        if status == "Succeeded":
            return task
        if status in ("Failed", "Aborted"):
            sys.exit(f"{what} failed: {task.get('meta_response', {}).get('error_detail') or task}")
        time.sleep(10)
    sys.exit(f"{what}: timed out")


def find(entities, name):
    return [e for e in entities if e.get("name") == name]


# --- network / container -------------------------------------------------------
networks = find(api("GET", "/networks")["entities"], NETWORK_NAME)
if len(networks) != 1:
    sys.exit(f"network {NETWORK_NAME!r}: found {len(networks)}")
network_uuid = networks[0]["uuid"]
containers = [c for c in api("GET", "/storage_containers")["entities"] if c["name"] == ENV["NTNX_CONTAINER"]]
if len(containers) != 1:
    sys.exit(f"container {ENV['NTNX_CONTAINER']!r}: found {len(containers)}")
container_uuid = containers[0]["storage_container_uuid"]

# --- image -------------------------------------------------------------------------
image_name = VM_NAME + "-image"
images = find(api("GET", "/images")["entities"], image_name)
if not images:
    print(f"Importing image {image_name} from {VHD_URL}")
    task = api("POST", "/images", {
        "name": image_name,
        "annotation": "GO-EUC appliance test image (VHD from CI)",
        "image_type": "DISK_IMAGE",
        "image_import_spec": {"storage_container_uuid": container_uuid, "url": VHD_URL},
    })
    wait_task(task["task_uuid"], "image import")
    images = find(api("GET", "/images")["entities"], image_name)
image = images[0]
if image.get("image_state") not in (None, "ACTIVE"):
    sys.exit(f"image state {image.get('image_state')}")
vm_disk_id = image["vm_disk_id"]
print(f"Image ready: {image_name} (vm_disk_id {vm_disk_id}, size {int(image.get('vm_disk_size', 0)) // 2**30} GiB)")

# --- cloud-init user-data ------------------------------------------------------
pubkey = open(KEY_PATH + ".pub", encoding="utf-8").read().strip()
password = open(PASSWORD_PATH, encoding="utf-8").read().strip()
hostname = VM_NAME[:63]
config_env = "\n".join([
    "# Written by cloud-init (unattended test deployment) in place of the console wizard.",
    f"APPLIANCE_NAME={shlex.quote(hostname)}",
    f"APPLIANCE_STATIC_IP_CIDR={shlex.quote(ENV['APPLIANCE_IP_CIDR'])}",
    f"APPLIANCE_GATEWAY={shlex.quote(ENV['APPLIANCE_GATEWAY'])}",
    f"APPLIANCE_DNS={shlex.quote(os.environ.get('GOEUC_DEPLOY_DNS') or ENV['APPLIANCE_DNS'])}",
    f"APPLIANCE_LOGIN_PASSWORD={shlex.quote(password)}",
] + [line for line in os.environ.get("GOEUC_DEPLOY_EXTRA_CONFIG", "").splitlines() if line.strip()] + [""])
userdata = "#cloud-config\n" + json.dumps({
    "users": [{
        "name": "goeucadmin",
        "shell": "/bin/bash",
        "groups": ["sudo"],
        "sudo": "ALL=(ALL) NOPASSWD:ALL",
        "lock_passwd": False,
        "ssh_authorized_keys": [pubkey],
    }],
    "write_files": [
        {"path": "/etc/go-euc/config.env", "permissions": "0600", "content": config_env},
        {"path": "/var/lib/go-euc/console-config.done", "permissions": "0600",
         "content": "unattended test deployment via cloud-init\n"},
    ],
}, indent=1)

# --- VM ----------------------------------------------------------------------------
if find(api("GET", "/vms")["entities"], VM_NAME):
    sys.exit(f"VM {VM_NAME} already exists")
print(f"Creating VM {VM_NAME} ({VCPUS} vCPU, {MEMORY_MB} MiB, network {NETWORK_NAME})")
task = api("POST", "/vms", {
    "name": VM_NAME,
    "description": "GO-EUC appliance automated test deployment",
    "num_vcpus": VCPUS,
    "num_cores_per_vcpu": 1,
    "memory_mb": MEMORY_MB,
    "boot": {"uefi_boot": False},
    "vm_disks": [{
        "is_cdrom": False,
        "disk_address": {"device_bus": "SCSI", "device_index": 0},
        "vm_disk_clone": {"disk_address": {"vmdisk_uuid": vm_disk_id}},
    }],
    "vm_nics": [{"network_uuid": network_uuid, "is_connected": True}],
    "vm_customization_config": {"userdata": userdata, "datasource_type": "CONFIG_DRIVE_V2"},
})
done = wait_task(task["task_uuid"], "VM create")
vm_uuid = next(e["entity_id"] for e in done.get("entity_list", []) if e.get("entity_type", "").lower() == "vm")
print(f"VM created: {vm_uuid}")

task = api("POST", f"/vms/{vm_uuid}/set_power_state", {"transition": "ON"})
wait_task(task["task_uuid"], "power on")
vm = api("GET", f"/vms/{vm_uuid}?include_vm_nic_config=true")
print(f"VM {VM_NAME} power_state={vm.get('power_state')} mac={[n.get('mac_address') for n in vm.get('vm_nics', [])]}")
print(json.dumps({"vm_uuid": vm_uuid, "image_uuid": image.get("uuid"), "vm_name": VM_NAME}))
