function fetch_sources_tools__rksdk_tools() {
	fetch_from_repo "${RKBIN_GIT_URL:-"https://github.com/ackPeng/rockchip_sdk_tools.git"}" "rockchip_sdk_tools" "branch:${RKSDK_TOOLS_BRANCH:-"main"}"
}

function resolve_rockchip_sdk_rkbin_root() {
    echo "${SRC}/cache/sources/rockchip_sdk_tools/rkbin"
}

function rk_full_secure_boot_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" ]]
}

function rk_optee_bootchain_enabled() {
    [[ "${RK_SECURE_UBOOT_ENABLE}" == "yes" || "${RK_OPTEE_BOOT_ENABLE}" == "yes" ]]
}

function pre_config_uboot_target__generate_fit_keys() {
    # Goal: Generate keys required for FIT signing before U-Boot configuration, plus an optional system encryption key.
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    local uboot_workdir rkbin_root rkbin_dir rk_sign_tool keys_dir
    uboot_workdir="$(pwd)"  # Current directory is the U-Boot source tree
    keys_dir="${uboot_workdir}/keys"

    # Prefer UBOOT_DIR if user explicitly set it
    if [[ -n "${UBOOT_DIR}" ]]; then
        uboot_workdir="${UBOOT_DIR}"
        keys_dir="${UBOOT_DIR}/keys"
    fi

    rkbin_root="$(resolve_rockchip_sdk_rkbin_root)"
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    echo "rkbin_root = ${rkbin_root}"
    echo "rkbin_dir  = ${rkbin_dir}"

    # Find rk_sign_tool executable (prefer PATH)
    rk_sign_tool="$(command -v rk_sign_tool 2>/dev/null || true)"
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_dir}" && -x "${rkbin_dir}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_dir}/tools/rk_sign_tool"
    fi
    if [[ -z "${rk_sign_tool}" && -n "${rkbin_root}" && -x "${rkbin_root}/tools/rk_sign_tool" ]]; then
        rk_sign_tool="${rkbin_root}/tools/rk_sign_tool"
    fi

    if [[ -z "${rk_sign_tool}" ]]; then
        display_alert "secure-uboot" "rk_sign_tool not found, skipping FIT key generation" "warn"
        return 0
    fi

    mkdir -p "${keys_dir}" || { display_alert "secure-uboot" "Cannot create directory ${keys_dir}" "err"; return 1; }

    # Idempotent: if dev.key and dev.crt already exist, assume keys were generated and avoid overwriting
    if [[ -f "${keys_dir}/dev.key" && -f "${keys_dir}/dev.crt" ]]; then
        display_alert "secure-uboot" "Existing keys detected, skipping generation (${keys_dir})" "info"
        export UBOOT_FIT_KEYS_DIR="${keys_dir}"
        return 0
    fi

    display_alert "secure-uboot" "Generating initial key pair using rk_sign_tool" "info"
    (
        cd "${keys_dir}" || exit 1
        # Generate RSA 2048-bit key pair (tool outputs private_key.pem / public_key.pem)
        "${rk_sign_tool}" kk --bits 2048 --out ./ || exit_with_error "rk_sign_tool key generation failed" "${rk_sign_tool}"
        ln -rsf private_key.pem dev.key
        ln -rsf public_key.pem dev.pubkey

        # Generate self-signed certificate (subject can be adjusted as needed)
        openssl req -batch -new -x509 -key dev.key -out dev.crt -subj "/CN=Armbian FIT Key/" || exit_with_error "Failed to generate self-signed certificate" "dev.crt"

        # Generate random key for system encryption (32 bytes, hex encoded)
        openssl rand -hex 32 > system_enc_key || exit_with_error "Failed to generate system_enc_key" "system_enc_key"
    )

    # Export path for later stages/packaging
    export UBOOT_FIT_KEYS_DIR="${keys_dir}"
    display_alert "secure-uboot" "FIT keys generated: ${UBOOT_FIT_KEYS_DIR}" "info"
}


# Helper: setup vendor build environment
function setup_vendor_build_environment() {
    # Generate keys (idempotent)
    if [[ "${DISABLE_FIT_KEY_GEN}" != "yes" ]]; then
        pre_config_uboot_target__generate_fit_keys || display_alert "secure-uboot" "FIT key generation failed" "warn"
    fi
}

# Helper: change boot partition name/label
function modify_boot_partition_name() {
    # Set boot filesystem label to "boot"
    export BOOT_FS_LABEL="boot"
    display_alert "secure-uboot" "Set boot partition label to: ${BOOT_FS_LABEL}" "info"
}

# Helper: create SPI loader image
function create_spi_loader_image() {
    display_alert "secure-uboot" "Creating SPI loader image" "info"

    dd if=/dev/zero of=rkspi_loader.img bs=1M count=0 seek=16 2>/dev/null

    # Create partition table
    /sbin/parted -s rkspi_loader.img mklabel gpt
    /sbin/parted -s rkspi_loader.img unit s mkpart idbloader 64 7167
    /sbin/parted -s rkspi_loader.img unit s mkpart vnvm 7168 7679
    /sbin/parted -s rkspi_loader.img unit s mkpart reserved_space 7680 8063
    /sbin/parted -s rkspi_loader.img unit s mkpart reserved1 8064 8127
    /sbin/parted -s rkspi_loader.img unit s mkpart uboot_env 8128 8191
    /sbin/parted -s rkspi_loader.img unit s mkpart reserved2 8192 16383
    /sbin/parted -s rkspi_loader.img unit s mkpart uboot 16384 32734

    # Write data
    if [[ -f idbloader.img ]]; then
        dd if=idbloader.img of=rkspi_loader.img seek=64 conv=notrunc 2>/dev/null
    fi
    if [[ -f u-boot.itb ]]; then
        dd if=u-boot.itb of=rkspi_loader.img seek=16384 conv=notrunc 2>/dev/null
    fi
}

