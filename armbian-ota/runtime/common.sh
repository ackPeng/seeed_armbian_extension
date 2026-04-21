#!/bin/bash

OTA_STATE_DIR="${OTA_STATE_DIR:-/var/lib/armbian-ota}"
OTA_STATE_FILE="${OTA_STATE_FILE:-${OTA_STATE_DIR}/state.env}"
OTA_WORK_DIR="${OTA_WORK_DIR:-/ota_work}"
OTA_LOCK_FILE="${OTA_LOCK_FILE:-/var/run/armbian-ota.lock}"
OTA_LOG_DIR="${OTA_LOG_DIR:-/var/log/armbian-ota}"
OTA_LOG_FILE="${OTA_LOG_FILE:-${OTA_LOG_DIR}/ota.log}"

init_logging() {
    mkdir -p "${OTA_LOG_DIR}" "${OTA_STATE_DIR}"
}

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] $*" | tee -a "${OTA_LOG_FILE}" 2>/dev/null
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

error_exit() {
    log_error "$@"
    exit 1
}

ensure_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        error_exit "This command must be run as root"
    fi
}

release_lock() {
    rm -f "${OTA_LOCK_FILE}" 2>/dev/null
}

acquire_lock() {
    if [ -f "${OTA_LOCK_FILE}" ]; then
        local lock_pid
        lock_pid="$(cat "${OTA_LOCK_FILE}" 2>/dev/null)"
        if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
            log_error "Another OTA process is running (PID: ${lock_pid})"
            return 1
        fi
        log_warn "Removing stale lock file"
        rm -f "${OTA_LOCK_FILE}"
    fi

    echo $$ > "${OTA_LOCK_FILE}"
    trap 'release_lock' EXIT
}

ensure_command() {
    local cmd
    for cmd in "$@"; do
        command -v "${cmd}" >/dev/null 2>&1 || error_exit "Missing required command: ${cmd}"
    done
}

state_init() {
    mkdir -p "${OTA_STATE_DIR}" 2>/dev/null || return 0
    if [ ! -f "${OTA_STATE_FILE}" ]; then
        cat > "${OTA_STATE_FILE}" 2>/dev/null <<'EOF' || true
# Armbian OTA runtime state
OTA_MODE=
STATUS=idle
PACKAGE_PATH=
CURRENT_SLOT=
TARGET_SLOT=
START_TIME=
COMPLETE_TIME=
EOF
    fi
}

state_get() {
    local key="$1"
    if [ -f "${OTA_STATE_FILE}" ]; then
        grep -E "^${key}=" "${OTA_STATE_FILE}" 2>/dev/null | tail -n1 | cut -d'=' -f2-
    fi
}

state_set() {
    local key="$1"
    local value="$2"
    state_init
    if grep -q -E "^${key}=" "${OTA_STATE_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${OTA_STATE_FILE}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${OTA_STATE_FILE}"
    fi
}

state_mark_mode() {
    state_set "OTA_MODE" "$1"
}

state_mark_status() {
    state_set "STATUS" "$1"
}

state_clear_runtime_fields() {
    state_init
    state_set "PACKAGE_PATH" ""
    state_set "CURRENT_SLOT" ""
    state_set "TARGET_SLOT" ""
    state_set "START_TIME" ""
    state_set "COMPLETE_TIME" ""
}

read_package_manifest_value() {
    local package_path="$1"
    local key="$2"
    local manifest_entry

    manifest_entry="$(
        tar -tzf "${package_path}" 2>/dev/null \
            | awk '/(^|\/)ota_manifest\.env$/ { print; exit }'
    )"
    if [ -z "${manifest_entry}" ]; then
        return 1
    fi

    tar -xOf "${package_path}" "${manifest_entry}" 2>/dev/null \
        | grep -E "^${key}=" | tail -n1 | cut -d'=' -f2-
}

