#!/bin/sh
#
# initramfs-tools init-premount hook: decryption disk auto link by-name

export SECURITY_STORAGE=SECURITY
BN_DIR="/dev/block/by-name"
mkdir -p "$BN_DIR"


for entry in /sys/block/mmcblk0/mmcblk0p*; do
    devnode="/dev/$(basename $entry)"
    name=$(grep PARTNAME $entry/uevent | cut -d= -f2)

    if [ -n "$name" ]; then
        ln -sf "$devnode" "$BN_DIR/$name"
        echo "[Decryption-disk] $name  ->  $devnode"
    fi
done

echo
echo "[Decryption-disk] ln Done. Result:"
ls -l $BN_DIR

/usr/bin/tee-supplicant &


# Check security partition header marker
SECURITY_MARKER=$(head -c 4 /dev/block/by-name/security)

echo "[Decryption-disk] Security partition marker: $SECURITY_MARKER"

if [ "$SECURITY_MARKER" = "SSKR" ]; then
    echo "[Decryption-disk] Security partition has SSKR marker, reading with keybox_app..."
    /usr/bin/keybox_app
else
    echo "[Decryption-disk] No SSKR marker, reading first 64 bytes as password..."
    head -c 64 /dev/block/by-name/security > /tmp/syspw
    # Write password to keybox if needed
    /usr/bin/keybox_app write
    rm /tmp/syspw
    /usr/bin/keybox_app
fi

# Verify password was successfully retrieved
if [ -f /tmp/syspw ] && [ -s /tmp/syspw ]; then
    echo "[Decryption-disk] Password successfully retrieved from security partition"

    # Decrypt LUKS partition
    # Find LUKS partition directly via blkid
    echo "[Decryption-disk] Searching for LUKS partitions..."

    # Find LUKS partition
    ROOT_DEVICE=$(blkid -t TYPE="crypto_LUKS" -o device | head -n1)

    if [ -z "$ROOT_DEVICE" ]; then
        echo "[Decryption-disk] Error: No LUKS partition found"
        echo "[Decryption-disk] Available partitions:"
        ls -la /dev/mmcblk* /dev/sd* 2>/dev/null | grep -E "mmcblk[0-9]+$|sd[a-z][0-9]*$"
        exit 1
    fi

    UUID=$(blkid -s UUID -o value "$ROOT_DEVICE")
    echo "[Decryption-disk] Found LUKS device: $ROOT_DEVICE (UUID: $UUID)"

    # Unlock LUKS partition with password
    echo "[Decryption-disk] Unlocking LUKS encrypted partition..."
    cat /tmp/syspw | /sbin/cryptsetup luksOpen "$ROOT_DEVICE" armbian-root || {
        echo "[Decryption-disk] Error: Failed to unlock LUKS partition"
        return 1
    }

    echo "[Decryption-disk] LUKS partition unlocked successfully"
else
    echo "[Decryption-disk] Error: Failed to retrieve password from security partition"
    exit 1
fi
