#!/usr/bin/env bash

set -euo pipefail

# Builds an OVA virtual appliance from Ubuntu cloud image and injects:
# - installer script + dashboards bundle
# - first-boot systemd unit to auto-run install on first boot

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${ROOT_DIR}/dist"
WORK_DIR="$(mktemp -d /tmp/go-euc-appliance-XXXXXX)"

UBUNTU_IMAGE_URL="${UBUNTU_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
GIT_SHA="${GITHUB_SHA:-local}"
BUILD_TS="$(date -u +%Y%m%d-%H%M%S)"
DISK_SIZE_GB="${DISK_SIZE_GB:-100}"
BUILD_ID="${BUILD_TS}-${GIT_SHA:0:8}"
APPLIANCE_BASENAME="go-euc-appliance-${BUILD_ID}"
QCOW2_PATH="${WORK_DIR}/${APPLIANCE_BASENAME}.qcow2"
VMDK_PATH="${WORK_DIR}/${APPLIANCE_BASENAME}.vmdk"
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
sudo virt-customize -a "${QCOW2_PATH}" \
  --run-command "mkdir -p /opt/go-euc-installer/scripts /etc/go-euc /usr/local/bin /var/lib/go-euc /etc/systemd/system" \
  --copy-in "${ROOT_DIR}/scripts/step1_install_base.sh:/opt/go-euc-installer/scripts" \
  --copy-in "${ROOT_DIR}/Dashboards.zip:/opt/go-euc-installer" \
  --copy-in "${ROOT_DIR}/appliance/firstboot/go-euc-firstboot.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/firstboot/go-euc-firstboot.service:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/firstboot/config.env.example:/etc/go-euc" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-autogrow.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-autogrow.service:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-upgrade.sh:/usr/local/bin" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-upgrade.service:/etc/systemd/system" \
  --copy-in "${ROOT_DIR}/appliance/maintenance/go-euc-upgrade.timer:/etc/systemd/system" \
  --install "cloud-guest-utils,open-vm-tools" \
  --run-command "chmod +x /usr/local/bin/go-euc-firstboot.sh /usr/local/bin/go-euc-autogrow.sh /usr/local/bin/go-euc-upgrade.sh /opt/go-euc-installer/scripts/step1_install_base.sh" \
  --run-command "ln -sf /etc/systemd/system/go-euc-firstboot.service /etc/systemd/system/multi-user.target.wants/go-euc-firstboot.service" \
  --run-command "ln -sf /etc/systemd/system/go-euc-autogrow.service /etc/systemd/system/multi-user.target.wants/go-euc-autogrow.service" \
  --run-command "cat >/etc/cloud/cloud.cfg.d/99-go-euc-growpart.cfg <<'EOF'
growpart:
  mode: auto
  devices: ['/']
  ignore_growroot_disabled: false
resize_rootfs: true
EOF" \
  --run-command "truncate -s 0 /etc/machine-id"

echo "Converting disk to VMDK for OVA..."
qemu-img convert -O vmdk -o adapter_type=lsilogic,subformat=streamOptimized "${QCOW2_PATH}" "${VMDK_PATH}"

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
  <VirtualSystem ovf:id="${APPLIANCE_BASENAME}" ovf:transport="com.vmware.guestInfo">
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
    <ProductSection ovf:class="go-euc">
      <Info>Deployment properties</Info>
      <Property ovf:key="appliance_name" ovf:type="string" ovf:userConfigurable="true" ovf:label="Appliance Name"/>
      <Property ovf:key="appliance_net_iface" ovf:type="string" ovf:userConfigurable="true" ovf:label="Network Interface (optional, e.g. ens160)"/>
      <Property ovf:key="appliance_static_ip_cidr" ovf:type="string" ovf:userConfigurable="true" ovf:label="IP Settings (CIDR, e.g. 192.168.1.50/24)"/>
      <Property ovf:key="appliance_gateway" ovf:type="string" ovf:userConfigurable="true" ovf:label="Gateway"/>
      <Property ovf:key="appliance_dns" ovf:type="string" ovf:userConfigurable="true" ovf:label="DNS (comma separated)"/>
    </ProductSection>
  </VirtualSystem>
</Envelope>
EOF

echo "Packaging OVA..."
(
  cd "${WORK_DIR}"
  tar -cf "${OVA_PATH}" "$(basename "${OVF_PATH}")" "$(basename "${VMDK_PATH}")"
)

echo "Generating checksum..."
sha256sum "${OVA_PATH}" | tee "${OVA_PATH}.sha256"

echo
echo "Build complete:"
echo "- ${OVA_PATH}"
echo "- ${OVA_PATH}.sha256"