# Helper: collect vendor artifacts
function collect_vendor_artifacts() {
    local vendor_board="${1}"
    local dst_dir="${uboottempdir}/usr/lib/${uboot_name}"

    mkdir -p "${dst_dir}" || exit_with_error "Failed to create packaging directory" "${dst_dir}"

    # Possible artifacts list
    local artifacts=(
        "rkspi_loader.img"
        "idbloader.img"
        "u-boot.bin"
        "u-boot-nodtb.bin"
        "u-boot.dtb"
        "u-boot.itb"
        "u-boot.its"
        "spl/u-boot-spl.bin"
        "tpl/u-boot-tpl.bin"
    )

    local copied=0
    for artifact in "${artifacts[@]}"; do
        if [[ -f "${artifact}" ]]; then
            cp -v "${artifact}" "${dst_dir}/" 2>&1 | grep -v '->' || true
            copied=$((copied+1))
        fi
    done

    if [[ ${copied} -gt 0 ]]; then
        display_alert "secure-uboot" "Copied ${copied} artifacts to ${dst_dir}" "info"
    fi

    # Save final config
    if [[ -f .config ]]; then
        cp .config "${dst_dir}/vendor-final.config"
    fi

    # Generate metadata
    generate_uboot_metadata "${dst_dir}" "${vendor_board}"
}

# Helper: generate U-Boot metadata
function generate_uboot_metadata() {
    local dst_dir="${1}"
    local vendor_board="${2}"

    cat > "${dst_dir}/u-boot-metadata-target-1.sh" <<VENDOR_META
declare -a UBOOT_TARGET_BINS=($(ls "${dst_dir}" 2>/dev/null | sed 's/^/"/;s/$/"/' | tr '\n' ' '))
declare UBOOT_TARGET_MAKE='${vendor_board}'
declare UBOOT_TARGET_CONFIG='vendor-final.config'
VENDOR_META
}

function detect_rk_secure_boot_platform() {
    # Return value: rk3576 / rk3588 / unknown
    # Platform detection is based on BOOT_SOC only.
    local boot_soc
    boot_soc="$(echo "${BOOT_SOC}" | tr '[:upper:]' '[:lower:]')"

    if [[ "${boot_soc}" == *"3576"* ]]; then
        echo "rk3576"
        return 0
    fi
    if [[ "${boot_soc}" == *"3588"* ]]; then
        echo "rk3588"
        return 0
    fi

    echo "unknown"
}

function detect_rk_secure_boot_board() {
    # Return value: canonical vendor board name, e.g. recomputer-rk3576-devkit / recomputer-rk3588-devkit / unknown
    # Board detection is based on BOARD_NAME first, fallback to BOARD.
    local board_name normalized
    board_name="${BOARD_NAME:-${BOARD:-}}"
    normalized="$(echo "${board_name}" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')"

    case "${normalized}" in
        recomputer-rk3576-devkit|*rk3576*devkit*|*rk3576*)
            echo "recomputer-rk3576-devkit"
            return 0
            ;;
        recomputer-rk3588-devkit|*rk3588*devkit*|*rk3588*)
            echo "recomputer-rk3588-devkit"
            return 0
            ;;
        *)
            echo "unknown"
            return 0
            ;;
    esac
}

function resolve_platform_rkbin_dir() {
    # Resolve platform-specific rkbin content directory.
    # Expected layout examples:
    # 1) rkbin/rk3576_rkbin/{RKTRUST,tools,...}
    # 2) rkbin/rk3588_rkbin/{RKTRUST,tools,...}
    # 3) legacy rkbin/{RKTRUST,tools,...}
    local rkbin_root platform rkbin_dir candidate
    rkbin_root="$(resolve_rockchip_sdk_rkbin_root)"
    platform="$(detect_rk_secure_boot_platform)"

    case "${platform}" in
        rk3576) rkbin_dir="${rkbin_root}/rk3576_rkbin" ;;
        rk3588) rkbin_dir="${rkbin_root}/rk3588_rkbin" ;;
        *) rkbin_dir="" ;;
    esac

    if [[ -n "${rkbin_dir}" && -d "${rkbin_dir}" ]]; then
        echo "${rkbin_dir}"
        return 0
    fi

    # If platform cannot be detected and both platform rkbin directories exist,
    # returning one arbitrarily is unsafe.
    if [[ "${platform}" == "unknown" && -d "${rkbin_root}/rk3576_rkbin" && -d "${rkbin_root}/rk3588_rkbin" ]]; then
        echo ""
        return 1
    fi

    if [[ -d "${rkbin_root}/RKTRUST" || -d "${rkbin_root}/tools" ]]; then
        echo "${rkbin_root}"
        return 0
    fi

    candidate="$(find "${rkbin_root}" -maxdepth 1 -mindepth 1 -type d -name "*_rkbin" | sort | head -n1)"
    if [[ -n "${candidate}" ]]; then
        echo "${candidate}"
        return 0
    fi

    echo "${rkbin_root}"
}

