#!/bin/bash
#
# armbian-ota-common.sh - Common functions for AB partition OTA
#

# Configuration
OTA_STATE_DIR="/var/lib/armbian-ota"
OTA_STATE_FILE="${OTA_STATE_DIR}/state"
OTA_WORK_DIR="/ota_work"
OTA_LOCK_FILE="/var/run/armbian-ota.lock"
LOG_DIR="/var/log/armbian-ota"
LOG_FILE="${LOG_DIR}/ota.log"

# Partition labels
BOOT_A_LABEL="armbi_boota"
BOOT_B_LABEL="armbi_bootb"
ROOT_A_LABEL="armbi_roota"
ROOT_B_LABEL="armbi_rootb"
USERDATA_LABEL="armbi_usrdata"

# ===== Logging functions =====
init_logging() {
    mkdir -p "${LOG_DIR}"
}

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "${LOG_FILE}" 2>/dev/null
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_debug() {
    if [ "${AB_OTA_DEBUG:-0}" = "1" ]; then
        log "DEBUG" "$@"
    fi
}

# ===== Lock management =====
acquire_lock() {
    if [ -f "${OTA_LOCK_FILE}" ]; then
        local lock_pid=$(cat "${OTA_LOCK_FILE}" 2>/dev/null)
        if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_error "Another OTA process is running (PID: ${lock_pid})"
            return 1
        fi
        log_warn "Removing stale lock file"
        rm -f "${OTA_LOCK_FILE}"
    fi

    echo $$ > "${OTA_LOCK_FILE}"
    trap 'release_lock' EXIT
    return 0
}

release_lock() {
    rm -f "${OTA_LOCK_FILE}" 2>/dev/null
}

# ===== Partition operations =====
get_part_by_label() {
    local label="$1"
    blkid -t LABEL="$label" -o device 2>/dev/null | head -n1
}

get_uuid_by_label() {
    local label="$1"
    blkid -t LABEL="$label" -o value -s UUID 2>/dev/null | head -n1
}

get_part_type() {
    local dev="$1"
    blkid -o value -s TYPE "$dev" 2>/dev/null
}

# ===== Slot management =====
get_current_slot() {
    # Try to get from mount points first
    local root_dev=""

    # Try to find the actual root device (handles overlayfs)
    # Check if /media/root-ro exists (overlayfs lower layer)
    if findmnt -n /media/root-ro >/dev/null 2>&1; then
        root_dev=$(findmnt -n -o SOURCE /media/root-ro)
    fi

    # Fallback to normal root mount
    if [ -z "${root_dev}" ]; then
        root_dev=$(findmnt -n -o SOURCE /)
    fi

    # If still empty, try to get from df
    if [ -z "${root_dev}" ]; then
        root_dev=$(df / | awk 'NR==2 {print $1}')
    fi

    if [ -n "${root_dev}" ]; then
        # Get UUID from device (handles various device path formats)
        # Use -p option to follow symlinks
        local root_uuid=$(blkid -o value -s UUID "$root_dev" 2>/dev/null)
        local root_a_uuid=$(get_uuid_by_label "$ROOT_A_LABEL")
        local root_b_uuid=$(get_uuid_by_label "$ROOT_B_LABEL")

        if [ "${AB_OTA_DEBUG:-0}" = "1" ]; then
            echo "DEBUG: root_dev=$root_dev" >&2
            echo "DEBUG: root_uuid=$root_uuid" >&2
            echo "DEBUG: root_a_uuid=$root_a_uuid" >&2
            echo "DEBUG: root_b_uuid=$root_b_uuid" >&2
        fi

        if [ -n "${root_uuid}" ] && [ -n "${root_a_uuid}" ] && [ "${root_uuid}" = "${root_a_uuid}" ]; then
            echo "a"
            return 0
        elif [ -n "${root_uuid}" ] && [ -n "${root_b_uuid}" ] && [ "${root_uuid}" = "${root_b_uuid}" ]; then
            echo "b"
            return 0
        fi
    fi

    # Fallback to u-boot env (may not reflect current running slot)
    fw_printenv -n boot_slot 2>/dev/null || echo "a"
}

get_target_slot() {
    local current=$(get_current_slot)
    if [ "$current" = "a" ]; then
        echo "b"
    else
        echo "a"
    fi
}

get_slot_boot_label() {
    local slot="$1"
    if [ "$slot" = "a" ]; then
        echo "$BOOT_A_LABEL"
    else
        echo "$BOOT_B_LABEL"
    fi
}

get_slot_root_label() {
    local slot="$1"
    if [ "$slot" = "a" ]; then
        echo "$ROOT_A_LABEL"
    else
        echo "$ROOT_B_LABEL"
    fi
}