assert_package_mode_matches() {
    local package_path="$1"
    local expected_mode="$2"
    local manifest_mode

    manifest_mode="$(read_package_manifest_value "${package_path}" "OTA_MODE" || true)"
    if [ -z "${manifest_mode}" ]; then
        error_exit "OTA package metadata missing OTA_MODE; refusing to continue with --mode=${expected_mode}"
    fi

    case "${manifest_mode}" in
        ab|recovery) ;;
        *)
            error_exit "Invalid OTA_MODE in package metadata: ${manifest_mode} (expected ab or recovery)"
            ;;
    esac

    if [ "${expected_mode}" != "ab" ] && [ "${expected_mode}" != "recovery" ]; then
        error_exit "Invalid requested OTA mode: ${expected_mode}"
    fi

    if [ "${manifest_mode}" != "${expected_mode}" ]; then
        error_exit "OTA package mode mismatch: expected ${expected_mode}, manifest=${manifest_mode}"
    fi
}

verify_sha256() {
    local payload="$1"
    local sha_file="$2"
    local label="${3:-payload}"

    [ -f "${payload}" ] || error_exit "Missing ${label}: ${payload}"
    [ -f "${sha_file}" ] || error_exit "Missing checksum file: ${sha_file}"
    ensure_command sha256sum

    local payload_dir payload_base sha_dir sha_base tmp_sha
    payload_dir="$(cd "$(dirname "${payload}")" && pwd)"
    payload_base="$(basename "${payload}")"
    sha_dir="$(cd "$(dirname "${sha_file}")" && pwd)"
    sha_base="$(basename "${sha_file}")"
    tmp_sha=""

    if ! grep -qE "[[:space:]]${payload_base}$" "${sha_dir}/${sha_base}"; then
        tmp_sha="$(mktemp)"
        awk -v f="${payload_base}" '{print $1"  "f}' "${sha_dir}/${sha_base}" > "${tmp_sha}" || error_exit "Failed to rewrite checksum file for ${label}"
    fi

    log_info "Verifying ${label} checksum"
    if [ -n "${tmp_sha}" ]; then
        (cd "${payload_dir}" && sha256sum -c "${tmp_sha}" >/dev/null 2>&1) || {
            rm -f "${tmp_sha}"
            error_exit "${label} checksum verification failed"
        }
        rm -f "${tmp_sha}"
    else
        (cd "${payload_dir}" && sha256sum -c "${sha_dir}/${sha_base}" >/dev/null 2>&1) || error_exit "${label} checksum verification failed"
    fi
}

detect_kver() {
    local files newest base
    files=(/boot/initrd.img-*)

    if [ ! -e "${files[0]}" ]; then
        error_exit "No initrd.img-* found under /boot"
    fi

    if [ "${#files[@]}" -eq 1 ]; then
        base="$(basename "${files[0]}")"
        echo "${base#initrd.img-}"
        return 0
    fi

    if [ -f "/boot/initrd.img-$(uname -r)" ]; then
        echo "$(uname -r)"
        return 0
    fi

    newest="$(ls -1t /boot/initrd.img-* 2>/dev/null | head -n1 || true)"
    [ -n "${newest}" ] || error_exit "Failed to determine kernel version"
    base="$(basename "${newest}")"
    echo "${base#initrd.img-}"
}

extract_ota_package() {
    local package_path="$1"
    local dest_dir="$2"

    rm -rf "${dest_dir}"
    mkdir -p "${dest_dir}"
    tar -xzf "${package_path}" -C "${dest_dir}" || error_exit "Failed to extract OTA package: ${package_path}"
}

runtime_dir() {
    echo "${OTA_RUNTIME_DIR}"
}

installed_recovery_asset_dir() {
    local dir
    dir="$(runtime_dir)"
    if [ -d "${dir}/recovery" ]; then
        echo "${dir}/recovery"
    else
        echo "${dir}/../recovery_ota"
    fi
}
