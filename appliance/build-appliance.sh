#!/usr/bin/env bash

set -euo pipefail

# Builds an OVA virtual appliance from Ubuntu cloud image and injects:
# - installer script + dashboards bundle
# - first-boot systemd unit to auto-run install on first boot

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/dist"
WORK_DIR="$(mktemp -d /tmp/go-euc-appliance-XXXXXX)"
VIRT_CUSTOMIZE_LOG="${OUTPUT_DIR}/virt-customize.log"

UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
GIT_SHA="${GITHUB_SHA:-local}"
BUILD_TS="$(date -u +%Y%m%d-%H%M%S)"
DISK_SIZE_GB="${DISK_SIZE_GB:-100}"
VHD_SUBFORMAT="${VHD_SUBFORMAT:-dynamic}"
BREAK_GLASS_USER="${BREAK_GLASS_USER:-recovery}"
BREAK_GLASS_PASSWORD="${BREAK_GLASS_PASSWORD:-Recover-ChangeMe-Now!}"
BUILD_ID="${BUILD_TS}-${GIT_SHA:0:8}"
APPLIANCE_BASENAME="go-euc-appliance-${BUILD_ID}"
QCOW2_PATH="${WORK_DIR}/${APPLIANCE_BASENAME}.qcow2"
VMDK_PATH="${WORK_DIR}/${APPLIANCE_BASENAME}.vmdk"
VHD_PATH="${OUTPUT_DIR}/${APPLIANCE_BASENAME}.vhd"
OVF_PATH="${WORK_DIR}/${APPLIANCE_BASENAME}.ovf"
OVA_PATH="${OUTPUT_DIR}/${APPLIANCE_BASENAME}.ova"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${OUTPUT_DIR}"

echo "Downloading base image..."
curl -fsSL "${UBUNTU_IMAGE_URL}" -o "${WORK_DIR}/base.img"

echo "Preparing appliance disk (${DISK_SIZE_GB}GB)..."
cp "${WORK_DIR}/base.img" "${QCOW2_PATH}"
qemu-img resize "${QCOW2_PATH}" "${DISK_SIZE_GB}G"

echo "Injecting installer and first-boot files..."
VIRT_CUSTOMIZE_ARGS=()
if [[ "${VIRT_CUSTOMIZE_DEBUG:-false}" == "true" ]]; then
  VIRT_CUSTOMIZE_ARGS+=("-v" "-x")
  echo "virt-customize debug enabled."
fi
if [[ "${VIRT_CUSTOMIZE_NO_NETWORK:-true}" == "true" ]]; then
  VIRT_CUSTOMIZE_ARGS+=("--no-network")
fi

mkdir -p "${OUTPUT_DIR}"

set -o pipefail
VIRT_CUSTOMIZE_CMD="virt-customize"
if [[ "${EUID}" -eq 0 ]]; then
  VIRT_CUSTOMIZE_CMD="virt-customize"
elif command -v sudo >/dev/null 2>&1 && [[ "${USE_SUDO_FOR_VIRT_CUSTOMIZE:-false}" == "true" ]]; then
  VIRT_CUSTOMIZE_CMD="sudo virt-customize"
fi

${VIRT_CUSTOMIZE_CMD} "${VIRT_CUSTOMIZE_ARGS[@]}" -a "${QCOW2_PATH}" \
  --run-command "mkdir -p /opt/go-euc-installer/scripts /etc/go-euc /usr/local/bin /var/lib/go-euc /etc/systemd/system /etc/profile.d" \
  --run-command "id -u ${BREAK_GLASS_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${BREAK_GLASS_USER}" \
  --run-command "echo '${BREAK_GLASS_USER}:${BREAK_GLASS_PASSWORD}' | chpasswd" \
  --run-command "usermod -aG sudo ${BREAK_GLASS_USER}" \
  --run-command "chage -d -1 ${BREAK_GLASS_USER}" \
  --run-command "cat >/etc/go-euc/break-glass.env <<'EOF'
BREAK_GLASS_USER=${BREAK_GLASS_USER}
BREAK_GLASS_PASSWORD=${BREAK_GLASS_PASSWORD}
EOF" \
  --run-command "chmod 600 /etc/go-euc/break-glass.env" \
  --run-command "cat >/etc/issue <<'EOF'
GO-EUC APPLIANCE - INITIALIZING

If setup is pending, log in on console and complete the first login wizard.
If setup is still running or failed, log in with break-glass account:
  username: ${BREAK_GLASS_USER}
  password: ${BREAK_GLASS_PASSWORD}

First-boot status:
  sudo systemctl status go-euc-firstboot.service
  sudo journalctl -u go-euc-firstboot.service -n 200 --no-pager
