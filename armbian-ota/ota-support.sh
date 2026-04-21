function pre_update_initramfs__301_config_fit_ota_script(){

    if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
        display_alert "ota config" "Installing FIT OTA support into initramfs" "info"
        local root_dir="${MOUNT}"
        # Copy 99-copy-tools hook file
        local hook_src="${SRC}/extensions/armbian-ota/armbian_ota_tools/99-copy-tools"
        local hook_dst="${root_dir}/etc/initramfs-tools/hooks/zz-copy-tools"

        if [[ -f "${hook_src}" ]]; then
            cp "${hook_src}" "${hook_dst}" || {
                display_alert "ota config" "Failed to copy 99-copy-toolshook" "err"
                return 1
            }
            chmod +x "${hook_dst}"
            display_alert "ota config" "99-copy-tools hook installation completed" "info"
        else
            display_alert "ota config" "99-copy-tools source file not found: ${hook_src}" "warn"
        fi

        # Copy fit-ota.sh script to initramfs
        display_alert "ota config" "Installing fit-ota script" "info"
        # Copy fit-ota.sh script
        local ota_src="${SRC}/extensions/armbian-ota/armbian_ota_tools/fit-ota"
        local ota_dst="${root_dir}/etc/initramfs-tools/scripts/init-premount/1-fit-ota"

        if [[ -f "${ota_src}" ]]; then
            cp "${ota_src}" "${ota_dst}" || {
                display_alert "ota config" "Failed to copy fit-ota script" "err"
                return 1
            }
            chmod +x "${ota_dst}"
            display_alert "ota config" "fit-ota script installation completed" "info"
        else
            display_alert "ota config" "fit-ota.sh source file not found: ${ota_src}" "warn"
        fi
    fi

}
function pre_umount_final_image__901_create_ota_payload_pkg() {


    display_alert "pre_umount_final_image__901 Extracting partition images from loop device" "Detecting and extracting partitions from ${LOOP}" "info"


    # Check for secure boot and auto ota configuration
    local secure_boot_and_decrypt="no"
    local encrypted_autodecrypt_nonsecure="no"
    if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
        secure_boot_and_decrypt="yes"
        display_alert "Secure boot and auto ota enabled" "Using FIT image workflow" "info"
    elif [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" ]]; then
        encrypted_autodecrypt_nonsecure="yes"
        display_alert "Encrypted auto-decrypt OTA" "Non-secure boot mode: use mapper rootfs and package plain boot partition" "info"
    fi

    # Create temporary directory for OTA package building
    local ota_temp_dir="${WORKDIR}/ota_package_build_$$"
    mkdir -p "$ota_temp_dir"

    # Check if loop device exists
    if [[ ! -b "${LOOP}" ]]; then
        display_alert "Error: Loop device not found" "${LOOP}" "err"
        return 1
    fi

    # Check required tools
    local required_tools="tar mount"
    for tool in $required_tools; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            display_alert "Error: Missing required tool" "$tool" "err"
            return 1
        fi
    done

    # For secure boot and auto ota, we don't need to detect partitions
    local boot_partition=""
    local rootfs_partition=""

    if [[ "$secure_boot_and_decrypt" == "yes" ]]; then
        display_alert "Secure boot mode" "Skipping partition detection" "info"
        # In secure boot mode, we'll use /dev/mapper/armbian-root directly
        rootfs_partition="encrypted"
    elif [[ "${AB_PART_OTA}" == "yes" ]]; then
        # AB partition OTA mode: Detect boot_a and rootfs_a partitions
        display_alert "AB partition OTA mode" "Detecting A-slot partitions" "info"

        # Get all partition information
        local partition_info
        partition_info=$(lsblk -ln -o NAME,SIZE,MOUNTPOINT "${LOOP}" | grep -E "${LOOP##*/}p?[0-9]+" | sort)

        display_alert "AB partition OTA" "Looking for armbi_boota and armbi_roota partitions" "info"

        # For AB OTA, we use fixed partition indices from the build process
        if [[ -n "${AB_BOOT_A_PART_INDEX}" ]]; then
            boot_partition="${LOOP}p${AB_BOOT_A_PART_INDEX}"
            display_alert "AB partition OTA" "Using boot_a partition: ${boot_partition}" "info"
        fi

        if [[ -n "${AB_ROOTFS_A_PART_INDEX}" ]]; then
            rootfs_partition="${LOOP}p${AB_ROOTFS_A_PART_INDEX}"
            display_alert "AB partition OTA" "Using rootfs_a partition: ${rootfs_partition}" "info"
        fi

        # Ensure rootfs partition exists
        if [[ -z "$rootfs_partition" || ! -b "$rootfs_partition" ]]; then
            display_alert "Error: Could not find rootfs_a partition" "${rootfs_partition:-not set}" "err"
            return 1
        fi
    else
        # Normal mode: Dynamically detect boot and rootfs partitions
        local partitions_found=()

        # Get all partition information (including size, mount point)
        local partition_info
        partition_info=$(lsblk -ln -o NAME,SIZE,MOUNTPOINT "${LOOP}" | grep -E "${LOOP##*/}p?[0-9]+" | sort)

        # Print partition_info for debugging
        display_alert "Loop device partitions" "${LOOP}" "info"
        display_alert "DEBUG: partition_info content" "=== START ===" "info"
        echo "$partition_info" | while IFS= read -r line; do
            display_alert "DEBUG partition_info line" "[$line]" "info"
        done
        display_alert "DEBUG: partition_info content" "=== END ===" "info"

        if [[ -z "$partition_info" ]]; then
            display_alert "Error: No partitions found on loop device" "${LOOP}" "err"
            return 1
        fi

        # Iterate through partitions, using mount point detection strategy
        while IFS= read -r partition_line; do
            if [[ -n "$partition_line" ]]; then
                display_alert "DEBUG raw line" "[$partition_line]" "debug"

                # Get clearer information: NAME, SIZE, MOUNTPOINT
                local partition_name=$(echo "$partition_line" | awk '{print $1}')
                local part_size=$(echo "$partition_line" | awk '{print $2}')
                local mount_point=$(echo "$partition_line" | awk '{print $3}')

                local full_path="/dev/$partition_name"

                display_alert "DEBUG parsed fields" "name=${partition_name}, size=${part_size}, mount=${mount_point}" "debug"

                if [[ -b "$full_path" ]]; then
                    partitions_found+=("$full_path")

                    # Use mount point information to differentiate
                    if [[ -n "$mount_point" ]]; then
                        # Detect boot partition: mount path contains "/boot"
                        if [[ "$mount_point" == *"/boot" && -z "$boot_partition" ]]; then
                            boot_partition="$full_path"
                            display_alert "Detected boot partition by mount point" "${full_path} (mounted at ${mount_point})" "info"
                            continue
                        fi

                        # Detect rootfs partition: mounted at root directory (does not end with "/boot")
                        if [[ "$mount_point" != *"/boot" && -z "$rootfs_partition" ]]; then
                            rootfs_partition="$full_path"
                            display_alert "Detected rootfs partition by mount point" "${full_path} (mounted at ${mount_point})" "info"
                            continue
                        fi
                    fi
                fi
            fi
        done <<< "$partition_info"

        # Ensure at least rootfs partition exists (except encrypted auto-decrypt non-secure mode)
        if [[ -z "$rootfs_partition" ]]; then
            if [[ "${encrypted_autodecrypt_nonsecure}" == "yes" ]]; then
                display_alert "Encrypted auto-decrypt OTA" "Skip rootfs partition detection in non-secure mode, rootfs will use /dev/mapper/armbian-root" "info"
            else
                display_alert "Error: Could not identify rootfs partition" "" "err"
                return 1
            fi
        fi
    fi

    # Fallback: try boot partition by LABEL/PARTLABEL when mountpoint probing misses it.
    if [[ -z "${boot_partition}" ]]; then
        local boot_candidate=""
        for boot_label in armbi_boot boot; do
            boot_candidate="$(blkid -t LABEL="${boot_label}" -o device 2>/dev/null | head -n1)"
            if [[ -n "${boot_candidate}" && -b "${boot_candidate}" ]]; then
                boot_partition="${boot_candidate}"
                display_alert "Boot partition fallback" "Detected boot partition by LABEL=${boot_label}: ${boot_partition}" "info"
                break
            fi
        done

        if [[ -z "${boot_partition}" ]]; then
            boot_candidate="$(blkid -t PARTLABEL=boot -o device 2>/dev/null | head -n1)"
            if [[ -n "${boot_candidate}" && -b "${boot_candidate}" ]]; then
                boot_partition="${boot_candidate}"
                display_alert "Boot partition fallback" "Detected boot partition by PARTLABEL=boot: ${boot_partition}" "info"
            fi
        fi
    fi

    # Get partition information
    local boot_size=0
    local rootfs_size=0

    if [[ "$secure_boot_and_decrypt" != "yes" && "${encrypted_autodecrypt_nonsecure}" != "yes" ]]; then
        rootfs_size=$(blockdev --getsize64 "$rootfs_partition" 2>/dev/null || echo "0")
        if [[ -n "$boot_partition" ]]; then
            boot_size=$(blockdev --getsize64 "$boot_partition" 2>/dev/null || echo "0")
        fi
        display_alert "Found partitions" "boot: ${boot_partition:-"none"} (${boot_size} bytes), rootfs: ${rootfs_partition} (${rootfs_size} bytes)" "info"
    else
        if [[ "$secure_boot_and_decrypt" == "yes" ]]; then
            display_alert "Secure boot mode active" "Using boot.itb and encrypted rootfs" "info"
        else
            if [[ -n "$boot_partition" ]]; then
                boot_size=$(blockdev --getsize64 "$boot_partition" 2>/dev/null || echo "0")
            fi
            display_alert "Encrypted auto-decrypt mode active" "Using mapper rootfs and boot partition ${boot_partition:-none} (${boot_size} bytes)" "info"
        fi
    fi

    # Create temporary mount points
    local boot_mount="${WORKDIR}/boot_mount"
    local rootfs_mount="${WORKDIR}/rootfs_mount"
    mkdir -p "$boot_mount" "$rootfs_mount"

    local extract_boot=false
    local extract_rootfs=true  # rootfs always extracted

    # Define tar package paths
    local boot_tar="${ota_temp_dir}/boot.tar.gz"
    local rootfs_tar="${ota_temp_dir}/rootfs.tar.gz"

    # SHA256 checksum files to be included in final OTA tarball
    local boot_sha_file="${ota_temp_dir}/boot.sha256"
    local rootfs_sha_file="${ota_temp_dir}/rootfs.sha256"

    # Handle boot partition content
    if [[ "$secure_boot_and_decrypt" == "yes" ]]; then
        local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
        local uboot_dir="${uboot_src}"
        # For secure boot with auto ota, look for boot.itb in the chroot
        local boot_itb_source="${uboot_dir}/fit/boot.itb"
        if [[ -f "$boot_itb_source" ]]; then
            display_alert "Copying FIT boot image" "${boot_itb_source} -> boot.itb" "info"
            if cp "$boot_itb_source" "${ota_temp_dir}/boot.itb"; then
                local boot_itb_size=$(stat -c%s "${ota_temp_dir}/boot.itb")
                display_alert "FIT boot image copied" "boot.itb size: $((boot_itb_size / 1024)) KB" "info"

                # Generate SHA256 for boot.itb
                if command -v sha256sum >/dev/null 2>&1; then
                    (cd "${ota_temp_dir}" && sha256sum "boot.itb" > "${boot_sha_file}") || {
                        display_alert "Warning: Failed to generate SHA256 for boot.itb" "${boot_sha_file}" "warn"
                    }
                else
                    display_alert "Warning: sha256sum not available; skipping boot.itb SHA256" "" "warn"
                fi
            else
                display_alert "Warning: Failed to copy boot.itb" "" "warn"
            fi
        else
            display_alert "Warning: boot.itb not found at ${boot_itb_source}" "" "warn"
        fi
    elif [[ -n "$boot_partition" && -b "$boot_partition" ]]; then
        # Normal boot partition extraction
        display_alert "Extracting boot partition content" "${boot_partition} -> boot.tar.gz" "info"
        if mount "$boot_partition" "$boot_mount"; then
            # Create boot.tar.gz
            if (cd "$boot_mount" && tar -czf "$boot_tar" .); then
                local boot_tar_size=$(stat -c%s "$boot_tar")
                display_alert "Boot content archived" "boot.tar.gz size: $((boot_tar_size / 1024)) KB" "info"
                display_alert "Boot partition contents" "Found $(find "$boot_mount" -type f | wc -l) files" "debug"
                extract_boot=true

                # Generate SHA256 for boot.tar.gz
                if command -v sha256sum >/dev/null 2>&1; then
                    (cd "${ota_temp_dir}" && sha256sum "boot.tar.gz" > "${boot_sha_file}") || {
                        display_alert "Warning: Failed to generate SHA256 for boot.tar.gz" "${boot_sha_file}" "warn"
                    }
                else
                    display_alert "Warning: sha256sum not available; skipping boot.tar.gz SHA256" "" "warn"
                fi
            else
                umount "$boot_mount" 2>/dev/null || true
                display_alert "Warning: Failed to create boot.tar.gz" "" "warn"
            fi
            umount "$boot_mount" 2>/dev/null || true
        else
            display_alert "Warning: Failed to mount boot partition" "${boot_partition}" "warn"
        fi
    fi

    # Extract rootfs partition content
    local rootfs_source=""

    if [[ "$secure_boot_and_decrypt" == "yes" || "${RK_AUTO_DECRYP}" == "yes" ]]; then
        # For encrypted rootfs, we need to use the mapper device
        rootfs_source="/dev/mapper/armbian-root"
        display_alert "Encrypted rootfs detected" "Using mapper device: ${rootfs_source}" "info"

        # Ensure the encrypted partition is set up
        if [[ ! -e "$rootfs_source" ]]; then
            display_alert "Error: Encrypted mapper device not found" "${rootfs_source}" "err"
            rm -rf "$ota_temp_dir"
            return 1
        fi
    else
        # Normal rootfs partition
        rootfs_source="$rootfs_partition"
    fi

    display_alert "Extracting rootfs partition content" "${rootfs_source} -> rootfs.tar.gz" "info"
    if mount "$rootfs_source" "$rootfs_mount"; then
        # Create rootfs.tar.gz
        if (cd "$rootfs_mount" && tar -czf "$rootfs_tar" --exclude="./dev/*" --exclude="./proc/*" --exclude="./sys/*" --exclude="./tmp/*" --exclude="./run/*" .); then
            local rootfs_tar_size=$(stat -c%s "$rootfs_tar")
            display_alert "Rootfs content archived" "rootfs.tar.gz size: $((rootfs_tar_size / 1024 / 1024)) MB" "info"
            display_alert "Rootfs partition contents" "Found $(find "$rootfs_mount" -type f | wc -l) files" "debug"
            extract_rootfs=true

            # Generate SHA256 for rootfs.tar.gz
            if command -v sha256sum >/dev/null 2>&1; then
                (cd "${ota_temp_dir}" && sha256sum "rootfs.tar.gz" > "${rootfs_sha_file}") || {
                    display_alert "Warning: Failed to generate SHA256 for rootfs.tar.gz" "${rootfs_sha_file}" "warn"
                }
            else
                display_alert "Warning: sha256sum not available; skipping rootfs.tar.gz SHA256" "" "warn"
            fi
        else
            umount "$rootfs_mount" 2>/dev/null || true
            display_alert "Error: Failed to create rootfs.tar.gz" "" "err"
            rm -rf "$ota_temp_dir"
            return 1
        fi
        umount "$rootfs_mount" 2>/dev/null || true
    else
        display_alert "Error: Failed to mount rootfs partition" "${rootfs_source}" "err"
        rm -rf "$ota_temp_dir"
        return 1
    fi

    # Clean up temporary mount points
    rm -rf "$boot_mount" "$rootfs_mount"

    # Verify extraction results

    # Check rootfs.tar.gz (must exist)
    if [[ ! -f "$rootfs_tar" ]]; then
        display_alert "Error: rootfs.tar.gz not found" "" "err"
        return 1
    fi

    # Verify rootfs.tar.gz integrity
    if ! tar -tzf "$rootfs_tar" >/dev/null 2>&1; then
        display_alert "Error: rootfs.tar.gz is corrupted or invalid" "" "err"
        return 1
    fi

    # Verify SHA256 sums if generated
    if [[ -f "${rootfs_sha_file}" ]]; then
        if ! (cd "${ota_temp_dir}" && sha256sum -c "$(basename "${rootfs_sha_file}")" >/dev/null 2>&1); then
            display_alert "Error: rootfs.tar.gz SHA256 verification failed" "${rootfs_sha_file}" "err"
            return 1
        fi
    fi

    if [[ "$secure_boot_and_decrypt" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        # Verify boot.itb exists and is readable
        if [[ ! -r "${ota_temp_dir}/boot.itb" ]]; then
            display_alert "Error: boot.itb is not readable" "" "err"
            return 1
        fi

        if [[ -f "${boot_sha_file}" ]]; then
            if ! (cd "${ota_temp_dir}" && sha256sum -c "$(basename "${boot_sha_file}")" >/dev/null 2>&1); then
                display_alert "Error: boot.itb SHA256 verification failed" "${boot_sha_file}" "err"
                return 1
            fi
        fi

        display_alert "Archive verification completed" "boot.itb and rootfs.tar.gz are valid" "info"
    elif [[ -f "$boot_tar" ]]; then
        if ! tar -tzf "$boot_tar" >/dev/null 2>&1; then
            display_alert "Error: boot.tar.gz is corrupted or invalid" "" "err"
            return 1
        fi

        if [[ -f "${boot_sha_file}" ]]; then
            if ! (cd "${ota_temp_dir}" && sha256sum -c "$(basename "${boot_sha_file}")" >/dev/null 2>&1); then
                display_alert "Error: boot.tar.gz SHA256 verification failed" "${boot_sha_file}" "err"
                return 1
            fi
        fi

        display_alert "Archive verification completed" "boot.tar.gz and rootfs.tar.gz are valid" "info"
    else
        display_alert "Archive verification completed" "rootfs.tar.gz is valid (no boot partition found)" "info"
    fi

    # Display extraction summary
    local summary=""
    if [[ "$secure_boot_and_decrypt" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        summary="boot.itb + rootfs.tar.gz (secure boot)"
    elif [[ -f "$boot_tar" ]]; then
        summary="boot.tar.gz + rootfs.tar.gz"
    else
        summary="rootfs.tar.gz only"
    fi
    display_alert "Extraction summary" "Created $summary" "info"

    # Create final OTA package
    display_alert "Creating final OTA package" "Combining tools and images" "info"

    # Use Armbian official variable to get image name
    local base_image_name=""

	# Get kernel version information
	local kernel_version_for_image="unknown"
	if [[ -n "$KERNEL_VERSION" ]]; then
		kernel_version_for_image="$KERNEL_VERSION"
	elif [[ -n "$IMAGE_INSTALLED_KERNEL_VERSION" ]]; then
		kernel_version_for_image="${IMAGE_INSTALLED_KERNEL_VERSION/-$LINUXFAMILY/}"
	fi

	# Construct vendor and version prefix
	local vendor_version_prelude="${VENDOR}_${IMAGE_VERSION:-"${REVISION}"}_"
	if [[ "${include_vendor_version:-"yes"}" == "no" ]]; then
		vendor_version_prelude=""
	fi

	# Construct base name
	base_image_name="${vendor_version_prelude}${BOARD^}_${RELEASE}_${BRANCH}_${kernel_version_for_image}"

	# Add desktop environment suffix
	if [[ -n "$DESKTOP_ENVIRONMENT" ]]; then
		base_image_name="${base_image_name}_${DESKTOP_ENVIRONMENT}"
	fi

	# Add extra image suffix
	if [[ -n "$EXTRA_IMAGE_SUFFIX" ]]; then
		base_image_name="${base_image_name}${EXTRA_IMAGE_SUFFIX}"
	fi

	# Add build type suffix
	if [[ "$BUILD_DESKTOP" == "yes" ]]; then
		base_image_name="${base_image_name}_desktop"
	fi
	if [[ "$BUILD_MINIMAL" == "yes" ]]; then
		base_image_name="${base_image_name}_minimal"
	fi
	if [[ "$ROOTFS_TYPE" == "nfs" ]]; then
		base_image_name="${base_image_name}_nfsboot"
	fi

    # Create OTA package name with OTA type label
    local ota_type_label=""
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        ota_type_label="AB_PART_OTA"
        display_alert "OTA package type" "A/B partition OTA" "info"
    else
        ota_type_label="RECOVERY_OTA"
        display_alert "OTA package type" "Recovery OTA" "info"
    fi
    local ota_package_name="${base_image_name}_${ota_type_label}.tar.gz"
    local ota_output_path="${DEST}/images/${ota_package_name}"

    # Ensure output directory exists
    mkdir -p "${DEST}/images/"

    local manifest_mode="recovery"
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        manifest_mode="ab"
    fi

    local ota_mode_file="$ota_temp_dir/ota_manifest.env"
    cat > "$ota_mode_file" << EOF
OTA_MODE=${manifest_mode}
BOARD=${BOARD}
RELEASE=${RELEASE}
BRANCH=${BRANCH}
VERSION=${IMAGE_VERSION:-"${REVISION}"}
KERNEL=${KERNEL_VERSION:-"${IMAGE_INSTALLED_KERNEL_VERSION}"}
EOF

    # Package OTA runtime tools into payload as a fallback/offline bundle.
    local ota_ext_dir
    ota_ext_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local runtime_src="${ota_ext_dir}/runtime"
    local ab_src="${ota_ext_dir}/ab_ota"
    local recovery_src="${ota_ext_dir}/recovery_ota"
    local payload_tools_dir="${ota_temp_dir}/ota_tools"

    mkdir -p "${payload_tools_dir}"

    if [[ -d "${runtime_src}" ]]; then
        mkdir -p "${payload_tools_dir}/runtime"
        cp -a "${runtime_src}/." "${payload_tools_dir}/runtime/" || {
            display_alert "OTA payload" "Failed to copy runtime tools into payload" "err"
            rm -rf "$ota_temp_dir"
            return 1
        }
    else
        display_alert "OTA payload" "runtime source dir not found: ${runtime_src}" "warn"
    fi

    if [[ -d "${ab_src}" ]]; then
        mkdir -p "${payload_tools_dir}/ab_ota"
        cp -a "${ab_src}/userspace" "${payload_tools_dir}/ab_ota/" 2>/dev/null || true
        cp -a "${ab_src}/systemd" "${payload_tools_dir}/ab_ota/" 2>/dev/null || true
    fi

    if [[ -d "${recovery_src}" ]]; then
        mkdir -p "${payload_tools_dir}/recovery_ota"
        cp -a "${recovery_src}/armbian-ota-manager" "${payload_tools_dir}/recovery_ota/" 2>/dev/null || true
        cp -a "${recovery_src}/start_prepare_ota.sh" "${payload_tools_dir}/recovery_ota/" 2>/dev/null || true
        cp -a "${recovery_src}/initramfs_hooks" "${payload_tools_dir}/recovery_ota/" 2>/dev/null || true
        cp -a "${recovery_src}/fit" "${payload_tools_dir}/recovery_ota/" 2>/dev/null || true
    fi

    cat > "${payload_tools_dir}/README_INSTALL.txt" << 'EOF'
Armbian OTA Runtime Tools

This payload contains OTA runtime scripts for fallback/offline installation.

If firmware was built with OTA enabled:
- AB firmware (`AB_PART_OTA=yes`) already includes AB OTA runtime/tools.
- Recovery firmware (`OTA_ENABLE=yes`, no `AB_PART_OTA`) already includes Recovery OTA runtime/tools.

In those cases, you only need to copy the OTA package and run `armbian-ota start --mode=...`.

Typical usage:
1) If your firmware does not include OTA runtime, copy ota_tools/ to target board.
2) Install runtime CLI and libraries manually (as root), for example:
   cp -a runtime/armbian-ota /usr/sbin/armbian-ota
   chmod +x /usr/sbin/armbian-ota
   mkdir -p /usr/share/armbian-ota
   cp -a runtime/common.sh runtime/backend-*.sh /usr/share/armbian-ota/
   mkdir -p /usr/share/armbian-ota/recovery
   cp -a recovery_ota /usr/share/armbian-ota/recovery/

3) Trigger OTA:
   armbian-ota start --mode=ab <ota-package.tar.gz>
   armbian-ota start --mode=recovery <ota-package.tar.gz>
EOF

    # Create version info file for compatibility wrapper
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        local version_file="$ota_temp_dir/version.txt"
        cat > "$version_file" << EOF
# Armbian AB OTA Package Version Info
# Generated: $(date)

VERSION=${IMAGE_VERSION:-"${REVISION}"}
VENDOR=${VENDOR}
BOARD=${BOARD}
RELEASE=${RELEASE}
BRANCH=${BRANCH}
KERNEL=${KERNEL_VERSION:-"${IMAGE_INSTALLED_KERNEL_VERSION}"}
EOF
        display_alert "AB partition OTA" "Created version.txt for OTA package" "info"
    fi

    # Create OTA package manifest file
    local manifest_file="$ota_temp_dir/ota_manifest.txt"
    cat > "$manifest_file" << EOF
# Armbian OTA Package Manifest
# Generated on: $(date)
# Original image: ${base_image_name}

Package Contents:
EOF

    # Add file list to manifest
    if [[ "$secure_boot_and_decrypt" == "yes" && -f "${ota_temp_dir}/boot.itb" ]]; then
        echo "- boot.itb: FIT boot image for secure boot" >> "$manifest_file"
    elif [[ -f "$boot_tar" ]]; then
        echo "- boot.tar.gz: Boot partition image" >> "$manifest_file"
    fi
    if [[ -f "$rootfs_tar" ]]; then
        echo "- rootfs.tar.gz: Root filesystem image" >> "$manifest_file"
    fi
    if [[ "${AB_PART_OTA}" == "yes" && -f "$ota_temp_dir/version.txt" ]]; then
        echo "- version.txt: Version information" >> "$manifest_file"
    fi
    echo "- ota_manifest.env: OTA runtime metadata" >> "$manifest_file"
    echo "- ota_tools/: OTA runtime scripts and helpers" >> "$manifest_file"

    # Create final OTA tar.gz package
    display_alert "Creating final OTA package" "${ota_package_name}" "info"
    if (cd "$ota_temp_dir" && tar -czf "$ota_output_path" .); then
        local ota_size=$(stat -c%s "$ota_output_path")
        display_alert "OTA package created successfully" "${ota_package_name} ($((ota_size / 1024 / 1024)) MB)" "info"

        # Display OTA package contents
        display_alert "OTA package contents" "" "info"
        tar -tzf "$ota_output_path" | head -20 | while read -r file; do
            display_alert "  - $file" "" "info"
        done

        # Create checksums
        local ota_md5=$(md5sum "$ota_output_path" | awk '{print $1}')
        local ota_sha256=$(sha256sum "$ota_output_path" | awk '{print $1}')

        # Write checksums file
        local checksum_file="${DEST}/images/${base_image_name}-OTA.checksums"
        cat > "$checksum_file" << EOF
# Armbian OTA Package Checksums
# Package: ${ota_package_name}
# Generated: $(date)

MD5:    ${ota_md5}
SHA256: ${ota_sha256}
EOF
        display_alert "Checksums generated" "${checksum_file}" "info"

    else
        display_alert "Error: Failed to create OTA package" "${ota_package_name}" "err"
        rm -rf "$ota_temp_dir"
        return 1
    fi

    # Clean up temporary directory
    rm -rf "$ota_temp_dir"

    display_alert "OTA package creation completed" "Package: ${ota_package_name}" "info"
}

function pre_package_uboot_image__build_fw_env_tool(){
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "A/B partition OTA" "Building fw_env tool from u-boot source" "info"

    local RK_SDK_TOOLS="${SRC}/cache/sources/rockchip_sdk_tools"
    if [[ ! -d "${RK_SDK_TOOLS}" ]]; then
        display_alert "A/B partition OTA" "rockchip_sdk_tools missing, fetching" "info"
        fetch_from_repo "${RKBIN_GIT_URL:-"https://github.com/ackPeng/rockchip_sdk_tools.git"}" "rockchip_sdk_tools" "branch:${RKSDK_TOOLS_BRANCH:-"main"}" || {
            display_alert "A/B partition OTA" "Failed to fetch rockchip_sdk_tools; AB_PART_OTA requires fw_env build" "err"
            return 1
        }
    fi

    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    if [[ ! -d "${uboot_src}" ]]; then
        display_alert "A/B partition OTA" "u-boot source not found: ${uboot_src}; AB_PART_OTA requires fw_env build" "err"
        return 1
    fi

    if [[ ! -f "${uboot_src}/make.sh" ]]; then
        display_alert "A/B partition OTA" "make.sh not found in u-boot source; AB_PART_OTA requires fw_env build" "err"
        return 1
    fi

    local prebuilts_source="${RK_SDK_TOOLS}/other_build_tool_chain/prebuilts"
    local prebuilts_dest="${uboot_src}/../prebuilts"
    if [[ -d "${prebuilts_source}" && ! -d "${prebuilts_dest}" ]]; then
        cp -rf "${prebuilts_source}" "${prebuilts_dest}" || {
            display_alert "A/B partition OTA" "Failed to copy prebuilts; AB_PART_OTA requires fw_env build" "err"
            return 1
        }
    fi

    local rkbin_source="${RK_SDK_TOOLS}/rkbin"
    local rkbin_dest="${uboot_src}/../rkbin"
    if [[ -d "${rkbin_source}" && ! -d "${rkbin_dest}" ]]; then
        cp -rf "${rkbin_source}" "${rkbin_dest}" || {
            display_alert "A/B partition OTA" "Failed to copy rkbin; AB_PART_OTA requires fw_env build" "err"
            return 1
        }
    fi

    (
        cd "${uboot_src}" || exit 1
        bash ./make.sh env
    ) || {
        display_alert "A/B partition OTA" "Failed to run 'bash ./make.sh env'; AB_PART_OTA requires fw_env build" "err"
        return 1
    }

    local fw_env_src="${uboot_src}/tools/env/fw_printenv"
    if [[ ! -f "${fw_env_src}" ]]; then
        display_alert "A/B partition OTA" "fw_printenv not generated at ${fw_env_src} after make.sh env" "err"
        return 1
    fi

    return 0
}

function pre_umount_final_image__899_install_fw_env_tool() {
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "A/B partition OTA" "Installing fw_env tools into rootfs" "info"
    local root_dir="${MOUNT}"
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local fw_env_src="${uboot_src}/tools/env/fw_printenv"
    local fw_printenv="${root_dir}/usr/bin/fw_printenv"
    local fw_setenv="${root_dir}/usr/bin/fw_setenv"
    local fw_env_config="${root_dir}/etc/fw_env.config"
    local fw_env_device="${AB_FW_ENV_DEVICE:-/dev/mmcblk1}"
    local fw_env_offset="${AB_FW_ENV_OFFSET:-0x3f8000}"
    local fw_env_size="${AB_FW_ENV_SIZE:-0x8000}"

    if [[ ! -f "${fw_env_src}" ]]; then
        display_alert "A/B partition OTA" "fw_printenv binary not found: ${fw_env_src}; AB_PART_OTA requires this binary" "err"
        return 1
    fi

    mkdir -p "${root_dir}/usr/bin" "${root_dir}/etc"

    cp "${fw_env_src}" "${fw_printenv}" || {
        display_alert "A/B partition OTA" "Failed to install fw_printenv" "err"
        return 1
    }
    cp "${fw_env_src}" "${fw_setenv}" || {
        display_alert "A/B partition OTA" "Failed to install fw_setenv" "err"
        return 1
    }
    chmod +x "${fw_printenv}" "${fw_setenv}"
    echo "${fw_env_device} ${fw_env_offset} ${fw_env_size}" > "${fw_env_config}" || {
        display_alert "A/B partition OTA" "Failed to create fw_env.config" "err"
        return 1
    }
    display_alert "A/B partition OTA" "Installed fw_env.config: ${fw_env_device} ${fw_env_offset} ${fw_env_size}" "info"

    return 0
}

function pre_umount_final_image__894_install_ota_runtime() {
    if [[ "${OTA_ENABLE}" != "yes" ]]; then
        return 0
    fi

    local root_dir="${MOUNT}"
    local ota_ext_dir
    ota_ext_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local runtime_src="${ota_ext_dir}/runtime"
    local recovery_src="${ota_ext_dir}/recovery_ota"

    if [[ ! -d "${runtime_src}" ]]; then
        display_alert "OTA runtime" "runtime source dir missing: ${runtime_src}" "warn"
        return 0
    fi

    display_alert "OTA runtime" "Installing OTA runtime into rootfs" "info"
    mkdir -p "${root_dir}/usr/sbin" "${root_dir}/usr/share/armbian-ota"

    cp "${runtime_src}/armbian-ota" "${root_dir}/usr/sbin/armbian-ota" || {
        display_alert "OTA runtime" "Failed to install armbian-ota CLI" "err"
        return 1
    }
    cp "${runtime_src}/common.sh" "${root_dir}/usr/share/armbian-ota/common.sh" || {
        display_alert "OTA runtime" "Failed to install common.sh" "err"
        return 1
    }

    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        cp "${runtime_src}/backend-ab.sh" "${root_dir}/usr/share/armbian-ota/backend-ab.sh" || {
            display_alert "OTA runtime" "Failed to install backend-ab.sh" "err"
            return 1
        }
    else
        cp "${runtime_src}/backend-recovery.sh" "${root_dir}/usr/share/armbian-ota/backend-recovery.sh" || {
            display_alert "OTA runtime" "Failed to install backend-recovery.sh" "err"
            return 1
        }
        if [[ -d "${recovery_src}" ]]; then
            mkdir -p "${root_dir}/usr/share/armbian-ota/recovery"
            cp -a "${recovery_src}/." "${root_dir}/usr/share/armbian-ota/recovery/" || {
                display_alert "OTA runtime" "Failed to install recovery runtime assets" "err"
                return 1
            }
        fi
    fi

    chmod +x "${root_dir}/usr/sbin/armbian-ota" "${root_dir}/usr/share/armbian-ota/common.sh"
    [[ -f "${root_dir}/usr/share/armbian-ota/backend-ab.sh" ]] && chmod +x "${root_dir}/usr/share/armbian-ota/backend-ab.sh"
    [[ -f "${root_dir}/usr/share/armbian-ota/backend-recovery.sh" ]] && chmod +x "${root_dir}/usr/share/armbian-ota/backend-recovery.sh"

    return 0
}

function rk_ab_autodecrypt_nonsecure_mode_enabled() {
	[[ "${AB_PART_OTA}" == "yes" && "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" ]]
}

function pre_prepare_partitions__ab_part_ota() {
	if [[ "${AB_PART_OTA}" == "yes" ]]; then
		USE_HOOK_FOR_PARTITION="yes"
		AB_BOOT_SIZE=${AB_BOOT_SIZE:-256}  # 256MiB for each boot partition
		AB_ROOTFS_SIZE=${AB_ROOTFS_SIZE:-4608}  # 4.5GiB for each rootfs partition
		SECURE_STORAGE_SECURITY_SIZE=${SECURE_STORAGE_SECURITY_SIZE:-4}
        USERDATA=${USERDATA:-256}  # userdata partition by default
        BOOTFS_TYPE="ext4"
        ROOTFS_TYPE="ext4"
        ROOT_FS_LABEL="armbi_roota"
        BOOT_FS_LABEL="armbi_boota"
		if rk_ab_autodecrypt_nonsecure_mode_enabled; then
			display_alert "A/B partition OTA" "Creating A/B encrypted partitions: boot_a, boot_b, security, rootfs_a, rootfs_b, userdata" "info"
		else
			display_alert "A/B partition OTA" "Creating A/B partitions: boot_a, boot_b, rootfs_a, rootfs_b, userdata" "info"
		fi
	fi
}

function create_partition_table__ab_part_ota() {
	if [[ "${AB_PART_OTA}" != "yes" ]]; then
		return 0
	fi

	local next=${OFFSET} # Starting MiB
	local p_index=1
	local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
	if [[ "${IMAGE_PARTITION_TABLE:-gpt}" == "gpt" ]]; then
		# Keep GPT entry table compact to reduce SPL malloc pressure when probing partitions.
		local gpt_table_length="${AB_GPT_TABLE_LENGTH:-64}"
		script+="table-length: ${gpt_table_length}\n"
	fi

	# BIOS (if exists)
	if [[ -n "${BIOSSIZE}" && ${BIOSSIZE} -gt 0 ]]; then
		[[ "${IMAGE_PARTITION_TABLE}" == "gpt" ]] || exit_with_error "BIOS partition only supports GPT" "BIOSSIZE=${BIOSSIZE}"
		script+="${p_index} : name=\"bios\", start=${next}MiB, size=${BIOSSIZE}MiB, type=21686148-6449-6E6F-744E-656564454649\n"
		next=$((next + BIOSSIZE)); p_index=$((p_index+1))
	fi
	# EFI
	if [[ -n "${UEFISIZE}" && ${UEFISIZE} -gt 0 ]]; then
		local efi_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System
		script+="${p_index} : name=\"efi\", start=${next}MiB, size=${UEFISIZE}MiB, type=${efi_type}\n"
		next=$((next + UEFISIZE)); p_index=$((p_index+1))
	fi
	# boot_a
	local boot_type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
	script+="${p_index} : name=\"boot_a\", start=${next}MiB, size=${AB_BOOT_SIZE}MiB, type=${boot_type}\n"
	next=$((next + AB_BOOT_SIZE)); local boot_a_index=${p_index}; p_index=$((p_index+1))
	# boot_b
	script+="${p_index} : name=\"boot_b\", start=${next}MiB, size=${AB_BOOT_SIZE}MiB, type=${boot_type}\n"
	next=$((next + AB_BOOT_SIZE)); local boot_b_index=${p_index}; p_index=$((p_index+1))
	# security partition must be between boot_b and rootfs_a in AB+encrypted auto-decrypt mode.
	local security_index=""
	if rk_ab_autodecrypt_nonsecure_mode_enabled; then
		local sec_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
		script+="${p_index} : name=\"security\", start=${next}MiB, size=${SECURE_STORAGE_SECURITY_SIZE}MiB, type=${sec_type}\n"
		next=$((next + SECURE_STORAGE_SECURITY_SIZE)); security_index=${p_index}; p_index=$((p_index+1))
	fi
	# rootfs_a
	local root_type="${PARTITION_TYPE_UUID_ROOT:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}"
    script+="${p_index} : name=\"rootfs_a\", start=${next}MiB, size=${AB_ROOTFS_SIZE}MiB, type=${root_type}\n"
    next=$((next + AB_ROOTFS_SIZE)); local rootfs_a_index=${p_index}; p_index=$((p_index+1))
	# rootfs_b
	script+="${p_index} : name=\"rootfs_b\", start=${next}MiB, size=${AB_ROOTFS_SIZE}MiB, type=${root_type}\n"
    next=$((next + AB_ROOTFS_SIZE)); local rootfs_b_index=${p_index}; p_index=$((p_index+1))

	# Add userdata partition with minimal size (1MiB)
	script+="${p_index} : name=\"userdata\", start=${next}MiB, size=${USERDATA}MiB, type=${root_type}\n"
	local userdata_index=${p_index}

	display_alert "A/B partition OTA" "Custom A/B partition table:\n${script}" "debug"
	echo -e "${script}" | run_host_command_logged sfdisk ${SDCARD}.raw || exit_with_error "A/B partition creation failed" "sfdisk"

	AB_BOOT_A_PART_INDEX=${boot_a_index}
	AB_BOOT_B_PART_INDEX=${boot_b_index}
	AB_ROOTFS_A_PART_INDEX=${rootfs_a_index}
	AB_ROOTFS_B_PART_INDEX=${rootfs_b_index}
	if [[ -n "${security_index}" ]]; then
		AB_SECURITY_PART_INDEX=${security_index}
		SECURE_STORAGE_SECURITY_PART_INDEX=${security_index}
	fi
	
	# Set bootpart and rootpart for Armbian partitioning logic
	bootpart=${boot_a_index}
	rootpart=${rootfs_a_index}
    AB_USERDATA_PART_INDEX=${userdata_index}
}

function format_partitions__ab_part_ota() {
	if [[ "${AB_PART_OTA}" != "yes" ]]; then
		return 0
	fi

	# Format boot_b as ext4 with label armbi_bootb
	if [[ -n "${AB_BOOT_B_PART_INDEX}" ]]; then
		local boot_b_dev="${LOOP}p${AB_BOOT_B_PART_INDEX}"
        check_loop_device "$boot_b_dev"
		display_alert "A/B partition OTA" "Formatting boot_b (${boot_b_dev}) as ext4 with label armbi_bootb" "info"
		run_host_command_logged mkfs.ext4 -q -L armbi_bootb "${boot_b_dev}" || display_alert "A/B partition OTA" "Failed to format boot_b" "warn"
	fi

	# Format rootfs_b as ext4 with label armbi_rootb
	if [[ -n "${AB_ROOTFS_B_PART_INDEX}" ]]; then
		local rootfs_b_dev="${LOOP}p${AB_ROOTFS_B_PART_INDEX}"
        check_loop_device "$rootfs_b_dev"
		if rk_ab_autodecrypt_nonsecure_mode_enabled; then
			local mapper_name="armbian-rootb-build"
			local mapper_dev="/dev/mapper/${mapper_name}"
			[[ -n "${CRYPTROOT_PASSPHRASE}" ]] || exit_with_error "A/B encrypted OTA requires CRYPTROOT_PASSPHRASE for rootfs_b LUKS format" "AB_PART_OTA=yes CRYPTROOT_ENABLE=yes RK_AUTO_DECRYP=yes"
			command -v cryptsetup >/dev/null 2>&1 || exit_with_error "cryptsetup not found while formatting encrypted rootfs_b" "host dependency missing"

			display_alert "A/B partition OTA" "Formatting rootfs_b (${rootfs_b_dev}) as LUKS + ext4(label=armbi_rootb)" "info"
			printf "%s" "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksFormat ${CRYPTROOT_PARAMETERS} "${rootfs_b_dev}" - ||
				exit_with_error "A/B encrypted OTA failed to luksFormat rootfs_b" "${rootfs_b_dev}"
			printf "%s" "${CRYPTROOT_PASSPHRASE}" | run_host_command_logged cryptsetup luksOpen "${rootfs_b_dev}" "${mapper_name}" - ||
				exit_with_error "A/B encrypted OTA failed to luksOpen rootfs_b" "${rootfs_b_dev}"
			run_host_command_logged mkfs.ext4 -q -L armbi_rootb "${mapper_dev}" || {
				run_host_command_logged cryptsetup luksClose "${mapper_name}" || true
				exit_with_error "A/B encrypted OTA failed to mkfs rootfs_b mapper" "${mapper_dev}"
			}
			run_host_command_logged cryptsetup luksClose "${mapper_name}" || exit_with_error "A/B encrypted OTA failed to luksClose rootfs_b mapper" "${mapper_name}"
		else
			display_alert "A/B partition OTA" "Formatting rootfs_b (${rootfs_b_dev}) as ext4 with label armbi_rootb" "info"
			run_host_command_logged mkfs.ext4 -q -L armbi_rootb "${rootfs_b_dev}" || display_alert "A/B partition OTA" "Failed to format rootfs_b" "warn"
		fi
	fi

	# Format userdata as ext4 with label armbi_usrdata
	if [[ -n "${AB_USERDATA_PART_INDEX}" ]]; then
		local userdata_dev="${LOOP}p${AB_USERDATA_PART_INDEX}"
        check_loop_device "$userdata_dev"
		display_alert "A/B partition OTA" "Formatting userdata (${userdata_dev}) as ext4 with label armbi_usrdata" "info"
		run_host_command_logged mkfs.ext4 -q -L armbi_usrdata "${userdata_dev}" || display_alert "A/B partition OTA" "Failed to format userdata" "warn"
	fi

	# Set PARTLABEL for rootfs_a if not set
	if [[ -n "${AB_ROOTFS_A_PART_INDEX}" ]]; then
		display_alert "A/B partition OTA" "Setting PARTLABEL for rootfs_a on partition ${AB_ROOTFS_A_PART_INDEX}" "info"
		run_host_command_logged parted ${LOOP} name ${AB_ROOTFS_A_PART_INDEX} "rootfs_a" || display_alert "A/B partition OTA" "Failed to set PARTLABEL for rootfs_a" "warn"
	fi
}

function prepare_image_size__ab_part_ota() {
	if [[ "${AB_PART_OTA}" == "yes" ]]; then
		local security_extra_size=0
		if rk_ab_autodecrypt_nonsecure_mode_enabled; then
			security_extra_size=${SECURE_STORAGE_SECURITY_SIZE:-4}
		fi
		FIXED_IMAGE_SIZE=$(((AB_ROOTFS_SIZE * 2) + OFFSET + (AB_BOOT_SIZE * 2) + UEFISIZE + EXTRA_ROOTFS_MIB_SIZE + USERDATA + security_extra_size)) # MiB
		display_alert "A/B partition OTA" "Setting FIXED_IMAGE_SIZE to ${FIXED_IMAGE_SIZE} MiB for equal rootfs_a and rootfs_b" "info"
	fi
}

function extension_prepare_config__install_overlayroot_userdata() {
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "A/B partition OTA" "install overlayroot and busybox-static" "info"
        add_packages_to_image overlayroot busybox-static

    fi
}

function pre_umount_final_image__898_config_overlayroot() {
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "overlayroot" "Configuring overlayroot for A/B partition OTA" "info"
    local root_dir="${MOUNT}"

    # Modify BUSYBOX from auto to y in initramfs.conf
    if [[ -f "${root_dir}/etc/initramfs-tools/initramfs.conf" ]]; then
        sed -i 's/^BUSYBOX=.*/BUSYBOX=y/' "${root_dir}/etc/initramfs-tools/initramfs.conf"
        display_alert "overlayroot" "Set BUSYBOX=y in initramfs.conf" "info"
    else
        display_alert "overlayroot" "initramfs.conf not found" "warn"
    fi

    # Modify overlayroot in /etc/overlayroot.conf
    if [[ -f "${root_dir}/etc/overlayroot.conf" ]]; then
        sed -i 's/^overlayroot=.*/overlayroot="device:dev=LABEL=armbi_usrdata"/' "${root_dir}/etc/overlayroot.conf"
        display_alert "overlayroot" "Set overlayroot in /etc/overlayroot.conf" "info"
    else
        display_alert "overlayroot" "/etc/overlayroot.conf not found" "warn"
    fi
}

function pre_umount_final_image__896_install_resize_userdata_service() {
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "A/B partition OTA" "Installing armbian-resize-userdata service" "info"
    local root_dir="${MOUNT}"
    local ota_ext_dir
    ota_ext_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    mkdir -p "${root_dir}/etc/systemd/system" "${root_dir}/usr/lib/armbian"

    cp "${ota_ext_dir}/ab_ota/systemd/armbian-resize-userdata.service" "${root_dir}/etc/systemd/system/" || {
        display_alert "A/B partition OTA" "Failed to copy armbian-resize-userdata.service" "err"
        return 1
    }
    cp "${ota_ext_dir}/ab_ota/userspace/armbian-resize-userdata" "${root_dir}/usr/lib/armbian/" || {
        display_alert "A/B partition OTA" "Failed to copy armbian-resize-userdata script" "err"
        return 1
    }
    chmod +x "${root_dir}/usr/lib/armbian/armbian-resize-userdata"

    chroot "${root_dir}" systemctl enable armbian-resize-userdata.service || {
        display_alert "A/B partition OTA" "Failed to enable armbian-resize-userdata.service" "warn"
    }

    return 0
}

# Function to install AB OTA manager and related tools
function pre_umount_final_image__895_install_ab_ota_tools() {
    if [[ "${OTA_ENABLE}" != "yes" ]]; then
        return 0
    fi

    local root_dir="${MOUNT}"
    local ota_ext_dir
    ota_ext_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    mkdir -p "${root_dir}/usr/sbin" "${root_dir}/usr/lib/armbian" "${root_dir}/etc/systemd/system"

    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "A/B partition OTA" "Installing AB OTA userspace tools" "info"
        local ab_ota_src="${ota_ext_dir}/ab_ota"

        cp "${ab_ota_src}/userspace/armbian-ota-manager" "${root_dir}/usr/sbin/armbian-ota-manager" || {
            display_alert "A/B partition OTA" "Failed to install armbian-ota-manager wrapper" "err"
            return 1
        }
        cp "${ab_ota_src}/userspace/armbian-ota-health-check" "${root_dir}/usr/lib/armbian/armbian-ota-health-check" || {
            display_alert "A/B partition OTA" "Failed to install armbian-ota-health-check" "err"
            return 1
        }
        cp "${ab_ota_src}/userspace/armbian-ota-init-uboot" "${root_dir}/usr/lib/armbian/armbian-ota-init-uboot" || {
            display_alert "A/B partition OTA" "Failed to install armbian-ota-init-uboot" "err"
            return 1
        }
        chmod +x "${root_dir}/usr/sbin/armbian-ota-manager" "${root_dir}/usr/lib/armbian/armbian-ota-health-check" "${root_dir}/usr/lib/armbian/armbian-ota-init-uboot"

        local services=(
            "armbian-ota-init-uboot.service"
            "armbian-ota-firstboot.service"
            "armbian-ota-mark-success.service"
            "armbian-ota-rollback.service"
        )
        local svc
        for svc in "${services[@]}"; do
            cp "${ab_ota_src}/systemd/${svc}" "${root_dir}/etc/systemd/system/${svc}" || {
                display_alert "A/B partition OTA" "Failed to install ${svc}" "warn"
            }
        done

        chroot "${root_dir}" systemctl enable armbian-ota-init-uboot.service || display_alert "A/B partition OTA" "Failed to enable armbian-ota-init-uboot.service" "warn"
        chroot "${root_dir}" systemctl enable armbian-ota-firstboot.service || display_alert "A/B partition OTA" "Failed to enable armbian-ota-firstboot.service" "warn"
        chroot "${root_dir}" systemctl enable armbian-ota-mark-success.service || display_alert "A/B partition OTA" "Failed to enable armbian-ota-mark-success.service" "warn"
    else
        display_alert "Recovery OTA" "Installing recovery OTA userspace tools" "info"
        local recovery_src="${ota_ext_dir}/recovery_ota"

        cp "${recovery_src}/armbian-ota-manager" "${root_dir}/usr/sbin/armbian-ota-manager" || {
            display_alert "Recovery OTA" "Failed to install armbian-ota-manager wrapper" "err"
            return 1
        }
        cp "${recovery_src}/start_prepare_ota.sh" "${root_dir}/usr/sbin/start_prepare_ota.sh" || {
            display_alert "Recovery OTA" "Failed to install start_prepare_ota.sh wrapper" "err"
            return 1
        }
        chmod +x "${root_dir}/usr/sbin/armbian-ota-manager" "${root_dir}/usr/sbin/start_prepare_ota.sh"
    fi

    return 0
}

# 扩容userdata分区
# sudo apt-get install overlayroot
# sudo apt install busybox-static
# /etc/initramfs-tools/initramfs.conf ---> BUSYBOX=y
# /etc/overlayroot.conf ---> overlayroot="device:dev=LABEL=armbi_usrdata"
