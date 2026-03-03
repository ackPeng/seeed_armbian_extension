
function pre_update_initramfs__300_optee_inject() {
    local RK_SDK_TOOLS="${SRC}/cache/sources/rockchip_sdk_tools"
    if [[ ! -d "${RK_SDK_TOOLS}" ]]; then
        display_alert "optee" "rockchip_sdk_tools source directory not found, downloading" "info"
        fetch_from_repo "${RKBIN_GIT_URL:-"https://github.com/ackPeng/rockchip_sdk_tools.git"}" "rockchip_sdk_tools" "branch:${RKSDK_TOOLS_BRANCH:-"main"}"
    fi

    apt-get install -y python3-pycryptodome
    # Inject OP-TEE related binaries and TAs before generating initrd, and create initramfs hooks.
    local root_dir="${MOUNT}"
    [[ -d "${root_dir}" ]] || { display_alert "optee" "root_dir does not exist: ${root_dir}" "err"; return 0; }

    display_alert "optee" "Installing OP-TEE client from library" "info"

    # Install tee-supplicant and libteec.so from cache
    local optee_bin_dir="${RK_SDK_TOOLS}/external/security/bin/optee_v2/lib/arm64"

    if [[ -d "${optee_bin_dir}" ]]; then
        mkdir -p "${root_dir}/usr/bin" || { display_alert "optee" "Failed to create usr/bin" "err"; return 0; }
        mkdir -p "${root_dir}/usr/lib" || { display_alert "optee" "Failed to create usr/lib" "err"; return 0; }

        install -m 0755 "${optee_bin_dir}/tee-supplicant" "${root_dir}/usr/bin/tee-supplicant" 
        install -m 0644 "${optee_bin_dir}/libteec.so" "${root_dir}/usr/lib/libteec.so" 
        install -m 0644 "${optee_bin_dir}/libteec.so.1" "${root_dir}/usr/lib/libteec.so.1"
        install -m 0644 "${optee_bin_dir}/libteec.so.1.0" "${root_dir}/usr/lib/libteec.so.1.0"
        install -m 0644 "${optee_bin_dir}/libteec.so.1.0.0" "${root_dir}/usr/lib/libteec.so.1.0.0"
    else
        display_alert "optee" "OP-TEE client binary directory not found: ${optee_bin_dir}" "err"
        return 1
    fi

    # Compile rk_tee_user_v2
    display_alert "optee" "Starting compilation of rk_tee_user_v2" "info"

    local rk_tee_build_dir="${RK_SDK_TOOLS}/external/security/rk_tee_user/v2"

    if [[ ! -d "${rk_tee_build_dir}" ]]; then
        display_alert "optee" "rk_tee_user_v2 source directory not found: ${rk_tee_build_dir}" "err"
        return 1
    fi

    cd "${rk_tee_build_dir}" || { display_alert "optee" "Cannot enter rk_tee_user_v2 directory: ${rk_tee_build_dir}" "err"; return 1; }

    # Execute compilation
    ./build.sh 6432  || {
        display_alert "optee" "rk_tee_user_v2 compilation failed" "err"
        return 1
    }

    # Check build artifacts
    local keybox_app_path="${rk_tee_build_dir}/out/extra_app/keybox_app"
    local ta_file_path="${rk_tee_build_dir}/out/ta/extra_app/8c6cf810-685d-4654-ae71-8031beee467e.ta"

    if [[ ! -f "${keybox_app_path}" ]]; then
        display_alert "optee" "keybox_app not found: ${keybox_app_path}" "warn"
    fi

    if [[ ! -f "${ta_file_path}" ]]; then
        display_alert "optee" "TA file not found: ${ta_file_path}" "warn"
    fi

    display_alert "optee" "rk_tee_user_v2 compiled successfully" "info"

    # Install TA files
    mkdir -p "${root_dir}/lib/optee_armtz" || display_alert "optee" "Failed to create optee_armtz" "err"
    install -m 0755 "${keybox_app_path}" "${root_dir}/usr/bin/keybox_app"
    install -m 0644 "${ta_file_path}" "${root_dir}/lib/optee_armtz/8c6cf810-685d-4654-ae71-8031beee467e.ta"

    display_alert "optee" "OP-TEE client installation completed" "info"

    # Install initramfs hook to ensure OP-TEE components are available in initramfs
    display_alert "optee" "Installing install-optee initramfs hook" "info"

    # # Create initramfs hooks directory
    # mkdir -p "${root_dir}/etc/initramfs-tools/hooks"

    # Copy install-optee hook file
    local hook_src="${SRC}/extensions/rk_secure-disk-encryption/auto-decryption-config/install-optee"
    local hook_dst="${root_dir}/etc/initramfs-tools/hooks/install-optee"

    if [[ -f "${hook_src}" ]]; then
        cp "${hook_src}" "${hook_dst}" || {
            display_alert "optee" "Failed to copy install-optee hook" "err"
            return 1
        }
        chmod +x "${hook_dst}"
        display_alert "optee" "install-optee hook installation completed" "info"
    else
        display_alert "optee" "install-optee source file not found: ${hook_src}" "warn"
    fi

    # Copy decryption-disk.sh script to initramfs
    display_alert "optee" "Installing decryption-disk script" "info"

    # # Create init-top directory
    # mkdir -p "${root_dir}/etc/initramfs-tools/scripts/init-top"

    # Copy decryption-disk.sh script
    local decryption_src="${SRC}/extensions/rk_secure-disk-encryption/auto-decryption-config/decryption-disk.sh"
    local decryption_dst="${root_dir}/etc/initramfs-tools/scripts/init-top/0-decryption-disk"

    if [[ -f "${decryption_src}" ]]; then
        cp "${decryption_src}" "${decryption_dst}" || {
            display_alert "optee" "Failed to copy decryption-disk script" "err"
            return 1
        }
        chmod +x "${decryption_dst}"
        display_alert "optee" "decryption-disk script installation completed" "info"
    else
        display_alert "optee" "decryption-disk.sh source file not found: ${decryption_src}" "warn"
    fi
}