EOF" \
  --copy-in "${ROOT_DIR}/scripts/step1_install_base.sh:/opt/go-euc-installer/scripts" \
  --copy-in "${ROOT_DIR}/Dashboards.zip:/opt/go-euc-installer" \
  --copy-in "${ROOT_DIR}/Telegraf:/opt/go-euc-installer" \
  --copy-in "${ROOT_DIR}/appliance/firstboot/go-euc-firstboot.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/firstboot/go-euc-firstboot.service:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/firstboot/go-euc-console-wizard.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/firstboot/go-euc-login-hook.sh:/etc/profile.d" \
  --copy-in "${ROOT_DIR}/appliance/firstboot/config.env.example:/etc/go-euc" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-autogrow.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-autogrow.service:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-upgrade.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-appliance-update.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-upgrade.service:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-upgrade.timer:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-webfiles.service:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-webfiles.py:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-ensure-ssh.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-ensure-ssh.service:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-postsetup-cleanup.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-postsetup-cleanup.service:/etc/systemd/system" \
  --run-command "chmod +x /usr/local/bin/go-euc-firstboot.sh /usr/local/bin/go-euc-console-wizard.sh /usr/local/bin/go-euc-autogrow.sh /usr/local/bin/go-euc-upgrade.sh /usr/local/bin/go-euc-appliance-update.sh /usr/local/bin/go-euc-webfiles.py /usr/local/bin/go-euc-ensure-ssh.sh /usr/local/bin/go-euc-postsetup-cleanup.sh /opt/go-euc-installer/scripts/step1_install_base.sh /etc/profile.d/go-euc-login-hook.sh" \
  --run-command "ln -sf /etc/systemd/system/go-euc-firstboot.service /etc/systemd/system/multi-user.target.wants/go-euc-firstboot.service" \
  --run-command "ln -sf /etc/systemd/system/go-euc-autogrow.service /etc/systemd/system/multi-user.target.wants/go-euc-autogrow.service" \
  --run-command "ln -sf /etc/systemd/system/go-euc-ensure-ssh.service /etc/systemd/system/multi-user.target.wants/go-euc-ensure-ssh.service" \
  --run-command "ln -sf /etc/systemd/system/go-euc-postsetup-cleanup.service /etc/systemd/system/multi-user.target.wants/go-euc-postsetup-cleanup.service" \
  --run-command "cat >/etc/cloud/cloud.cfg.d/99-go-euc-growpart.cfg <<'EOF'
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true
EOF" \
  --run-command "truncate -s 0 /etc/machine-id" 2>&1 | tee "${VIRT_CUSTOMIZE_LOG}"

echo "Converting disk to VMDK for OVA..."
qemu-img convert -O vmdk -o adapter_type=lsilogic,subformat=streamOptimized "${QCOW2_PATH}" "${VMDK_PATH}"

echo "Converting disk to VHD for Hyper-V..."
case "${VHD_SUBFORMAT}" in
  dynamic|fixed)
    ;;
  *)
    echo "Unsupported VHD_SUBFORMAT='${VHD_SUBFORMAT}'. Use 'dynamic' or 'fixed'." >&2
    exit 1
    ;;
esac
qemu-img convert -O vpc -o "subformat=${VHD_SUBFORMAT}" "${QCOW2_PATH}" "${VHD_PATH}"

echo "Creating OVF descriptor..."
VMDK_SIZE_BYTES="$(wc -c < "${VMDK_PATH}" | tr -d ' ')"
cat > "${OVF_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf">
  <References>
    <File ovf:id="file1" ovf:href="${APPLIANCE_BASENAME}.vmdk" ovf:size="${VMDK_SIZE_BYTES}"/>
  </References>
  <DiskSection>
    <Info>Virtual disk info</Info>
    <Disk ovf:diskId="vmdisk1" ovf:fileRef="file1" ovf:capacity="${DISK_SIZE_GB}" ovf:capacityAllocationUnits="byte * 2^30" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"/>
  </DiskSection>
  <NetworkSection>
    <Info>Network info</Info>
    <Network ovf:name="VM Network">
      <Description>VM Network</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="${APPLIANCE_BASENAME}">
    <Info>GO-EUC appliance</Info>
    <Name>${APPLIANCE_BASENAME}</Name>
    <OperatingSystemSection ovf:id="94">
      <Info>Ubuntu Linux (64-bit)</Info>
      <Description>Ubuntu Linux (64-bit)</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>${APPLIANCE_BASENAME}</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-14</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>2 virtual CPU(s)</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>2</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>4096MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>4096</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>Hard disk</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:Parent>4</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:Description>SCSI Controller</rasd:Description>
        <rasd:ElementName>SCSI Controller 0</rasd:ElementName>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:ResourceSubType>lsilogic</rasd:ResourceSubType>
        <rasd:ResourceType>6</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>7</rasd:AddressOnParent>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>VM Network</rasd:Connection>
        <rasd:Description>E1000 Ethernet adapter</rasd:Description>
        <rasd:ElementName>Ethernet 1</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>E1000</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

echo "Packaging OVA..."
(
  cd "${WORK_DIR}"
  tar -cf "${OVA_PATH}" "$(basename "${OVF_PATH}")" "$(basename "${VMDK_PATH}")"
)

echo "Generating checksums..."
sha256sum "${OVA_PATH}" | tee "${OVA_PATH}.sha256"
sha256sum "${VHD_PATH}" | tee "${VHD_PATH}.sha256"

echo
echo "Build complete:"
echo "- ${OVA_PATH}"
echo "- ${OVA_PATH}.sha256"
echo "- ${VHD_PATH}"
echo "- ${VHD_PATH}.sha256"
