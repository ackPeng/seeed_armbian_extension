function rk_auto_decryption_enable_optee_bootchain() {
    if [[ "${CRYPTROOT_ENABLE}" != "yes" || "${RK_AUTO_DECRYP}" != "yes" ]]; then
        return 0
    fi

    if [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]]; then
        return 0
    fi

    if [[ "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
        return 0
    fi

    display_alert "OP-TEE bootchain" "Enable OP-TEE boot chain for encrypted auto-decryption without secure boot" "info"
    export RK_OPTEE_BOOT_ENABLE=yes
}

rk_auto_decryption_enable_optee_bootchain


function rk_autodecrypt_nonsecure_mode_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" ]]
}

function rk_autodecrypt_detect_vendor_board() {
    if [[ -n "${UBOOT_VENDOR_BOARD}" ]]; then
        echo "${UBOOT_VENDOR_BOARD}"
        return 0
    fi

    local boot_soc
    boot_soc="$(echo "${BOOT_SOC}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${boot_soc}" == *"3576"* ]]; then
        echo "recomputer-rk3576-devkit"
    else
        echo "recomputer-rk3588-devkit"
    fi
}

function rk_autodecrypt_copy_secure_boot_defconfig() {
    local vendor_board="$1"
    local target_defconfig="configs/${vendor_board}_defconfig"
    local script_dir candidate src_defconfig

    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    src_defconfig=""

    for candidate in \
        "${script_dir}/secure-boot-config/rk3588-config/${vendor_board}_defconfig" \
        "${script_dir}/secure-boot-config/rk3576-config/${vendor_board}_defconfig" \
        "${script_dir}/secure-boot-config/defconfig/${vendor_board}_defconfig"; do
        if [[ -f "${candidate}" ]]; then
            src_defconfig="${candidate}"
            break
        fi
    done

    if [[ -z "${src_defconfig}" ]]; then
        return 1
    fi

    cp -f "${src_defconfig}" "${target_defconfig}" || return 1
    display_alert "optee-autodecrypt" "Applied secure-boot-config defconfig fallback: $(basename "${src_defconfig}") -> ${target_defconfig}" "info"
    return 0
}

function rk_autodecrypt_disable_fit_signature_in_defconfig() {
    local target_defconfig="$1"
    local disable_list="${RK_AUTODECRYPT_DISABLE_CONFIGS:-CONFIG_FIT_SIGNATURE}"
    local symbol

    if [[ ! -f "${target_defconfig}" ]]; then
        return 1
    fi

    for symbol in ${disable_list}; do
        if [[ -x scripts/config ]]; then
            if [[ "$(type -t run_host_command_logged || true)" == "function" ]]; then
                run_host_command_logged scripts/config --file "${target_defconfig}" --set-val "${symbol}" n || return 1
            else
                scripts/config --file "${target_defconfig}" --set-val "${symbol}" n || return 1
            fi
            continue
        fi

        # Fallback when scripts/config is unavailable in the current u-boot tree.
        if grep -q "^${symbol}=" "${target_defconfig}"; then
            sed -i "s/^${symbol}=.*/${symbol}=n/" "${target_defconfig}" || return 1
        elif grep -q "^# ${symbol} is not set" "${target_defconfig}"; then
            :
        else
            printf "%s=n\n" "${symbol}" >> "${target_defconfig}" || return 1
        fi
    done

    display_alert "optee-autodecrypt" "Disabled configs in ${target_defconfig}: ${disable_list}" "info"
    return 0
}

function rk_autodecrypt_prepare_defconfig_for_current_tree() {
    local vendor_board target_defconfig
    vendor_board="$(rk_autodecrypt_detect_vendor_board)"
    target_defconfig="configs/${vendor_board}_defconfig"

    # Rule:
    # 1) if a dedicated trim hook exists, use it.
    # 2) otherwise fallback to secure-boot-config defconfig.
    if [[ "$(type -t rk_autodecrypt_uboot_defconfig_trim_hook || true)" == "function" ]]; then
        rk_autodecrypt_uboot_defconfig_trim_hook "${target_defconfig}" ||
            exit_with_error "auto-decrypt defconfig trim hook failed" "${target_defconfig}"
        display_alert "optee-autodecrypt" "Applied custom defconfig trim hook: rk_autodecrypt_uboot_defconfig_trim_hook" "info"
        rk_autodecrypt_disable_fit_signature_in_defconfig "${target_defconfig}" ||
            exit_with_error "failed to disable CONFIG_FIT_SIGNATURE" "${target_defconfig}"
        return 0
    fi

    rk_autodecrypt_copy_secure_boot_defconfig "${vendor_board}" ||
        exit_with_error "auto-decrypt defconfig fallback failed" "vendor_board=${vendor_board} secure-boot-config"
    rk_autodecrypt_disable_fit_signature_in_defconfig "${target_defconfig}" ||
        exit_with_error "failed to disable CONFIG_FIT_SIGNATURE" "${target_defconfig}"
}

