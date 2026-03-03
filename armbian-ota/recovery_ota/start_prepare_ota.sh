#!/bin/bash
#
# start_praper_ota.sh
#
# Install 99-copy-tools and 99-ota-apply into initramfs hooks,
# automatically detect the kernel version from /boot/initrd.img-*,
# and rebuild the initrd for that kernel version.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_HOOK="${SCRIPT_DIR}/99-copy-tools"
SRC_OTA="${SCRIPT_DIR}/99-ota-apply"

DEST_HOOK_DIR="/etc/initramfs-tools/hooks"
DEST_OTA_DIR="/etc/initramfs-tools/scripts/init-premount"
DEST_HOOK="${DEST_HOOK_DIR}/99-copy-tools"
DEST_OTA="${DEST_OTA_DIR}/99-ota-apply"


echo "[start_praper_ota] Preparing Armbian OTA initramfs hooks..."

# Require root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "ERROR: This script must be run as root:"
    echo "  sudo $0"
    exit 1
fi

# Validate source files
if [ ! -f "${SRC_HOOK}" ]; then
    echo "ERROR: File not found: ${SRC_HOOK}"
    exit 1
fi

if [ ! -f "${SRC_OTA}" ]; then
    echo "ERROR: File not found: ${SRC_OTA}"
    exit 1
fi

# ===== helper: verify payload sha256 against provided .sha256 file (generated at build time) =====
verify_sha256() {
    local payload="$1"       # absolute or relative path to payload
    local sha_file="$2"      # absolute or relative path to checksum file
    local label="$3"         # log label

    if [ ! -f "${payload}" ]; then
        echo "ERROR: Missing ${label} payload: ${payload}" >&2
        return 1
    fi

    if [ ! -f "${sha_file}" ]; then
        echo "ERROR: Missing ${label} checksum file: ${sha_file}" >&2
        return 1
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        echo "ERROR: sha256sum not found; cannot verify ${label}" >&2
        return 1
    fi

    # Run verification in the payload directory so that the checksum file can contain a basename.
    local payload_dir
    payload_dir="$(cd "$(dirname "${payload}")" && pwd)"
    local payload_base
    payload_base="$(basename "${payload}")"
    local sha_dir
    sha_dir="$(cd "$(dirname "${sha_file}")" && pwd)"
    local sha_base
    sha_base="$(basename "${sha_file}")"

    # Ensure checksum file references the intended payload name.
    # If it does not, create a temporary checksum file with corrected filename.
    local tmp_sha=""
    if ! grep -qE "[[:space:]]${payload_base}$" "${sha_dir}/${sha_base}"; then
        tmp_sha="$(mktemp)"
        # keep hash, replace filename with payload_base
        awk -v f="${payload_base}" '{print $1"  "f}' "${sha_dir}/${sha_base}" > "${tmp_sha}" || return 1
    fi

    echo "[start_praper_ota] Verifying ${label} SHA256..."
    if [ -n "${tmp_sha}" ]; then
        (cd "${payload_dir}" && sha256sum -c "${tmp_sha}" >/dev/null) || {
            echo "ERROR: ${label} SHA256 verification failed (payload=${payload_base})" >&2
            rm -f "${tmp_sha}"
            return 1
        }
        rm -f "${tmp_sha}"
    else
        (cd "${payload_dir}" && sha256sum -c "${sha_dir}/${sha_base}" >/dev/null) || {
            echo "ERROR: ${label} SHA256 verification failed (payload=${payload_base})" >&2
            return 1
        }
    fi

    echo "[start_praper_ota] ${label} SHA256 OK"
    return 0
}

# ===== Detect kernel version based on /boot/initrd.img-* =====
detect_kver() {
    local files
    files=(/boot/initrd.img-*)

    # No match at all
    if [ ! -e "${files[0]}" ]; then
        echo "ERROR: No initrd.img-* found under /boot. Cannot determine kernel version." >&2
        return 1
    fi

    # Filter to existing files
    local real_files=()
    for f in "${files[@]}"; do
        [ -e "$f" ] && real_files+=("$f")
    done

    if [ "${#real_files[@]}" -eq 0 ]; then
        echo "ERROR: No valid initrd.img-* files found under /boot." >&2
        return 1
    fi

    # Only one file → extract version directly
    if [ "${#real_files[@]}" -eq 1 ]; then
        local base
        base="$(basename "${real_files[0]}")"      # e.g. initrd.img-6.1.115-vendor-rk35xx
        echo "${base#initrd.img-}"
        return 0
    fi

    # Multiple files → prefer uname -r if exists
    local uname_k
    uname_k="$(uname -r)"
    if [ -f "/boot/initrd.img-${uname_k}" ]; then
        echo "${uname_k}"
        return 0
    fi

    # Otherwise pick the newest initrd.img-* by mtime
    local newest
    newest="$(ls -1t /boot/initrd.img-* 2>/dev/null | head -n1 || true)"
    if [ -n "$newest" ] && [ -f "$newest" ]; then
        local base
        base="$(basename "$newest")"
        echo "${base#initrd.img-}"
        return 0
    fi

    echo "ERROR: Failed to determine kernel version." >&2
    return 1
}

# ===== Pre-OTA checksum verification (stop OTA if mismatch) =====
# Expected layout: OTA directory contains payloads plus pre-generated *.sha256 files
# - rootfs.tar.gz + rootfs.sha256
# - boot.tar.gz or boot.itb + boot.sha256