function resolve_kernel_dtb_path() {
    # Resolve kernel DTB path for resource/FIT packaging.
    # Priority:
    # 1) RK_SECURE_KERNEL_DTB absolute path
    # 2) RK_SECURE_KERNEL_DTB filename under kernel rockchip dtb dir
    # 3) board + platform based candidate list (BOARD_NAME + BOOT_SOC)
    local kernel_src="$1"
    local dtb_dir platform board candidate override

    dtb_dir="${kernel_src}/arch/arm64/boot/dts/rockchip"
    override="${RK_SECURE_KERNEL_DTB:-}"

    if [[ -n "${override}" ]]; then
        if [[ -f "${override}" ]]; then
            echo "${override}"
            return 0
        fi
        if [[ -f "${dtb_dir}/${override}" ]]; then
            echo "${dtb_dir}/${override}"
            return 0
        fi
        display_alert "secure-uboot" "RK_SECURE_KERNEL_DTB not found: ${override}" "warn"
    fi

    platform="$(detect_rk_secure_boot_platform)"
    board="$(detect_rk_secure_boot_board)"

    # Board-specific preferred candidates.
    case "${board}" in
        recomputer-rk3576-devkit)
            for candidate in \
                "rk3576-recomputer-rk3576-devkit.dtb" \
                "rk3576-recomputer-devkit.dtb"; do
                [[ -f "${dtb_dir}/${candidate}" ]] && { echo "${dtb_dir}/${candidate}"; return 0; }
            done
            ;;
        recomputer-rk3588-devkit)
            for candidate in \
                "rk3588-recomputer-rk3588-devkit.dtb" \
                "rk3588-recomputer-devkit.dtb"; do
                [[ -f "${dtb_dir}/${candidate}" ]] && { echo "${dtb_dir}/${candidate}"; return 0; }
            done
            ;;
        *)
            ;;
    esac

    # Platform-specific fallback candidates.
    case "${platform}" in
        rk3576)
            for candidate in \
                "rk3576-recomputer-rk3576-devkit.dtb" \
                "rk3576-recomputer-devkit.dtb"; do
                [[ -f "${dtb_dir}/${candidate}" ]] && { echo "${dtb_dir}/${candidate}"; return 0; }
            done
            ;;
        rk3588)
            for candidate in \
                "rk3588-recomputer-rk3588-devkit.dtb" \
                "rk3588-recomputer-devkit.dtb"; do
                [[ -f "${dtb_dir}/${candidate}" ]] && { echo "${dtb_dir}/${candidate}"; return 0; }
            done
            ;;
        *)
            ;;
    esac

    echo ""
}

function resolve_rk_secure_extension_dir() {
    # Resolve extension root robustly across different Armbian extension layouts.
    local script_dir candidate
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    for candidate in \
        "${script_dir}" \
        "${SRC}/extensions/seeed_armbian_extension/rk_secure-disk-encryption" \
        "${SRC}/extensions/rk_secure-disk-encryption"; do
        if [[ -d "${candidate}/secure-boot-config" ]]; then
            echo "${candidate}"
            return 0
        fi
    done

    # Fallback to script directory for clearer error messages upstream.
    echo "${script_dir}"
}

function resolve_platform_defconfig_path() {
    # Resolve platform + board specific defconfig from either old or new layout.
    # Supported layouts:
    # - secure-boot-config/defconfig/recomputer-*.config
    # - secure-boot-config/rk3576-config/recomputer-rk3576-devkit_defconfig
    # - secure-boot-config/rk3588-config/recomputer-rk3588-devkit_defconfig
    local secure_config_dir="$1"
    local platform board candidate

    platform="$(detect_rk_secure_boot_platform)"
    board="$(detect_rk_secure_boot_board)"

    # Prefer exact board mapping first.
    if [[ "${board}" != "unknown" ]]; then
        case "${platform}" in
            rk3576|rk3588)
                candidate="${secure_config_dir}/${platform}-config/${board}_defconfig"
                [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }
                ;;
            *)
                ;;
        esac

        candidate="${secure_config_dir}/defconfig/${board}_defconfig"
        [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }
    fi

    case "${platform}" in
        rk3576)
            for candidate in \
                "${secure_config_dir}/rk3576-config/recomputer-rk3576-devkit_defconfig" \
                "${secure_config_dir}/defconfig/recomputer-rk3576-devkit_defconfig"; do
                [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }
            done
            ;;
        rk3588)
            for candidate in \
                "${secure_config_dir}/rk3588-config/recomputer-rk3588-devkit_defconfig" \
                "${secure_config_dir}/defconfig/recomputer-rk3588-devkit_defconfig"; do
                [[ -f "${candidate}" ]] && { echo "${candidate}"; return 0; }
            done
            ;;
        *)
            ;;
    esac

    echo ""
}

function pre_prepare_partitions__040_require_secure_storage_hook() {
    # If secure boot + auto decrypt are enabled together, secure storage hook must be present.
    if [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]; then
        if [[ "$(type -t create_partition_table__secure_storage || true)" != "function" ]]; then
            exit_with_error "rk-auto-decryption secure storage partition hook is missing" "create_partition_table__secure_storage not found"
        fi
    fi
}