function rk_autodecrypt_install_patch_uboot_target_wrapper() {
    if [[ "$(type -t patch_uboot_target || true)" != "function" ]]; then
        display_alert "optee-autodecrypt" "patch_uboot_target not found, cannot install post-patch defconfig hook" "warn"
        return 0
    fi

    if [[ "$(type -t __rk_autodecrypt_patch_uboot_target_original || true)" == "function" ]]; then
        return 0
    fi

    eval "$(declare -f patch_uboot_target | sed '1s/^patch_uboot_target/__rk_autodecrypt_patch_uboot_target_original/')"
    patch_uboot_target() {
        __rk_autodecrypt_patch_uboot_target_original "$@" || return $?

        if [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" && "${RK_SECURE_UBOOT_ENABLE}" != "yes" && "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]; then
            rk_autodecrypt_prepare_defconfig_for_current_tree
        fi
    }

    display_alert "optee-autodecrypt" "Installed post-patch defconfig hook wrapper on patch_uboot_target" "info"
}

function build_custom_uboot__100_autodecrypt_prepare_defconfig() {
    if ! rk_autodecrypt_nonsecure_mode_enabled; then
        return 0
    fi

    if [[ "${RK_OPTEE_BOOT_ENABLE}" != "yes" ]]; then
        return 0
    fi

    rk_autodecrypt_install_patch_uboot_target_wrapper
    rk_autodecrypt_prepare_defconfig_for_current_tree
}
function rk_autodecrypt_refresh_boot_scr_from_boot_cmd() {
    local boot_cmd="$1"
    local boot_scr="$2"
    local mkimage_bin="${RK_AUTODECRYPT_MKIMAGE_BIN:-}"
    local candidate

    if [[ ! -f "${boot_cmd}" ]]; then
        return 1
    fi

    if [[ -z "${mkimage_bin}" ]]; then
        for candidate in \
            "$(command -v mkimage 2>/dev/null || true)" \
            "${SRC}/cache/sources/${BOOTSOURCEDIR}/tools/mkimage"; do
            [[ -n "${candidate}" && -x "${candidate}" ]] || continue
            mkimage_bin="${candidate}"
            break
        done
    fi

    [[ -n "${mkimage_bin}" ]] ||
        exit_with_error "mkimage not found for boot.cmd -> boot.scr regeneration" "${boot_cmd}"

    if [[ "$(type -t run_host_command_logged || true)" == "function" ]]; then
        run_host_command_logged "${mkimage_bin}" -C none -A arm -T script -d "${boot_cmd}" "${boot_scr}" ||
            exit_with_error "failed to regenerate boot.scr from boot.cmd" "${boot_scr}"
    else
        "${mkimage_bin}" -C none -A arm -T script -d "${boot_cmd}" "${boot_scr}" ||
            exit_with_error "failed to regenerate boot.scr from boot.cmd" "${boot_scr}"
    fi

    display_alert "optee-autodecrypt" "Regenerated boot.scr from boot.cmd via mkimage" "info"
    return 0
}

function pre_umount_final_image__120_adjust_boot_cmd_load_addr_for_autodecrypt() {
    if ! rk_autodecrypt_nonsecure_mode_enabled; then
        return 0
    fi

    local root_dir="${MOUNT}"
    local boot_cmd="${root_dir}/boot/boot.cmd"
    local boot_scr="${root_dir}/boot/boot.scr"

    [[ -d "${root_dir}" ]] || return 0
    [[ -f "${boot_cmd}" ]] || {
        display_alert "optee-autodecrypt" "boot.cmd not found, skip load_addr adjustment: ${boot_cmd}" "debug"
        return 0
    }

    if grep -qE '^[[:space:]]*setenv[[:space:]]+load_addr[[:space:]]+"0x05000000"[[:space:]]*$' "${boot_cmd}"; then
        display_alert "optee-autodecrypt" "boot.cmd load_addr already set to safe address 0x05000000" "debug"
        rk_autodecrypt_refresh_boot_scr_from_boot_cmd "${boot_cmd}" "${boot_scr}"
        return 0
    fi

    if grep -qE '^[[:space:]]*setenv[[:space:]]+load_addr[[:space:]]+"0x9000000"[[:space:]]*$' "${boot_cmd}"; then
        sed -i -E 's|^[[:space:]]*setenv[[:space:]]+load_addr[[:space:]]+"0x9000000"[[:space:]]*$|setenv load_addr "0x05000000"|' "${boot_cmd}" ||
            exit_with_error "failed to update boot.cmd load_addr" "${boot_cmd}"
        display_alert "optee-autodecrypt" "Updated /boot/boot.cmd load_addr: 0x9000000 -> 0x05000000" "info"
        rk_autodecrypt_refresh_boot_scr_from_boot_cmd "${boot_cmd}" "${boot_scr}"
        return 0
    fi

    display_alert "optee-autodecrypt" "No matching load_addr=0x9000000 line found in boot.cmd, left unchanged" "warn"
}

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

    # Resolve extension root robustly across different Armbian extension layouts.
    local extension_dir=""
    local candidate=""
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "${script_dir}" \
        "${SRC}/extensions/seeed_armbian_extension/rk_secure-disk-encryption" \
        "${SRC}/extensions/rk_secure-disk-encryption"; do
        if [[ -d "${candidate}/auto-decryption-config" ]]; then
            extension_dir="${candidate}"
            break
        fi
    done
    [[ -n "${extension_dir}" ]] || extension_dir="${script_dir}"

    # Copy install-optee hook file
    local hook_src="${extension_dir}/auto-decryption-config/install-optee"
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
    local decryption_src="${extension_dir}/auto-decryption-config/decryption-disk.sh"
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