function pre_umount_final_image__cleanup_optee_components() {
    # Clean up OP-TEE components from rootfs after initramfs is generated
    # These are sensitive components that should not remain in the final root filesystem
    display_alert "optee" "Cleaning up OP-TEE components from rootfs" "info"

    local root_dir="${MOUNT}"
    [[ -d "${root_dir}" ]] || return 0

    # Remove keybox_app
    if [[ -f "${root_dir}/usr/bin/keybox_app" ]]; then
        rm -f "${root_dir}/usr/bin/keybox_app"
        display_alert "optee" "Removed keybox_app from rootfs" "debug"
    fi

    # Remove OP-TEE TA files
    if [[ -d "${root_dir}/lib/optee_armtz" ]]; then
        rm -rf "${root_dir}/lib/optee_armtz"
        display_alert "optee" "Removed optee_armtz directory from rootfs" "debug"
    fi

    # Remove tee-supplicant
    if [[ -f "${root_dir}/usr/bin/tee-supplicant" ]]; then
        rm -f "${root_dir}/usr/bin/tee-supplicant"
        display_alert "optee" "Removed tee-supplicant from rootfs" "debug"
    fi

    # Remove libteec libraries
    for lib in "${root_dir}/usr/lib"/libteec.so*; do
        if [[ -f "$lib" ]]; then
            rm -f "$lib"
        fi
    done
    display_alert "optee" "Removed libteec libraries from rootfs" "debug"

    display_alert "optee" "OP-TEE components cleanup completed" "info"
}


function pre_prepare_partitions__secure_storage_partitions() {
	USE_HOOK_FOR_PARTITION="yes"
	SECURE_STORAGE_SECURITY_SIZE=${SECURE_STORAGE_SECURITY_SIZE:-4}
	SECURE_STORAGE_SECURITY_FS_TYPE=${SECURE_STORAGE_SECURITY_FS_TYPE:-none}
	display_alert "secure-storage" " security(${SECURE_STORAGE_SECURITY_SIZE}MiB) partitions" "info"
}