# Helper: apply configs and patches from secure-boot-config directory
function apply_secure_boot_config() {
    local extension_dir secure_config_dir
    extension_dir="$(resolve_rk_secure_extension_dir)"
    secure_config_dir="${extension_dir}/secure-boot-config"

    if [[ ! -d "${secure_config_dir}" ]]; then
        display_alert "secure-uboot" "secure-boot-config directory does not exist: ${secure_config_dir}" "debug"
        return 0
    fi

    display_alert "secure-uboot" "Applying secure-boot-config files and patches" "info"

    # 1. defconfig files (platform-specific)
    display_alert "secure-uboot" "Applying defconfig files" "info"
    mkdir -p configs
    local defconfig_count=0
    local selected_defconfig platform board
    platform="$(detect_rk_secure_boot_platform)"
    board="$(detect_rk_secure_boot_board)"
    selected_defconfig="$(resolve_platform_defconfig_path "${secure_config_dir}")"

    if [[ -n "${selected_defconfig}" ]]; then
        cp -vf "${selected_defconfig}" configs/ && defconfig_count=$((defconfig_count + 1))
        display_alert "secure-uboot" "Applied defconfig: $(basename "${selected_defconfig}") (BOOT_SOC=${BOOT_SOC} BOARD_NAME=${BOARD_NAME:-${BOARD:-}})" "info"
    else
        exit_with_error "No matching defconfig found for platform/board" "BOOT_SOC=${BOOT_SOC} BOARD_NAME=${BOARD_NAME:-${BOARD:-}} platform=${platform} board=${board}"
    fi

    if [[ "${defconfig_count}" -lt 1 ]]; then
        exit_with_error "No defconfig files found under secure-boot-config" "${secure_config_dir}"
    fi
    display_alert "secure-uboot" "Applied ${defconfig_count} defconfig file(s)" "debug"

    # 2. Device tree files
    if [[ -d "${secure_config_dir}/dt" ]]; then
        display_alert "secure-uboot" "Applying device tree files" "info"
        mkdir -p arch/arm/dts
        local dt_count=0
        for dt_file in "${secure_config_dir}/dt"/*; do
            [[ -e "${dt_file}" ]] || continue
            cp -rf "${dt_file}" arch/arm/dts/ && dt_count=$((dt_count + 1))
        done
        display_alert "secure-uboot" "Applied ${dt_count} device tree files" "debug"
    fi

    # 3. board directory
    if [[ -d "${secure_config_dir}/board" ]]; then
        display_alert "secure-uboot" "Applying board-level configuration files" "info"
        local board_count=0
        # Recursively copy the whole board directory structure
        cp -rf "${secure_config_dir}/board"/* . 2>/dev/null && board_count=$((board_count + 1))
        display_alert "secure-uboot" "Applied board-level configuration files" "debug"
    fi

    # 4. Patch files (if any)
    if compgen -G "${secure_config_dir}"/*.patch > /dev/null; then
        display_alert "secure-uboot" "Applying secure boot patches" "info"
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
                    display_alert "secure-uboot" "Patch applied: ${patch_name}" "debug"
                else
                    patch_failed=$((patch_failed + 1))
                    display_alert "secure-uboot" "Failed to apply patch: ${patch_name}" "err"
                fi
            else
                # Fallback to patch(1)
                if patch -p1 < "${patch_file}" 2>/dev/null; then
                    patch_applied=$((patch_applied + 1))
                else
                    patch_failed=$((patch_failed + 1))
                    display_alert "secure-uboot" "Patch application failed (patch): ${patch_name}" "err"
                fi
            fi
        done

        display_alert "secure-uboot" "Patch application completed: Success=${patch_applied} Failed=${patch_failed}" "info"
    fi

    # 5. Handle other configuration files
    local config_files=(
        "include/configs"
        "scripts"
        "include"
    )

    for config_subdir in "${config_files[@]}"; do
        if [[ -d "${secure_config_dir}/${config_subdir}" ]]; then
            display_alert "secure-uboot" "Applying configuration directory: ${config_subdir}" "info"
            mkdir -p "${config_subdir}"
            cp -rf "${secure_config_dir}/${config_subdir}"/* "${config_subdir}/" 2>/dev/null || true
        fi
    done

    display_alert "secure-uboot" "secure-boot-config application completed" "info"
}

function enable_optee_bootchain_bl32_fit_node() {
    # Non-secure OP-TEE bootchain still needs BL32 packed into vendor u-boot.itb.
    # Keep this as a narrow local change instead of reusing the full secure-boot overlay.
    local fit_generator="arch/arm/mach-rockchip/make_fit_atf.sh"

    if [[ ! -f "${fit_generator}" ]]; then
        display_alert "secure-uboot" "OP-TEE bootchain: FIT generator not found, skipping BL32 enable" "warn"
        return 0
    fi

    if grep -q '^[[:space:]]*gen_bl32_node[[:space:]]*$' "${fit_generator}"; then
        display_alert "secure-uboot" "OP-TEE bootchain: BL32 FIT node already enabled" "debug"
        return 0
    fi

    if grep -q '^[[:space:]]*#gen_bl32_node[[:space:]]*$' "${fit_generator}"; then
        sed -i 's/^[[:space:]]*#gen_bl32_node[[:space:]]*$/gen_bl32_node/' "${fit_generator}" ||
            exit_with_error "Failed to enable BL32 FIT node for OP-TEE bootchain" "${fit_generator}"
        display_alert "secure-uboot" "OP-TEE bootchain: enabled BL32 FIT node in ${fit_generator}" "info"
        return 0
    fi

    display_alert "secure-uboot" "OP-TEE bootchain: no commented gen_bl32_node marker found, leaving ${fit_generator} unchanged" "warn"
}

function rk_secure_boot_autodecrypt_mode_enabled() {
    [[ "${CRYPTROOT_ENABLE}" == "yes" && "${RK_AUTO_DECRYP}" == "yes" ]]
}

function rk_secure_boot_verify_fit_images() {
    local fit_image="$1"
    local fit_info

    [[ -f "${fit_image}" ]] || exit_with_error "FIT image missing after vendor build" "${fit_image}"

    if ! command -v dumpimage >/dev/null 2>&1; then
        display_alert "secure-uboot" "dumpimage not found, skip FIT image content verification" "warn"
        return 0
    fi

    fit_info="$(dumpimage -l "${fit_image}" 2>/dev/null || true)"
    [[ -n "${fit_info}" ]] || exit_with_error "Failed to parse FIT image" "${fit_image}"

    # For auto-decryption mode, BL32(OP-TEE) and the third ATF loadable are mandatory.
    if rk_secure_boot_autodecrypt_mode_enabled; then
        grep -Eq 'Image [0-9]+ \(atf-3\)' <<< "${fit_info}" ||
            exit_with_error "FIT image validation failed: missing atf-3 loadable" "${fit_image}"
        grep -Eq 'Image [0-9]+ \(optee\)' <<< "${fit_info}" ||
            exit_with_error "FIT image validation failed: missing optee loadable" "${fit_image}"
    fi

    display_alert "secure-uboot" "FIT image validation passed (${fit_image})" "info"
}


function build_custom_uboot__vendor_fit_secure() {
    # Use Rockchip vendor make.sh to build secure FIT version U-Boot.
    if ! rk_optee_bootchain_enabled; then
        return 0
    fi

    # Conditional restriction: Rockchip series (rockchip64 / rk35xx / downstream naming) or forced.
    if [[ ! "${LINUXFAMILY}" =~ ^(rockchip|rockchip64|rk35|rk35xx) ]]; then
        display_alert "secure-uboot" "LINUXFAMILY=${LINUXFAMILY} does not match Rockchip, skipping vendor FIT U-Boot build" "debug"
        return 0
    fi

    # Check for make.sh (vendor build flag)
    if [[ ! -f ./make.sh ]]; then
        display_alert "secure-uboot" "Vendor make.sh not found, falling back to standard build process" "warn"
        return 0
    fi

    # Prevent duplicate execution
    if [[ "${EXTENSION_BUILT_UBOOT}" == "yes" ]]; then
        display_alert "secure-uboot" "Marked EXTENSION_BUILT_UBOOT by other steps, skipping" "debug"
        return 0
    fi

    display_alert "secure-uboot" "Starting vendor FIT U-Boot build" "info"

    # Use standard patch process instead of manual copying
    display_alert "secure-uboot" "Applying standard patch process" "info"

    # Ensure uboot_git_revision is set (required by patch_uboot_target)
    declare -g uboot_git_revision
    if [[ -z "${uboot_git_revision}" ]]; then
        uboot_git_revision="$(git rev-parse HEAD)"
    fi

    # Apply standard patch process (this will automatically handle all patches in BOOTPATCHDIR)
    # Including: board_recomputer-rk3588/, target_*, common directories
    patch_uboot_target

    if rk_full_secure_boot_enabled; then
        # Full secure boot mode: apply secure defconfig/patch set (FIT-centric boot flow)
        apply_secure_boot_config
    else
        # OP-TEE bootchain mode: keep vendor default boot behavior, only ensure build chain is available
        display_alert "secure-uboot" "OP-TEE bootchain mode: skipping secure-boot defconfig/patch overlay" "info"
        if [[ -f .config ]]; then
            display_alert "secure-uboot" "OP-TEE bootchain mode: removing stale .config to avoid secure FIT boot behavior carry-over" "info"
            rm -f .config || exit_with_error "Failed to remove stale .config" "$(pwd)/.config"
        fi
        enable_optee_bootchain_bl32_fit_node
    fi
    setup_vendor_build_environment

    # Copy rkbin to the parent directory of u-boot
    local rkbin_source
    rkbin_source="$(resolve_platform_rkbin_dir)"
    local rkbin_dest="../rkbin"
    if [[ -d "${rkbin_source}" ]]; then
        display_alert "secure-uboot" "Copying platform rkbin (${rkbin_source}) to ${rkbin_dest}" "info"
        rm -rf "${rkbin_dest}" 2>/dev/null || true
        mkdir -p "${rkbin_dest}" || {
            display_alert "secure-uboot" "Failed to create ${rkbin_dest}" "err"
            return 1
        }
        cp -rf "${rkbin_source}/." "${rkbin_dest}/" || {
            display_alert "secure-uboot" "Failed to copy rkbin" "err"
            return 1
        }
    else
        exit_with_error "secure-uboot rkbin source directory does not exist (or platform unresolved)" "${rkbin_source}"
    fi

    # Copy prebuilts to the parent directory of u-boot
    local prebuilts_source="${SRC}/cache/sources/rockchip_sdk_tools/other_build_tool_chain/prebuilts"
    local prebuilts_dest="../prebuilts"
    if [[ -d "${prebuilts_source}" ]]; then
        display_alert "secure-uboot" "Copying prebuilts to ${prebuilts_dest}" "info"
        rm -rf "${prebuilts_dest}" 2>/dev/null || true
        cp -rf "${prebuilts_source}" "${prebuilts_dest}" || {
            display_alert "secure-uboot" "Failed to copy prebuilts" "err"
            return 1
        }
    else
        display_alert "secure-uboot" "prebuilts source directory does not exist: ${prebuilts_source}" "warn"
    fi

    # Build using vendor make.sh
    display_alert "secure-uboot" "Starting vendor u-boot compilation" "info"
    local vendor_board
    if [[ -n "${UBOOT_VENDOR_BOARD}" ]]; then
        vendor_board="${UBOOT_VENDOR_BOARD}"
    else
        case "$(detect_rk_secure_boot_platform)" in
            rk3576) vendor_board="recomputer-rk3576-devkit" ;;
            rk3588) vendor_board="recomputer-rk3588-devkit" ;;
            *) vendor_board="recomputer-rk3588-devkit" ;;
        esac
    fi
    bash ./make.sh "${vendor_board}" --spl-new || exit_with_error "vendor u-boot compilation failed" "make.sh"

    # Requires idblock support: generate idblock.bin
    display_alert "secure-uboot" "Generating idblock.bin" "info"
    bash ./make.sh --idblock || display_alert "secure-uboot" "idblock generation failed (continuing)" "warn"

    # Copy key files
    cp idblock.bin idbloader.img || true
    if [[ -f fit/uboot.itb ]]; then
        cp fit/uboot.itb u-boot.itb
    fi
    if [[ -f fit/u-boot.its ]]; then
        cp fit/u-boot.its u-boot.its
    fi
    rk_secure_boot_verify_fit_images "u-boot.itb"

    # Create SPI loader image
    create_spi_loader_image

    # Collect artifacts to Armbian packaging directory
    collect_vendor_artifacts "${vendor_board}"

    # Mark as built
    EXTENSION_BUILT_UBOOT=yes
    uboot_target_counter=1
    display_alert "secure-uboot" "vendor FIT secure U-Boot build completed" "info"
    return 0
}


function pre_package_kernel_image__create_resource_img() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    local kernel_src="${SRC}/cache/sources/${LINUXSOURCEDIR}"
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local dtb_path
    dtb_path="$(resolve_kernel_dtb_path "${kernel_src}")"
    display_alert "Creating resource.img" "Using DTB: ${dtb_path:-<not found>}" "info"
    local resource_tool="${uboot_src}/tools/resource_tool"
    local output_resource_img="${kernel_src}/resource.img"

    # Check necessary files and tools
    [[ -f "${dtb_path}" ]] || {
        display_alert "Missing DTB file" "${dtb_path}" "err"
        return 0
    }

    [[ -n "${resource_tool}" && -x "${resource_tool}" ]] || {
        display_alert "Missing resource_tool" "Searched in u-boot and rkbin-tools directories" "err"
        return 0
    }

    display_alert "Using resource_tool" "${resource_tool}" "debug"
    
    # Create temporary work directory
    local temp_work_dir=$(mktemp -d)
    mkdir -p "${temp_work_dir}"
    
    # Copy DTB file to work directory
    local dtb_filename=$(basename "${dtb_path}")
    cp "${dtb_path}" "${temp_work_dir}/${dtb_filename}"

    # Ensure output directory exists and is writable
    local output_dir=$(dirname "${output_resource_img}")
    mkdir -p "${output_dir}"

    # Use resource_tool to create resource.img
    (
        cd "${temp_work_dir}"

        display_alert "Debug: Packing resource.img" "DTB: ${dtb_filename}, Output: ${output_resource_img}" "debug"
        display_alert "Debug: Working directory" "$(pwd)" "debug"
        display_alert "Debug: Files in temp dir" "$(ls -la)" "debug"

        # Create in current directory first, then move to target location
        "${resource_tool}" --pack "${dtb_filename}" "./resource.img" || {
            display_alert "Failed to create resource.img in temp dir" "resource_tool pack failed" "err"
            rm -rf "${temp_work_dir}"
            return 1
        }

        # Move to final location
        if [[ -f "./resource.img" ]]; then
            mv "./resource.img" "${output_resource_img}" || {
                display_alert "Failed to move resource.img to ${output_resource_img}" "mv failed" "err"
                rm -rf "${temp_work_dir}"
                return 1
            }
        else
            display_alert "resource.img not created in temp directory" "file missing" "err"
            rm -rf "${temp_work_dir}"
            return 1
        fi
    )
    
    # Clean up temporary directory
    rm -rf "${temp_work_dir}"
    
    # Verify generated resource.img
    if [[ -f "${output_resource_img}" && -s "${output_resource_img}" ]]; then
        local img_size=$(stat -c %s "${output_resource_img}")
        display_alert "Successfully created resource.img" "Size: ${img_size} bytes" "info"
        
        # Optional: Display resource.img content
        "${resource_tool}" --print --image="${output_resource_img}" 2>/dev/null || true
    else
        display_alert "Failed to create resource.img" "File not found or empty" "err"
        return 1
    fi
}

function pre_umount_final_image__100_set_armbianenv_verbosity() {
    # For secure boot and/or encrypted-root builds, force verbose boot logs.
    if [[ "${RK_SECURE_UBOOT_ENABLE}" != "yes" && "${CRYPTROOT_ENABLE}" != "yes" ]]; then
        return 0
    fi

    local root_dir="${MOUNT}"
    [[ -d "${root_dir}" ]] || return 0

    local candidates=(
        "${root_dir}/boot/armbianEnv.txt"
        "${root_dir}/armbianEnv.txt"
    )

    local env_file updated=0
    for env_file in "${candidates[@]}"; do
        [[ -f "${env_file}" ]] || continue
        if grep -q '^verbosity=' "${env_file}" 2>/dev/null; then
            sed -i 's/^verbosity=.*/verbosity=7/' "${env_file}" || true
        else
            printf '\nverbosity=7\n' >> "${env_file}"
        fi
        display_alert "secure-uboot" "Set verbosity=7 in ${env_file}" "info"
        updated=1
    done

    if [[ "${updated}" -eq 0 ]]; then
        mkdir -p "${root_dir}/boot" 2>/dev/null || true
        printf 'verbosity=7\n' > "${root_dir}/boot/armbianEnv.txt"
        display_alert "secure-uboot" "Created ${root_dir}/boot/armbianEnv.txt with verbosity=7" "info"
    fi
}

