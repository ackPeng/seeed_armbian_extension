#!/bin/sh
#
# initramfs-tools init-premount hook: decryption disk auto link by-name

export SECURITY_STORAGE=SECURITY
BN_DIR="/dev/block/by-name"
mkdir -p "$BN_DIR"

log_step() {
    echo "$*"
    if [ -e /dev/kmsg ]; then
        echo "$*" > /dev/kmsg 2>/dev/null || true
    fi
}

get_cmdline_crypt_uuid() {
    local token value
    for token in $(cat /proc/cmdline 2>/dev/null); do
        case "$token" in
            cryptdevice=UUID=*:*)
                value="${token#cryptdevice=UUID=}"
                echo "${value%%:*}"
                return 0
                ;;
            cryptdevice=UUID=*)
                value="${token#cryptdevice=UUID=}"
                echo "${value}"
                return 0
                ;;
        esac
    done
    return 1
}

log_step "[Decryption-disk] ENTER 0-decryption-disk"

for disk in /sys/block/*; do
    disk_name="$(basename "$disk")"
    case "$disk_name" in
        loop*|ram*|zram*|dm-*|mtdblock*) continue ;;
    esac

    for entry in "$disk"/"${disk_name}"*; do
        [ -d "$entry" ] || continue
        [ -f "$entry/partition" ] || continue

        devnode="/dev/$(basename "$entry")"
        name="$(sed -n 's/^PARTNAME=//p' "$entry/uevent" | head -n1)"

        if [ -n "$name" ]; then
            ln -sf "$devnode" "$BN_DIR/$name"
            echo "[Decryption-disk] $name  ->  $devnode"
        fi
    done
done

echo
echo "[Decryption-disk] ln Done. Result:"
ls -l $BN_DIR
log_step "[Decryption-disk] by-name links created"

/bin/ln -sf "$(blkid -t PARTLABEL=security -o device | head -n1)" /dev/block/by-name/security 2>/dev/null || true
if [ ! -e /dev/block/by-name/security ]; then
    log_step "[Decryption-disk] Error: cannot resolve security partition (/dev/block/by-name/security)"
    blkid
    exit 1
fi
log_step "[Decryption-disk] security partition resolved: $(readlink -f /dev/block/by-name/security)"

/usr/bin/tee-supplicant &
log_step "[Decryption-disk] tee-supplicant started"


# Check security partition header marker
SECURITY_MARKER=$(head -c 4 /dev/block/by-name/security)

log_step "[Decryption-disk] Security partition marker: $SECURITY_MARKER"

if [ "$SECURITY_MARKER" = "SSKR" ]; then
    log_step "[Decryption-disk] Security partition has SSKR marker, reading with keybox_app..."
    /usr/bin/keybox_app
    log_step "[Decryption-disk] keybox_app read finished (SSKR path)"
else
    log_step "[Decryption-disk] No SSKR marker, reading first 64 bytes as password..."
    head -c 64 /dev/block/by-name/security > /tmp/syspw
    # Write password to keybox if needed
    log_step "[Decryption-disk] keybox_app write start"
    /usr/bin/keybox_app write
    log_step "[Decryption-disk] keybox_app write done"
    rm /tmp/syspw
    log_step "[Decryption-disk] keybox_app read start"
    /usr/bin/keybox_app
    log_step "[Decryption-disk] keybox_app read done"
fi

# Verify password was successfully retrieved
if [ -f /tmp/syspw ] && [ -s /tmp/syspw ]; then
    log_step "[Decryption-disk] Password successfully retrieved from security partition"
    PW_LEN="$(wc -c < /tmp/syspw 2>/dev/null || echo 0)"
    echo "[Decryption-disk] password bytes read: ${PW_LEN}"

    # Decrypt LUKS partition
    log_step "[Decryption-disk] Searching for LUKS partitions..."

    ROOT_DEVICE=""
    TARGET_LUKS_UUID="$(get_cmdline_crypt_uuid || true)"
    if [ -n "$TARGET_LUKS_UUID" ]; then
        ROOT_DEVICE="$(blkid -t UUID="$TARGET_LUKS_UUID" -o device 2>/dev/null | head -n1)"
        if [ -n "$ROOT_DEVICE" ]; then
            ROOT_TYPE="$(blkid -s TYPE -o value "$ROOT_DEVICE" 2>/dev/null || true)"
            if [ "$ROOT_TYPE" != "crypto_LUKS" ]; then
                ROOT_DEVICE=""
            else
                log_step "[Decryption-disk] Selected LUKS by cmdline UUID: ${TARGET_LUKS_UUID}"
            fi
        fi
    fi

    # Fallback: choose the first LUKS device
    if [ -z "$ROOT_DEVICE" ]; then
        ROOT_DEVICE=$(blkid -t TYPE="crypto_LUKS" -o device | head -n1)
    fi

    if [ -z "$ROOT_DEVICE" ]; then
        log_step "[Decryption-disk] Error: No LUKS partition found"
        echo "[Decryption-disk] Available partitions:"
        ls -la /dev/mmcblk* /dev/sd* 2>/dev/null | grep -E "mmcblk[0-9]+$|sd[a-z][0-9]*$"
        exit 1
    fi

    UUID=$(blkid -s UUID -o value "$ROOT_DEVICE")
    log_step "[Decryption-disk] Found LUKS device: $ROOT_DEVICE (UUID: $UUID)"

    # Unlock LUKS partition with password
    log_step "[Decryption-disk] Unlocking LUKS encrypted partition..."
    cat /tmp/syspw | /sbin/cryptsetup luksOpen "$ROOT_DEVICE" armbian-root || {
        log_step "[Decryption-disk] Error: Failed to unlock LUKS partition"
        exit 1
    }

    log_step "[Decryption-disk] LUKS partition unlocked successfully"
else
    log_step "[Decryption-disk] Error: Failed to retrieve password from security partition"
    exit 1
fi