function pre_prepare_partitions__secure_storage_partitions() {
	USE_HOOK_FOR_PARTITION="yes"
	SECURE_STORAGE_SECURITY_SIZE=${SECURE_STORAGE_SECURITY_SIZE:-4}
	SECURE_STORAGE_SECURITY_FS_TYPE=${SECURE_STORAGE_SECURITY_FS_TYPE:-none}
	display_alert "secure-storage" " security(${SECURE_STORAGE_SECURITY_SIZE}MiB) partitions" "info"
}

function create_partition_table__secure_storage() {
	# In AB mode, partition table is owned by create_partition_table__ab_part_ota.
	# Keep this hook as a no-op to avoid overriding AB layout.
	if [[ "${AB_PART_OTA}" == "yes" ]]; then
		if [[ -n "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]]; then
			display_alert "secure-storage" "AB mode detected, reusing security partition index ${SECURE_STORAGE_SECURITY_PART_INDEX}" "info"
		else
			display_alert "secure-storage" "AB mode detected but security partition index is unset" "warn"
		fi
		return 0
	fi

	local next=${OFFSET} # Starting MiB
	local p_index=1
	local script="label: ${IMAGE_PARTITION_TABLE:-gpt}\n"
	if [[ "${IMAGE_PARTITION_TABLE:-gpt}" == "gpt" ]]; then
		# Reduce GPT table entry count to lower SPL allocation pressure during early GPT parsing.
		local gpt_table_length="${SECURE_STORAGE_GPT_TABLE_LENGTH:-64}"
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

function post_create_partitions__920_verify_secure_storage_layout() {
	# Verify security partition exists in the raw image partition table.
	# NOTE: this hook runs before LOOP is allocated, so do not access ${LOOP}pX here.
	if [[ -z "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]]; then
		exit_with_error "secure-storage verification failed" "SECURE_STORAGE_SECURITY_PART_INDEX is empty"
	fi

	local ptable_dump
	ptable_dump="$(sfdisk -d "${SDCARD}.raw" 2>/dev/null || true)"
	if [[ -z "${ptable_dump}" ]]; then
		exit_with_error "secure-storage verification failed: cannot dump partition table" "${SDCARD}.raw"
	fi

	if ! grep -q 'name="security"' <<< "${ptable_dump}"; then
		display_alert "secure-storage" "Partition table dump:" "err"
		echo "${ptable_dump}" || true
		exit_with_error "secure-storage verification failed: no security partition name found" "${SDCARD}.raw"
	fi

	if ! grep -Eq "\\.raw${SECURE_STORAGE_SECURITY_PART_INDEX}([[:space:]]|:).*(name=\"security\")" <<< "${ptable_dump}"; then
		display_alert "secure-storage" "Partition table dump:" "err"
		echo "${ptable_dump}" || true
		exit_with_error "secure-storage verification failed: security index mismatch" "expected index=${SECURE_STORAGE_SECURITY_PART_INDEX}"
	fi

	display_alert "secure-storage" "Security partition table entry verified at index ${SECURE_STORAGE_SECURITY_PART_INDEX}" "info"
}


function format_partitions__secure_storage() {
	# security partition remains raw unless user specifies FS type
	if [[ -n "${SECURE_STORAGE_SECURITY_PART_INDEX}" ]]; then
		local sec_dev="${LOOP}p${SECURE_STORAGE_SECURITY_PART_INDEX}"
		check_loop_device "${sec_dev}"
		[[ -b "${sec_dev}" ]] || exit_with_error "secure-storage verification failed: security partition device missing after loop setup" "${sec_dev}"

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
			fi

			# Multiple syncs to ensure data is written to disk
			sync
			sync
			blockdev --flushbufs "${sec_dev}" 2>/dev/null || true
		fi
	fi
}