function pre_umount_final_image__package_fit() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    display_alert "fit-post-initrd" "Starting to rebuild FIT before final unmount" "info"
    local boot_dir="${MOUNT}/boot"  # Use real /boot from mount point
    [[ -d "${boot_dir}" ]] || exit_with_error "FIT packaging failed: /boot does not exist" "${boot_dir}"

    local ramdisk_path=""
    if compgen -G "${boot_dir}/initrd.img-"* > /dev/null; then
        ramdisk_path="$(ls -1t ${boot_dir}/initrd.img-* | head -1)"
        display_alert "fit-post-initrd" "Using official initrd: ${ramdisk_path}" "info"
    elif [[ -f "${boot_dir}/uInitrd" ]]; then
        ramdisk_path="${boot_dir}/uInitrd"
        display_alert "fit-post-initrd" "Using uInitrd: ${ramdisk_path}" "info"
    elif [[ -f "${SRC}/userpatches/overlay/rootfs.cpio.gz" ]]; then
        ramdisk_path="${SRC}/userpatches/overlay/rootfs.cpio.gz"
        display_alert "fit-post-initrd" "Official initrd not found, falling back to rootfs.cpio.gz" "warn"
    else
        exit_with_error "FIT packaging failed: no initramfs found" "${boot_dir}"
    fi

    local kernel_src="${SRC}/cache/sources/${LINUXSOURCEDIR}"
    local kernel_img_path="${kernel_src}/arch/arm64/boot/Image"
    local dtb_path
    dtb_path="$(resolve_kernel_dtb_path "${kernel_src}")"
    display_alert "fit-post-initrd" "Embedding DTB into FIT: ${dtb_path} (name=$(basename "${dtb_path}" 2>/dev/null || echo unknown))" "info"
    local resource_path="${kernel_src}/resource.img"
    local rk_mkimage=""
    local rkbin_dir
    rkbin_dir="$(resolve_platform_rkbin_dir)"
    if [[ -x "${rkbin_dir}/tools/mkimage" ]]; then
        rk_mkimage="${rkbin_dir}/tools/mkimage"
    elif [[ -x "$(resolve_rockchip_sdk_rkbin_root)/tools/mkimage" ]]; then
        rk_mkimage="$(resolve_rockchip_sdk_rkbin_root)/tools/mkimage"
    fi
    [[ -x "${rk_mkimage}" ]] || exit_with_error "FIT packaging failed: mkimage missing" "${rk_mkimage}"

    [[ -f "${kernel_img_path}" ]] || exit_with_error "FIT packaging failed: kernel image missing" "${kernel_img_path}"
    [[ -f "${dtb_path}" ]] || exit_with_error "FIT packaging failed: DTB missing" "${dtb_path}"

    # Use host temporary directory
    local fit_work="${TMPDIR:-/tmp}/fit-final-$$"
    rm -rf "${fit_work}" 2>/dev/null || true
    mkdir -p "${fit_work}" || exit_with_error "FIT packaging failed: cannot create temporary directory" "${fit_work}"

    # Copy necessary files to work directory
    cp -f "${kernel_img_path}" "${fit_work}/Image"
    cp -f "${dtb_path}" "${fit_work}/board.dtb"
    if [[ -f "${resource_path}" ]]; then cp -f "${resource_path}" "${fit_work}/resource.img"; else : > "${fit_work}/resource.img"; fi
    cp -f "${ramdisk_path}" "${fit_work}/initrd.img"

    # Use external ITS template file
    local extension_dir its_template
    extension_dir="$(resolve_rk_secure_extension_dir)"
    its_template="${extension_dir}/secure-boot-config/fit_kernel.its"
    if [[ ! -f "${its_template}" ]]; then
        exit_with_error "FIT packaging failed: ITS template missing" "${its_template}"
    fi

    # Copy ITS template to work directory
    cp -f "${its_template}" "${fit_work}/boot-final.its"

    # Replace placeholders with actual file paths
    sed -i "s|@KERNEL_DTB@|${dtb_path}|g" "${fit_work}/boot-final.its"
    sed -i "s|@KERNEL_IMG@|${kernel_img_path}|g" "${fit_work}/boot-final.its"
    sed -i "s|@RAMDISK_IMG@|${ramdisk_path}|g" "${fit_work}/boot-final.its"
    sed -i "s|@RESOURCE_IMG@|${resource_path}|g" "${fit_work}/boot-final.its"

    display_alert "fit-post-initrd" "Generating final FIT (initial boot-final.img)" "info"
    (
        cd "${fit_work}" || exit 1

        "${rk_mkimage}" -f boot-final.its  -E -p 0x800 boot-final.img || exit 1

    ) || { rm -rf "${fit_work}"; exit_with_error "FIT packaging failed: mkimage generation failed" "${fit_work}/boot-final.its"; }

    # Secondary signing: refer to post_install_kernel_debs__package_initramfs_itb, if scripts/fit.sh exists
    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local uboot_dir="${uboot_src}"
    if [[ -z "${uboot_dir}" || ! -d "${uboot_dir}" ]]; then
        uboot_dir="$(find "${SRC}/cache/sources/u-boot-worktree" -maxdepth 4 -type d -name "u-boot-*${LINUXFAMILY}*" | head -1)"
    fi


    if [[ -x "${uboot_dir}/scripts/fit.sh" ]]; then
        display_alert "fit-post-initrd" "Executing secondary signing script fit.sh" "info"
        (
            cd "${uboot_dir}" || exit 1
            cp "${fit_work}/boot-final.img" .
            ./scripts/fit.sh --boot_img "${fit_work}/boot-final.img" || exit 1
        ) || display_alert "fit-post-initrd" "fit.sh execution failed, trying fallback image path" "warn"
    else
        display_alert "fit-post-initrd" "fit.sh not found, using boot-final.img as fallback" "warn"
    fi

    local fit_output_candidate=""
    if [[ -f "${uboot_dir}/fit/boot.itb" ]]; then
        fit_output_candidate="${uboot_dir}/fit/boot.itb"
    elif [[ -f "${uboot_dir}/boot-final.img" ]]; then
        fit_output_candidate="${uboot_dir}/boot-final.img"
    elif [[ -f "${fit_work}/boot-final.img" ]]; then
        fit_output_candidate="${fit_work}/boot-final.img"
    else
        rm -rf "${fit_work}" 2>/dev/null || true
        exit_with_error "FIT packaging failed: no final FIT image generated" "${uboot_dir}/fit/boot.itb"
    fi

    local canonical_fit_image="${SRC}/cache/sources/${BOOTSOURCEDIR}/fit/boot.itb"
    mkdir -p "$(dirname "${canonical_fit_image}")" || exit_with_error "FIT packaging failed: cannot create fit output directory" "$(dirname "${canonical_fit_image}")"
    if [[ "${fit_output_candidate}" == "${canonical_fit_image}" ]] || \
       [[ -e "${canonical_fit_image}" && "${fit_output_candidate}" -ef "${canonical_fit_image}" ]]; then
        display_alert "fit-post-initrd" "Final FIT image already in canonical location: ${canonical_fit_image}" "info"
    else
        cp -f "${fit_output_candidate}" "${canonical_fit_image}" || exit_with_error "FIT packaging failed: cannot stage final fit image" "${canonical_fit_image}"
    fi
    export RK_SECURE_BOOT_FIT_IMAGE="${canonical_fit_image}"
    display_alert "fit-post-initrd" "Final FIT image ready: ${RK_SECURE_BOOT_FIT_IMAGE}" "info"

    # Clean up temporary work directory
    rm -rf "${fit_work}" 2>/dev/null || true

    display_alert "fit-flash" "Removing boot settings from fstab" "info"

    local fstab_file="${MOUNT}/etc/fstab"

    if [[ ! -f "${fstab_file}" ]]; then
        display_alert "fit-flash" "No fstab file" "info"
        return 0
    fi

    # If there are no boot entries, skip
    if ! grep -q "/boot" "${fstab_file}" 2>/dev/null; then
        display_alert "fit-flash" "No boot entries" "info"
        return 0
    fi

    display_alert "secure-uboot" "pre_umount_image: Removing boot partition mount entries from fstab" "info"

    # Print fstab content before sed execution
    display_alert "secure-uboot" "fstab content before sed execution:" "info"
    cat "${fstab_file}" 2>/dev/null || true

    # Create backup
    cp "${fstab_file}" "${fstab_file}.bak" 2>/dev/null || true

    # Remove lines containing /boot
    sed -i '\|/boot|d' "${fstab_file}" 2>/dev/null || true

    # Print fstab content after sed execution
    display_alert "secure-uboot" "fstab content after sed execution:" "info"
    cat "${fstab_file}" 2>/dev/null || true

    # Verify and clean up
    if ! grep -q "/boot" "${fstab_file}" 2>/dev/null; then
        rm -f "${fstab_file}.bak" 2>/dev/null || true
        display_alert "secure-uboot" "Successfully removed boot partition mount entries from fstab" "info"
    else
        display_alert "secure-uboot" "Warning: /boot entries still exist in fstab, please check manually" "warn"
    fi
}

