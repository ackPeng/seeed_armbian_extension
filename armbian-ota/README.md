# Armbian OTA Support

This extension provides two different OTA (Over-The-Air) update mechanisms for Armbian:

1. **Recovery OTA** - Single partition recovery mode (existing implementation)
2. **AB Partition OTA** - Dual partition A/B update mode with automatic rollback

## Directory Structure

```
extensions/armbian-ota/
├── ota-support.sh                          # Main entry point
│
├── recovery_ota/                           # Recovery OTA mode
│   ├── initramfs_hooks/
│   │   ├── 99-copy-tools                   # Initramfs hook for recovery OTA
│   │   └── 99-ota-apply                    # Recovery OTA apply script
│   ├── fit/
│   │   └── fit-ota                         # FIT image OTA support
│   └── start_prepare_ota.sh                # Recovery OTA preparation script
│
├── ab_ota/                                 # AB Partition OTA mode
│   ├── initramfs_hooks/
│   │   ├── 99-copy-ab-ota-tools            # Initramfs hook for AB OTA
│   │   └── ab-ota-apply                    # AB OTA apply script
│   ├── userspace/
│   │   ├── armbian-ota-manager             # Main OTA management tool
│   │   ├── armbian-ota-health-check        # First boot health check
│   │   └── lib/common.sh                   # Common functions
│   ├── systemd/
│   │   ├── armbian-ota-firstboot.service   # Health check service
│   │   ├── armbian-ota-mark-success.service # Mark success service
│   │   └── armbian-ota-rollback.service    # Rollback service
│   └── configs/                            # Configuration templates
│
├── common/                                 # Shared utilities
│   └── lib/
│       ├── logger.sh                       # Logging functions
│       ├── partition.sh                    # Partition operations
│       └── verify.sh                       # SHA256 verification
│
└── systemd/                                # Shared systemd services
    ├── armbian-resize-userdata
    └── armbian-resize-userdata.service
```

## Recovery OTA Mode

### Configuration

Set these environment variables to enable Recovery OTA:

```bash
RK_SECURE_UBOOT_ENABLE=yes
RK_AUTO_DECRYP=yes
```

### How It Works

1. OTA package is extracted to `/ota_work/`
2. On reboot, initramfs detects trigger in security partition
3. OTA is applied directly to current rootfs
4. System reboots into updated firmware

### Usage

```bash
# On target system
./start_prepare_ota.sh <path-to-ota-package.tar.gz>
reboot
```

## AB Partition OTA Mode

### Configuration

Set this environment variable to enable AB Partition OTA:

```bash
AB_PART_OTA=yes
```

**Important**: AB OTA and Recovery OTA are mutually exclusive. You cannot enable both at the same time.

### Partition Layout

| Partition | Label | Purpose |
|-----------|-------|---------|
| nvme0n1p1 | armbi_boota | Boot slot A |
| nvme0n1p2 | armbi_bootb | Boot slot B |
| nvme0n1p3 | armbi_roota | Root slot A |
| nvme0n1p4 | armbi_rootb | Root slot B |
| nvme0n1p5 | armbi_usrdata | User data (shared) |

### U-Boot Environment Variables

| Variable | Purpose |
|----------|---------|
| `boot_slot` | Current active slot (a or b) |
| `boot_success` | Last successfully booted slot |
| `ota_in_progress` | OTA in progress flag (0 or 1) |

### How It Works

1. User initiates OTA with `armbian-ota-manager start <package>`
2. OTA payload is copied to target (inactive) slot partitions
3. `ota_in_progress=1` and `boot_slot` are set to target slot
4. System reboots
5. Initramfs detects OTA in progress, applies update to target slot
6. System boots from target slot
7. Health checks run on first boot
8. If checks pass: OTA marked successful, `ota_in_progress=0`
9. If checks fail: Automatic rollback to previous slot

### Usage

```bash
# Check status
armbian-ota-manager status

# Start OTA update
armbian-ota-manager start Armbian_xxx-OTA.tar.gz

# System will reboot and apply update automatically

# Manual rollback (if needed)
armbian-ota-manager rollback

# Mark as successful (if automatic marking failed)
armbian-ota-manager mark-success
```

## Build Configuration

Add to your board configuration or build command:

```bash
# For AB Partition OTA
AB_PART_OTA=yes
AB_BOOT_SIZE=256        # Boot partition size in MiB
AB_ROOTFS_SIZE=4608     # Rootfs partition size in MiB
USERDATA=256            # Userdata partition size in MiB

# For Recovery OTA
RK_SECURE_UBOOT_ENABLE=yes
RK_AUTO_DECRYP=yes
```

## OTA Package Contents

The OTA package (`*-OTA.tar.gz`) contains:

- `rootfs.tar.gz` - Root filesystem image (required)
- `rootfs.sha256` - Root filesystem checksum (required)
- `boot.tar.gz` - Boot partition image (optional)
- `boot.sha256` - Boot partition checksum (optional)
- `boot.itb` - FIT boot image (for secure boot)

## Troubleshooting

### Check OTA Status

```bash
armbian-ota-manager status
```

### View Logs

```bash
# OTA manager logs
cat /var/log/armbian-ota/ota.log

# Health check logs
cat /var/log/armbian-ota/health-check.log

# Initramfs logs
cat /run/initramfs/ab-ota.log
```

### Manual Rollback

```bash
armbian-ota-manager rollback
```

### Check U-Boot Environment

```bash
fw_printenv
fw_printenv -n boot_slot
fw_printenv -n ota_in_progress
```

### Set U-Boot Environment Manually

```bash
fw_setenv boot_slot a
fw_setenv boot_success a
fw_setenv ota_in_progress 0
```

## Development

### Adding New Features

1. For Recovery OTA: Modify files in `recovery_ota/`
2. For AB OTA: Modify files in `ab_ota/`
3. For shared functionality: Use `common/lib/`

### Function Naming Convention

In `ota-support.sh`:
- Recovery OTA: `pre_update_initramfs__301_*` (priority 301)
- AB OTA: `pre_update_initramfs__302_*` (priority 302)
- Shared: Use appropriate priority based on dependencies

## License

This extension is part of the Armbian project and follows the same license.
