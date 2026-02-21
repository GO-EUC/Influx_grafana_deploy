#!/usr/bin/env bash

set -euo pipefail

ROOT_SOURCE="$(findmnt -n -o SOURCE / || true)"
ROOT_FSTYPE="$(findmnt -n -o FSTYPE / || true)"

if [[ -z "${ROOT_SOURCE}" || "${ROOT_SOURCE}" != /dev/* ]]; then
  echo "[autogrow] Unsupported root source: ${ROOT_SOURCE:-<none>}"
  exit 0
fi

# LVM/dm layouts are intentionally skipped here to avoid unsafe assumptions.
if [[ "${ROOT_SOURCE}" == /dev/mapper/* || "${ROOT_SOURCE}" == /dev/dm-* ]]; then
  echo "[autogrow] Skipping device-mapper root: ${ROOT_SOURCE}"
  exit 0
fi

DISK_DEV=""
PART_NUM=""

if [[ "${ROOT_SOURCE}" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
  DISK_DEV="${BASH_REMATCH[1]}"
  PART_NUM="${BASH_REMATCH[2]}"
elif [[ "${ROOT_SOURCE}" =~ ^(/dev/mmcblk[0-9]+)p([0-9]+)$ ]]; then
  DISK_DEV="${BASH_REMATCH[1]}"
  PART_NUM="${BASH_REMATCH[2]}"
elif [[ "${ROOT_SOURCE}" =~ ^(/dev/[a-z]+)([0-9]+)$ ]]; then
  DISK_DEV="${BASH_REMATCH[1]}"
  PART_NUM="${BASH_REMATCH[2]}"
else
  echo "[autogrow] Unable to parse root partition: ${ROOT_SOURCE}"
  exit 0
fi

echo "[autogrow] Root source: ${ROOT_SOURCE}, disk: ${DISK_DEV}, partition: ${PART_NUM}"

GROWPART_OUTPUT="$(growpart "${DISK_DEV}" "${PART_NUM}" 2>&1 || true)"
if [[ "${GROWPART_OUTPUT}" == *"NOCHANGE"* ]]; then
  echo "[autogrow] Partition already at maximum size."
else
  echo "${GROWPART_OUTPUT}"
fi

partprobe "${DISK_DEV}" || true
udevadm settle || true

case "${ROOT_FSTYPE}" in
  ext2|ext3|ext4)
    resize2fs "${ROOT_SOURCE}"
    ;;
  xfs)
    xfs_growfs /
    ;;
  *)
    echo "[autogrow] Unsupported filesystem for automatic resize: ${ROOT_FSTYPE}"
    ;;
esac

echo "[autogrow] Completed."