ROOTFS_PAYLOAD="../rootfs.tar.gz"
ROOTFS_SHA="../rootfs.sha256"
BOOT_TAR_PAYLOAD="../boot.tar.gz"
BOOT_ITB_PAYLOAD="../boot.itb"
BOOT_SHA="../boot.sha256"

# rootfs is mandatory
verify_sha256 "${ROOTFS_PAYLOAD}" "${ROOTFS_SHA}" "rootfs.tar.gz" || {
    echo "[start_praper_ota] ERROR: rootfs payload checksum mismatch; aborting OTA." >&2
    exit 1
}

# boot is optional (either boot.tar.gz or boot.itb)
if [ -f "${BOOT_ITB_PAYLOAD}" ]; then
    verify_sha256 "${BOOT_ITB_PAYLOAD}" "${BOOT_SHA}" "boot.itb" || {
        echo "[start_praper_ota] ERROR: boot.itb checksum mismatch; aborting OTA." >&2
        exit 1
    }
elif [ -f "${BOOT_TAR_PAYLOAD}" ]; then
    verify_sha256 "${BOOT_TAR_PAYLOAD}" "${BOOT_SHA}" "boot.tar.gz" || {
        echo "[start_praper_ota] ERROR: boot.tar.gz checksum mismatch; aborting OTA." >&2
        exit 1
    }
else
    echo "[start_praper_ota] No boot payload found (boot.itb/boot.tar.gz). Continuing with rootfs-only OTA."
fi

# ===== mv ota package to /ota_work/ =====
echo "[start_praper_ota] mv ota package to /ota_work/"
mkdir -p /ota_work
mv ../*.tar.gz /ota_work/

# ===== Check boot partition type and handle boot.itb =====
echo "[start_praper_ota] Checking /dev/mmcblk0p1 filesystem type..."
if [ -e /dev/mmcblk0p1 ]; then
    BOOT_FS_TYPE=$(blkid -o value -s TYPE /dev/mmcblk0p1 2>/dev/null || echo "")
    echo "[start_praper_ota] /dev/mmcblk0p1 filesystem type: $BOOT_FS_TYPE"

    if [ -f "../boot.itb" ]; then
        if [ "$BOOT_FS_TYPE" != "ext4" ]; then
            echo "[start_praper_ota] /dev/mmcblk0p1 is not ext4 (type: $BOOT_FS_TYPE), writing boot.itb using dd"
            cp ../boot.itb /ota_work/boot.itb
            if dd if=/ota_work/boot.itb of=/dev/mmcblk0p1 bs=1M conv=fsync; then
                echo "[start_praper_ota] Successfully wrote boot.itb to /dev/mmcblk0p1"
                sync
                # Set OTA trigger on security partition
                SECURITY_PART="/dev/block/by-name/security"
                if [ -e "$SECURITY_PART" ]; then
                    echo "[start_praper_ota] Setting OTA trigger on $SECURITY_PART"
                    sector_size=512
                    total_sectors=$(blockdev --getsz "$SECURITY_PART")
                    last_sector=$((total_sectors - 1))
                    temp_file=$(mktemp)
                    if dd if="$SECURITY_PART" bs="$sector_size" skip="$last_sector" count=1 of="$temp_file" 2>/dev/null; then
                        printf '\xaa' | dd of="$temp_file" bs=1 seek=511 count=1 conv=notrunc 2>/dev/null
                        if dd if="$temp_file" of="$SECURITY_PART" bs="$sector_size" seek="$last_sector" count=1 conv=notrunc 2>/dev/null; then
                            echo "[start_praper_ota] OTA trigger set successfully"
                        else
                            echo "[start_praper_ota] ERROR: Failed to write modified sector to $SECURITY_PART"
                        fi
                    else
                        echo "[start_praper_ota] ERROR: Failed to read last sector from $SECURITY_PART"
                    fi
                    rm -f "$temp_file"
                else
                    echo "[start_praper_ota] WARNING: Security partition $SECURITY_PART not found, cannot set OTA trigger"
                fi
                echo "[start_praper_ota] Boot update completed, exiting"
                echo "[start_praper_ota] Please reboot the system to ota rootfs."
                exit 0
            else
                echo "[start_praper_ota] ERROR: Failed to write boot.itb to /dev/mmcblk0p1"
                exit 1
            fi
        else
            echo "[start_praper_ota] /dev/mmcblk0p1 is ext4, boot.itb will be handled by OTA process"
        fi
    else
        echo "[start_praper_ota] No boot.itb found in /ota_work"
    fi
else
    echo "[start_praper_ota] /dev/mmcblk0p1 not found, skipping boot.itb handling"
fi


KVER="$(detect_kver)"
echo "[start_praper_ota] Detected kernel version: ${KVER}"
# ===== Install hook script =====
echo "[start_praper_ota] Installing 99-copy-tools to ${DEST_HOOK_DIR} ..."
mkdir -p "${DEST_HOOK_DIR}"
cp "${SRC_HOOK}" "${DEST_HOOK}"
chmod 755 "${DEST_HOOK}"

# ===== Install OTA script =====
echo "[start_praper_ota] Installing 99-ota-apply to ${DEST_OTA_DIR} ..."
mkdir -p "${DEST_OTA_DIR}"
cp "${SRC_OTA}" "${DEST_OTA}"
chmod 755 "${DEST_OTA}"

# ===== Rebuild initramfs =====
echo "[start_praper_ota] Updating initramfs for kernel: ${KVER} ..."
update-initramfs -u -k "${KVER}"

echo "[start_praper_ota] Done! /boot/initrd.img-${KVER} and its uInitrd have been updated."