function post_umount_final_image__flash_fit_kernel() {
    # After final unmount, write FIT image to boot partition (only in RAW boot mode)
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi
  
    display_alert "fit-flash" "RAW boot mode: Writing FIT image to boot partition" "info"

    local uboot_src="${SRC}/cache/sources/${BOOTSOURCEDIR}"
    local fit_image="${RK_SECURE_BOOT_FIT_IMAGE:-${uboot_src}/fit/boot.itb}"
    local boot_part_index="${RAW_BOOT_PART_INDEX:-1}"
    local boot_dev="${LOOP}p${boot_part_index}"

    display_alert "fit-flash" "Target boot device: ${boot_dev}" "info"

    if [[ ! -f "${fit_image}" ]]; then
        exit_with_error "FIT flash failed: FIT image does not exist" "${fit_image}"
    fi

    [[ -b "${boot_dev}" ]] || exit_with_error "FIT flash failed: target boot partition does not exist" "${boot_dev}"

    display_alert "fit-flash" "dd if="${fit_image}" of="${boot_dev}"" "info"
    dd if="${fit_image}" of="${boot_dev}" conv=fsync || exit_with_error "FIT flash failed: dd write error" "${boot_dev}"

    sync
    display_alert "fit-flash" "FIT image write completed" "info"

}