function create_partition_table__secure_storage() {

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
	# /boot (XBOOTLDR)
	if [[ -n "${BOOTSIZE}" && ${BOOTSIZE} -gt 0 && ( -n "${BOOTFS_TYPE}" || "${BOOTPART_REQUIRED}" == "yes" ) ]]; then
		local boot_type="BC13C2FF-59E6-4262-A352-B275FD6F7172"
		script+="${p_index} : name=\"boot\", start=${next}MiB, size=${BOOTSIZE}MiB, type=${boot_type}\n"
		next=$((next + BOOTSIZE)); p_index=$((p_index+1))
	fi
	# security partition
	local sec_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
	script+="${p_index} : name=\"security\", start=${next}MiB, size=${SECURE_STORAGE_SECURITY_SIZE}MiB, type=${sec_type}\n"
	next=$((next + SECURE_STORAGE_SECURITY_SIZE)); local security_part_index=${p_index}; p_index=$((p_index+1))
	# rootfs remaining space
	local root_type
	if [[ "${IMAGE_PARTITION_TABLE}" == "gpt" ]]; then
		root_type="${PARTITION_TYPE_UUID_ROOT:-0FC63DAF-8483-4772-8E79-3D69D8477DE4}" # Use generic Linux guid if not defined
	else
		root_type="83"
	fi
	script+="${p_index} : name=\"rootfs\", start=${next}MiB, type=${root_type}\n"
	# Update rootpart sequence number for subsequent logic
	rootpart=${p_index}

	display_alert "secure-storage" "Custom partition table:\n${script}" "debug"
	echo -e "${script}" | run_host_command_logged sfdisk ${SDCARD}.raw || exit_with_error "secure-storage partition creation failed" "sfdisk"

	SECURE_STORAGE_SECURITY_PART_INDEX=${security_part_index}
}


function format_partitions__secure_storage() {
	# security partition remains raw unless user specifies FS type
	if [[ -n "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]]; then
		local sec_dev="${LOOP}p${SECURE_STORAGE_SECURITY_PART_INDEX}"
		check_loop_device "${sec_dev}" || true

		# Format if filesystem type is specified
		if [[ "${SECURE_STORAGE_SECURITY_FS_TYPE}" != "none" ]]; then
			display_alert "secure-storage" "mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} on security (${sec_dev})" "info"
			if command -v mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} >/dev/null 2>&1; then
				mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} -q "${sec_dev}" || display_alert "secure-storage" "security mkfs failed" "err"
			else
				display_alert "secure-storage" "mkfs.${SECURE_STORAGE_SECURITY_FS_TYPE} not found" "err"
			fi
		fi

		# Write password to security partition (only if cryptroot is enabled)
		if [[ "${CRYPTROOT_ENABLE}" == "yes" && -n "${CRYPTROOT_PASSPHRASE}" ]]; then
			display_alert "secure-storage" "Writing CRYPTROOT_PASSPHRASE to security partition" "info"
			# Ensure device exists
			if [[ -b "${sec_dev}" ]]; then
				# Wait for device to be ready
				wait_for_disk_sync "before writing to security partition"

				# Use printf to write directly, avoiding temporary files
				printf "%s" "${CRYPTROOT_PASSPHRASE}" | dd of="${sec_dev}" bs=1 count="${#CRYPTROOT_PASSPHRASE}" conv=fsync 2>/dev/null || {
					display_alert "secure-storage" "Failed to write password to security partition" "err"
					return 1
				}

				# Verify write
				sleep 1
				local read_back=$(dd if="${sec_dev}" bs="${#CRYPTROOT_PASSPHRASE}" count=1 2>/dev/null)
				if [[ "$read_back" == "${CRYPTROOT_PASSPHRASE}" ]]; then
					display_alert "secure-storage" "Password written and verified successfully" "info"
				else
					display_alert "secure-storage" "Password write verification failed" "warn"
					display_alert "secure-storage" "Expected: ${CRYPTROOT_PASSPHRASE}" "debug"
					display_alert "secure-storage" "Actual: ${read_back}" "debug"
				fi

				# Multiple syncs to ensure data is written to disk
				sync
				sync
				blockdev --flushbufs "${sec_dev}" 2>/dev/null || true
			else
				display_alert "secure-storage" "Security partition device does not exist: ${sec_dev}" "err"
				# List available partition devices
				display_alert "secure-storage" "Available partitions: $(ls -la ${LOOP}p* 2>/dev/null || echo 'None')" "debug"
			fi
		fi
	fi
}