# ===== State management =====
init_state_dir() {
    mkdir -p "${OTA_STATE_DIR}"
}

read_state() {
    local key="$1"
    if [ -f "${OTA_STATE_FILE}" ]; then
        grep "^${key}=" "${OTA_STATE_FILE}" 2>/dev/null | cut -d'=' -f2-
    fi
}

write_state() {
    local key="$1"
    local value="$2"
    init_state_dir

    # Create state file if not exists
    if [ ! -f "${OTA_STATE_FILE}" ]; then
        cat > "${OTA_STATE_FILE}" << 'EOF'
# Armbian AB OTA State File
# DO NOT EDIT MANUALLY

[ota]
active_slot=a
target_slot=b
status=idle
try_count=0
max_tries=3
current_version=unknown
target_version=unknown
ota_package_sha256=
start_time=
complete_time=
boot_success_slot=a
EOF
    fi

    # Update the key value
    if grep -q "^${key}=" "${OTA_STATE_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${OTA_STATE_FILE}"
    else
        echo "${key}=${value}" >> "${OTA_STATE_FILE}"
    fi
}

get_ota_status() {
    read_state "status"
}

is_ota_in_progress() {
    local status=$(get_ota_status)
    [ "$status" = "applying" ] || [ "$status" = "ready_to_boot" ]
}

# ===== Version management =====
get_current_version() {
    if [ -f /etc/armbian-release ]; then
        grep ^VERSION= /etc/armbian-release 2>/dev/null | cut -d'=' -f2 | tr -d '"'
    elif [ -f /etc/os-release ]; then
        grep ^VERSION_ID= /etc/os-release 2>/dev/null | cut -d'=' -f2 | tr -d '"'
    else
        echo "unknown"
    fi
}

extract_ota_version() {
    local ota_package="$1"
    # Extract version from package name: Armbian_23.08.0-trunk_...-OTA.tar.gz
    basename "$ota_package" | sed -E 's/.*_[0-9]+\.[0-9]+\.[0-9]+.*/\0/' | head -n1
}

# ===== SHA256 verification =====
verify_sha256() {
    local payload="$1"
    local sha_file="$2"
    local label="${3:-payload}"

    if [ ! -f "${payload}" ]; then
        log_error "Missing ${label}: ${payload}"
        return 1
    fi

    if [ ! -f "${sha_file}" ]; then
        log_warn "Missing checksum file: ${sha_file}"
        return 1
    fi

    if ! command -v sha256sum >/dev/null 2>&1; then
        log_error "sha256sum not found"
        return 1
    fi

    local payload_dir
    payload_dir="$(cd "$(dirname "${payload}")" && pwd)"
    local payload_base
    payload_base="$(basename "${payload}")"
    local sha_dir
    sha_dir="$(cd "$(dirname "${sha_file}")" && pwd)"
    local sha_base
    sha_base="$(basename "${sha_file}")"

    # Create temp checksum file with correct filename if needed
    local tmp_sha=""
    if ! grep -qE "[[:space:]]${payload_base}$" "${sha_dir}/${sha_base}"; then
        tmp_sha="$(mktemp)"
        awk -v f="${payload_base}" '{print $1"  "f}' "${sha_dir}/${sha_base}" > "${tmp_sha}" || {
            log_error "Failed to create checksum file"
            return 1
        }
    fi

    log_info "Verifying ${label} SHA256..."
    if [ -n "${tmp_sha}" ]; then
        if (cd "${payload_dir}" && sha256sum -c "${tmp_sha}" >/dev/null 2>&1); then
            rm -f "${tmp_sha}"
            log_info "${label} SHA256 OK"
            return 0
        else
            rm -f "${tmp_sha}"
            log_error "${label} SHA256 verification failed"
            return 1
        fi
    else
        if (cd "${payload_dir}" && sha256sum -c "${sha_dir}/${sha_base}" >/dev/null 2>&1); then
            log_info "${label} SHA256 OK"
            return 0
        else
            log_error "${label} SHA256 verification failed"
            return 1
        fi
    fi
}

# ===== Error handling =====
error_exit() {
    log_error "$@"
    exit 1
}

# ===== Check dependencies =====
check_dependencies() {
    local missing=0

    for cmd in fw_printenv fw_setenv blkid tar; do
        if ! command -v $cmd >/dev/null 2>&1; then
            log_error "Missing required command: $cmd"
            missing=1
        fi
    done

    if [ $missing -eq 1 ]; then
        return 1
    fi
    return 0
}

# Note: Functions are available in the current shell after sourcing
# No export needed when this file is sourced with '.' or 'source'