# Modify partition settings to use RAW boot partition
function pre_prepare_partitions__set_raw_boot_partition() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    display_alert "secure-uboot" "Enabling RAW boot partition mode" "info"

    BOOTPART_REQUIRED="yes"

    # Ensure boot partition has enough space (set to 256 MiB)
    export BOOTSIZE=256
    display_alert "secure-uboot" "Forcing boot partition size: ${BOOTSIZE} MiB" "info"

    # Disable standard boot filesystem handling
    export BOOT_RAW_MODE="yes"
}

# Modify partition name and label
function pre_prepare_partitions__change_boot_partition_name() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    modify_boot_partition_name
    mkopts_label[ext4]=" -U 0b06166d-3930-4176-b30a-900806bd6202 -L  "

}


# Skip standard boot partition mount and copy
function post_create_partitions__handle_raw_boot() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    display_alert "secure-uboot" "RAW boot mode: Save bootpart index and prevent filesystem creation" "debug"

    # Ensure BOOTSIZE is set
    if [[ -z "${BOOTSIZE}" ]]; then
        export BOOTSIZE=256
        display_alert "secure-uboot" "Setting default BOOTSIZE=${BOOTSIZE} MiB" "info"
    fi

    # Save original bootpart index for later dd write
    export RAW_BOOT_PART_INDEX="${bootpart}"
    display_alert "secure-uboot" "Saved boot partition index: ${RAW_BOOT_PART_INDEX}" "debug"

    # Delay clearing bootpart variable, clear it in mount_chroot_script stage
    # This ensures correct use of BOOTSIZE during partition creation

}

# Clear bootpart variable before mounting rootfs
function pre_mount_chroot_script__delayed_raw_boot_cleanup() {
    if ! rk_full_secure_boot_enabled; then
        return 0
    fi

    # Delay clearing bootpart to prevent subsequent filesystem creation and mount
    if [[ "${BOOT_RAW_MODE}" == "yes" ]]; then
        display_alert "secure-uboot" "Delayed cleanup: Clearing bootpart variable" "debug"
        bootpart=""
    fi
}
