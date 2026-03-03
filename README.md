# Seeed Armbian Extension

> This repository extends functionality for Seeed Studio RKXX devices. Currently, it supports **OTA updates** and **disk encryption**, with more features to be added in the future.

## Features

### Secure Boot
- FIT image-based signature verification mechanism
- Automatic generation of RSA 2048-bit key pairs
- Support for Rockchip vendor U-Boot build process
- RAW boot partition mode to prevent tampering

### Disk Encryption
- OP-TEE (Open Portable Trusted Execution Environment) integration
- Automatic root partition decryption during initramfs stage
- Security partition for storing encryption credentials

### OTA Updates (Over-The-Air Updates)

#### AB Partition Mode
- Dual-slot A/B partition architecture
- Seamless online updates without system interruption
- Automatic health checks and failure rollback
- Shared user data partition

#### Recovery Mode
- Single partition recovery mode
- Suitable for secure boot + disk encryption scenarios
- Updates applied during initramfs stage

## Project Structure

```
seeed_armbian_extension/
├── armbian-ota/                            # OTA update support
│   ├── README.md                           # OTA documentation
│   ├── ota-support.sh                      # Main entry script
│   ├── recovery_ota/                       # Recovery OTA mode
│   │   ├── initramfs_hooks/
│   │   │   ├── 99-copy-tools               # Copy tools to initramfs
│   │   │   └── 99-ota-apply                # OTA apply script
│   │   ├── fit/fit-ota                     # FIT image OTA support
│   │   └── start_prepare_ota.sh            # OTA preparation script
│   └── ab_ota/                             # AB partition OTA mode
│       ├── systemd/                        # systemd services
│       │   ├── armbian-ota-firstboot.service
│       │   ├── armbian-ota-init-uboot.service
│       │   ├── armbian-ota-mark-success.service
│       │   └── armbian-ota-rollback.service
│       ├── userspace/                      # Userspace tools
│       │   ├── armbian-ota-manager         # OTA management tool
│       │   ├── armbian-ota-health-check    # Health check
│       │   ├── armbian-ota-init-uboot      # U-Boot initialization
│       │   └── lib/common.sh               # Common function library
│       └── system/
│           └── armbian-resize-userdata     # userdata expansion
│
└── rk_secure-disk-encryption/              # RK secure boot and disk encryption
    ├── rk-secure-boot.sh                   # Secure boot configuration
    ├── rk-auto-decryption-disk.sh          # Auto decryption configuration
    ├── secure-boot-config/                 # Secure boot config files
    │   ├── defconfig/                      # U-Boot defconfig
    │   ├── fit_kernel.its                  # FIT image template
    │   └── *.patch                         # Patch files
    └── auto-decryption-config/             # Auto decryption config
        ├── install-optee                   # OP-TEE install hook
        └── decryption-disk.sh              # Disk decryption script
```

## Supported Devices

- Seeed Studio reComputer RK35XX series
- Other RK35XX-based Rockchip devices (may require adaptation)

## Quick Start

### Building Images

#### AB Partition OTA Mode

```bash
# Configure build options
export OTA_ENABLE=yes           # Enable OTA
export AB_PART_OTA=yes          # Enable AB partition OTA


# Run Armbian build
./compile.sh
```

#### Recovery OTA Mode

```bash
export OTA_ENABLE=yes           # Enable OTA

# Run Armbian build
./compile.sh
```

#### Disk Encryption Mode

```bash
# Configure build options
export CRYPTROOT_ENABLE=yes         # Enable disk encryption
export RK_AUTO_DECRYP=yes           # Enable auto disk decryption
export RK_SECURE_UBOOT_ENABLE=yes   # Enable secure boot
export CRYPTROOT_PASSPHRASE="your-secure-passphrase" # Set encryption password

# Run Armbian build
./compile.sh
```

## OTA Update Usage Guide

### AB Partition Mode

#### Check OTA Status

```bash
armbian-ota-manager status
```

Example output:
```
=== Armbian AB OTA Status ===

U-boot Environment:
  boot_slot: a
  boot_success: a
  ota_in_progress: 0
  try_count: 0

Slot Information:
  Current slot: a

Partitions:
  armbi_boota: /dev/nvme0n1p1 (UUID: xxx) [BOOTING]
  armbi_bootb: /dev/nvme0n1p2 (UUID: xxx)
  armbi_roota: /dev/nvme0n1p3 (UUID: xxx) [BOOTING]
  armbi_rootb: /dev/nvme0n1p4 (UUID: xxx)
```

#### Perform OTA Update

```bash
# 1. Transfer OTA package to device
scp Armbian_*_AB_PART_OTA.tar.gz user@device:/tmp/

# 2. Start OTA update on device
armbian-ota-manager start /tmp/Armbian_*_AB_PART_OTA.tar.gz

# 3. System will display update progress and prompt for reboot
# ==========================================
# OTA update completed successfully!
# Target slot: b
# ==========================================
#
# The new firmware has been installed to slot b
# Your current system (slot a) is still running normally
#
# To switch to the new firmware, reboot:
#   reboot
#
# After reboot, health checks will run automatically
# If they fail, the system will automatically roll back to slot a

# 4. Reboot device
reboot
```

#### Manual Rollback

```bash
# If issues occur with new version, manual rollback is available
armbian-ota-manager rollback
```

#### Mark OTA as Successful

Usually OTA is automatically marked as successful. If manual marking is needed:

```bash
armbian-ota-manager mark-success
```

### Recovery Mode

```bash
# 1. Transfer OTA package to device
scp Armbian_*_RECOVERY_OTA.tar.gz user@device:/tmp/

# 2. Prepare OTA update
./start_prepare_ota.sh /tmp/Armbian_*_RECOVERY_OTA.tar.gz

# 3. Reboot device, initramfs will automatically apply update
reboot
```

## Partition Layout

### AB Partition Mode

| Partition | Label | Size | Purpose |
|-----------|-------|------|---------|
| nvme0n1p1 | armbi_boota | 256 MiB | Boot Slot A |
| nvme0n1p2 | armbi_bootb | 256 MiB | Boot Slot B |
| nvme0n1p3 | armbi_roota | 4608 MiB | Root Slot A |
| nvme0n1p4 | armbi_rootb | 4608 MiB | Root Slot B |
| nvme0n1p5 | armbi_usrdata | 256+ MiB | User data (shared, using overlayroot) |

### Recovery Mode

| Partition | Label | Size | Purpose |
|-----------|-------|------|---------|
| nvme0n1p1 | boot | 256 MiB | Boot partition (RAW mode) |
| nvme0n1p2 | security | 4 MiB | Security partition (stores encryption keys) |
| nvme0n1p3 | rootfs | Remaining | Root filesystem (encrypted) |

## Contributing

Issues and Pull Requests are welcome!

## Contact

- Seeed Studio: https://www.seeedstudio.com/
- Armbian Project: https://www.armbian.com/

---

**Note**: This project is designed for Seeed Studio RK35XX devices. Usage on other devices may require adaptation.
