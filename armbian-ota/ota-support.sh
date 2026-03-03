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
    if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
        secure_boot_and_decrypt="yes"
        display_alert "Secure boot and auto ota enabled" "Using FIT image workflow" "info"
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

        # Ensure at least rootfs partition exists
        if [[ -z "$rootfs_partition" ]]; then
            display_alert "Error: Could not identify rootfs partition" "" "err"
            return 1
        fi
    fi

    # Get partition information
    local boot_size=0
    local rootfs_size=0

    if [[ "$secure_boot_and_decrypt" != "yes" ]]; then
        rootfs_size=$(blockdev --getsize64 "$rootfs_partition" 2>/dev/null || echo "0")
        if [[ -n "$boot_partition" ]]; then
            boot_size=$(blockdev --getsize64 "$boot_partition" 2>/dev/null || echo "0")
        fi
        display_alert "Found partitions" "boot: ${boot_partition:-"none"} (${boot_size} bytes), rootfs: ${rootfs_partition} (${rootfs_size} bytes)" "info"
    else
        display_alert "Secure boot mode active" "Using boot.itb and encrypted rootfs" "info"
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

    # For AB partition OTA, don't include armbian_ota_tools (manager is already installed)
    # For recovery OTA, include the tools
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        local tools_source_dir="${SRC}/extensions/armbian-ota/armbian_ota_tools"
        if [[ -d "$tools_source_dir" ]]; then
            cp -r "$tools_source_dir" "$ota_temp_dir/" || {
                display_alert "Error: Failed to copy arbian_ota_tools" "$tools_source_dir" "err"
                rm -rf "$ota_temp_dir"
                return 1
            }
            display_alert "Copied OTA tools" "armbian_ota_tools -> ${ota_package_name}" "info"
        else
            display_alert "Warning: armbian_ota_tools directory not found" "$tools_source_dir" "warn"
        fi
    else
        display_alert "AB partition OTA" "Skipping armbian_ota_tools (manager already installed in image)" "info"
    fi

    # Create version info file for armbian-ota-manager
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
        echo "- version.txt: Version information for armbian-ota-manager" >> "$manifest_file"
    fi
    if [[ "${AB_PART_OTA}" != "yes" && -d "${SRC}/extensions/armbian-ota/armbian_ota_tools" ]]; then
        echo "- arbian_ota_tools/: OTA update tools and utilities" >> "$manifest_file"
    fi

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
    
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
    
        local secure_config_dir="${SRC}/extensions/rk_secure-disk-encryption/secure-boot-config"
        if compgen -G "${secure_config_dir}"/*.patch > /dev/null; then
            display_alert "A/B partition OTA" "Applying secure boot patches" "info"
            local patch_applied=0
            local patch_failed=0
            for patch_file in "${secure_config_dir}"/*.patch; do
                [[ -f "${patch_file}" ]] || continue
                local patch_name
                patch_name=$(basename "${patch_file}")

                # Check if patch can be applied
                if git apply --check "${patch_file}" 2>/dev/null; then
                    if git apply "${patch_file}"; then
                        patch_applied=$((patch_applied + 1))
                        display_alert "A/B partition OTA" "Patch applied: ${patch_name}" "debug"
                    else
                        patch_failed=$((patch_failed + 1))
                        display_alert "A/B partition OTA" "Failed to apply patch: ${patch_name}" "err"
                    fi
                else
                    # Fallback to patch(1)
                    if patch -p1 < "${patch_file}" 2>/dev/null; then
                        patch_applied=$((patch_applied + 1))
                    else
                        patch_failed=$((patch_failed + 1))
                        display_alert "A/B partition OTA" "Patch application failed (patch): ${patch_name}" "err"
                    fi
                fi
            done

            display_alert "A/B partition OTA" "Patch application completed: Success=${patch_applied} Failed=${patch_failed}" "info"
        fi

        display_alert "A/B partition OTA" "Building fw_env tool from u-boot source" "info"
        local RK_SDK_TOOLS="${SRC}/cache/sources/rockchip_sdk_tools"
        if [[ ! -d "${RK_SDK_TOOLS}" ]]; then
            display_alert "optee" "rockchip_sdk_tools source directory not found, downloading" "info"
            fetch_from_repo "${RKBIN_GIT_URL:-"https://github.com/ackPeng/rockchip_sdk_tools.git"}" "rockchip_sdk_tools" "branch:${RKSDK_TOOLS_BRANCH:-"main"}"
        fi
        local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
        local prebuilts_source="${RK_SDK_TOOLS}/external/prebuilts"
        local Prebuilts_toolchain_dir="${uboot_src}/../prebuilts"
        if [[ ! -d "${Prebuilts_toolchain_dir}" ]]; then
            cp -rf "${prebuilts_source}" "${Prebuilts_toolchain_dir}" || {
                display_alert "A/B partition OTA" "Failed to copy prebuilts" "err"
                return 1
            }
        fi

        local rkbin_source="${RK_SDK_TOOLS}/rkbin"
        local Rkbin_toolchain_dir="${uboot_src}/../rkbin"
        if [[ ! -d "${Rkbin_toolchain_dir}" ]]; then
            cp -rf "${rkbin_source}" "${Rkbin_toolchain_dir}" || {
                display_alert "A/B partition OTA" "Failed to copy rkbin" "err"
                return 1
            }
        fi

        cd "${uboot_src}" || {
            display_alert "A/B partition OTA" "Failed to enter u-boot source directory" "err"
            return 1
        }
        bash ./make.sh env || {
            display_alert "A/B partition OTA" "Failed to build fw_env tool" "err"
            return 1
        }

    fi
}

function pre_umount_final_image__899_install_fw_env_tool() {
    if [[ "${AB_PART_OTA}" == "yes" ]]; then

        display_alert "A/B partition OTA" "Installing fw_env tool into rootfs" "info"
        local root_dir="${MOUNT}"
        local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
        local fw_env_src="${uboot_src}/tools/env/fw_printenv"
        local fw_printenv="${root_dir}/usr/bin/fw_printenv"
        local fw_setenv="${root_dir}/usr/bin/fw_setenv"
        local fw_env_config="${root_dir}/etc/fw_env.config"
        if [[ -f "${fw_env_src}" ]]; then
            cp "${fw_env_src}" "${fw_printenv}" || {
                display_alert "A/B partition OTA" "Failed to copy fw_printenv tool" "err"
                return 1
            }
            cp "${fw_env_src}" "${fw_setenv}" || {
                display_alert "A/B partition OTA" "Failed to copy fw_setenv tool" "err"
                return 1
            }
            echo -e "/dev/mtdblock0 0x3f8000 0x8000" > "${fw_env_config}" || {
                display_alert "A/B partition OTA" "Failed to create fw_env.config file" "err"
                return 1
            }
            display_alert "A/B partition OTA" "fw_env tool installation completed" "info"
        else
            display_alert "A/B partition OTA" "fw_env source file not found: ${fw_env_src}" "warn"
        fi
    fi
}

function pre_prepare_partitions__ab_part_ota() {
	if [[ "${AB_PART_OTA}" == "yes" ]]; then
		USE_HOOK_FOR_PARTITION="yes"
		AB_BOOT_SIZE=${AB_BOOT_SIZE:-256}  # 256MiB for each boot partition
		AB_ROOTFS_SIZE=${AB_ROOTFS_SIZE:-4608}  # 4.5GiB for each rootfs partition
        USERDATA=${USERDATA:-256}  # userdata partition by default
        BOOTFS_TYPE="ext4"
        ROOTFS_TYPE="ext4"
        ROOT_FS_LABEL="armbi_roota"
        BOOT_FS_LABEL="armbi_boota"
		display_alert "A/B partition OTA" "Creating A/B partitions: boot_a, boot_b, rootfs_a, rootfs_b" "info"
	fi
}

function create_partition_table__ab_part_ota() {
	if [[ "${AB_PART_OTA}" != "yes" ]]; then
		return 0
	fi

	local next=${OFFSET} # Starting MiB
	local p_index=1
	local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"

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
		display_alert "A/B partition OTA" "Formatting rootfs_b (${rootfs_b_dev}) as ext4 with label armbi_rootb" "info"
		run_host_command_logged mkfs.ext4 -q -L armbi_rootb "${rootfs_b_dev}" || display_alert "A/B partition OTA" "Failed to format rootfs_b" "warn"
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
		FIXED_IMAGE_SIZE=$(((AB_ROOTFS_SIZE * 2) + $OFFSET + (AB_BOOT_SIZE * 2) + $UEFISIZE + $EXTRA_ROOTFS_MIB_SIZE + $USERDATA)) # MiB
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
    if [[ "${AB_PART_OTA}" == "yes" ]]; then
        display_alert "A/B partition OTA" "Installing armbian-resize-userdata service" "info"
        local root_dir="${MOUNT}"

        # Copy service file
        cp "${SRC}/extensions/armbian-ota/ab_ota/systemd/armbian-resize-userdata.service" "${root_dir}/etc/systemd/system/" || {
            display_alert "A/B partition OTA" "Failed to copy armbian-resize-userdata.service" "err"
            return 1
        }

        # Copy script
        cp "${SRC}/extensions/armbian-ota/ab_ota/userspace/armbian-resize-userdata" "${root_dir}/usr/lib/armbian/" || {
            display_alert "A/B partition OTA" "Failed to copy armbian-resize-userdata script" "err"
            return 1
        }
        chmod +x "${root_dir}/usr/lib/armbian/armbian-resize-userdata"

        # Enable service
        chroot "${root_dir}" systemctl enable armbian-resize-userdata.service || {
            display_alert "A/B partition OTA" "Failed to enable armbian-resize-userdata.service" "err"
            return 1
        }

        display_alert "A/B partition OTA" "armbian-resize-userdata service installed and enabled" "info"
    fi
}

# Function to install AB OTA manager and related tools
function pre_umount_final_image__895_install_ab_ota_tools() {
    if [[ "${AB_PART_OTA}" != "yes" ]]; then
        return 0
    fi

    display_alert "A/B partition OTA" "Installing AB OTA manager and tools" "info"
    local root_dir="${MOUNT}"
    local ab_ota_src="${SRC}/extensions/armbian-ota/ab_ota"

    # Create directories
    mkdir -p "${root_dir}/usr/sbin"
    mkdir -p "${root_dir}/usr/lib/armbian"
    mkdir -p "${root_dir}/usr/share/armbian-ota"
    mkdir -p "${root_dir}/etc/systemd/system"

    # Copy armbian-ota-manager
    if [[ -f "${ab_ota_src}/userspace/armbian-ota-manager" ]]; then
        cp "${ab_ota_src}/userspace/armbian-ota-manager" "${root_dir}/usr/sbin/" || {
            display_alert "A/B partition OTA" "Failed to copy armbian-ota-manager" "err"
            return 1
        }
        chmod +x "${root_dir}/usr/sbin/armbian-ota-manager"
        display_alert "A/B partition OTA" "Installed armbian-ota-manager" "info"
    else
        display_alert "A/B partition OTA" "armbian-ota-manager not found at ${ab_ota_src}/userspace/armbian-ota-manager" "warn"
    fi

    # Copy health-check script
    if [[ -f "${ab_ota_src}/userspace/armbian-ota-health-check" ]]; then
        cp "${ab_ota_src}/userspace/armbian-ota-health-check" "${root_dir}/usr/lib/armbian/" || {
            display_alert "A/B partition OTA" "Failed to copy armbian-ota-health-check" "err"
            return 1
        }
        chmod +x "${root_dir}/usr/lib/armbian/armbian-ota-health-check"
        display_alert "A/B partition OTA" "Installed armbian-ota-health-check" "info"
    fi

    # Copy init-uboot script
    if [[ -f "${ab_ota_src}/userspace/armbian-ota-init-uboot" ]]; then
        cp "${ab_ota_src}/userspace/armbian-ota-init-uboot" "${root_dir}/usr/lib/armbian/" || {
            display_alert "A/B partition OTA" "Failed to copy armbian-ota-init-uboot" "err"
            return 1
        }
        chmod +x "${root_dir}/usr/lib/armbian/armbian-ota-init-uboot"
        display_alert "A/B partition OTA" "Installed armbian-ota-init-uboot" "info"
    fi

    # Copy common.sh library
    if [[ -f "${ab_ota_src}/userspace/lib/common.sh" ]]; then
        cp "${ab_ota_src}/userspace/lib/common.sh" "${root_dir}/usr/share/armbian-ota/" || {
            display_alert "A/B partition OTA" "Failed to copy common.sh" "err"
            return 1
        }
        display_alert "A/B partition OTA" "Installed common.sh library" "info"
    fi

    # Copy systemd services
    local services=(
        "armbian-ota-init-uboot.service"
        "armbian-ota-firstboot.service"
        "armbian-ota-mark-success.service"
        "armbian-ota-rollback.service"
    )

    for svc in "${services[@]}"; do
        if [[ -f "${ab_ota_src}/systemd/${svc}" ]]; then
            cp "${ab_ota_src}/systemd/${svc}" "${root_dir}/etc/systemd/system/" || {
                display_alert "A/B partition OTA" "Failed to copy ${svc}" "warn"
                continue
            }
            display_alert "A/B partition OTA" "Installed ${svc}" "info"
        fi
    done

    # Enable init-uboot service (runs once on first boot)
    chroot "${root_dir}" systemctl enable armbian-ota-init-uboot.service || {
        display_alert "A/B partition OTA" "Failed to enable armbian-ota-init-uboot.service" "warn"
    }

    # Enable firstboot and mark-success services
    chroot "${root_dir}" systemctl enable armbian-ota-firstboot.service || {
        display_alert "A/B partition OTA" "Failed to enable armbian-ota-firstboot.service" "warn"
    }
    chroot "${root_dir}" systemctl enable armbian-ota-mark-success.service || {
        display_alert "A/B partition OTA" "Failed to enable armbian-ota-mark-success.service" "warn"
    }
    # NOTE: rollback service is NOT enabled - it only runs via OnFailure trigger
    display_alert "A/B partition OTA" "rollback.service installed (not enabled, triggered by OnFailure)" "info"

    display_alert "A/B partition OTA" "AB OTA tools installation completed" "info"
}

# 扩容userdata分区
# sudo apt-get install overlayroot
# sudo apt install busybox-static
# /etc/initramfs-tools/initramfs.conf ---> BUSYBOX=y
# /etc/overlayroot.conf ---> overlayroot="device:dev=LABEL=armbi_usrdata"