#!/usr/bin/env bash

set -uo pipefail

VRS="v5.6.1"

##############################################
# Script to create & mount a LUKS container. #
# Supports multiple file containers (.bin)   #
# Block devices (partitions) unsupported.    #
##############################################

# Supported distros:
# Debian-based (eg. Ubuntu, Mint, Zorin, PopOS etc)
# Arch
# Manjaro


# ===========================================================================
# Colours & effects
# ===========================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
GRAY='\033[90m'
MAGENTA='\e[35m'
UNDERLINE='\033[4m'
BOLD='\033[1m'
NC='\033[0m' # Reset (no color)


# ===========================================================================
# Information display prompts
# ===========================================================================
d_ok()   { echo -e "${BOLD}${GREEN}[✓]${NC} ${GREEN}$*${NC}"; }
d_step() { echo -e "${BOLD}${BLUE}▶  $*  ◀${NC}"; }
d_info() { echo -e "${BOLD}${MAGENTA}[i]${NC} $*"; }
d_warn() { echo -e "${BOLD}${YELLOW}[!]${NC} ${YELLOW}$*${NC}"; }
d_err()  { echo -e "\n${BOLD}${RED}[✗]${NC} ${RED}$*${NC}\n"; }
d_exit() { echo -e "\n${BOLD}${BLUE}$*${NC}\n"; }


# ===========================================================================
# Global variables
# ===========================================================================
CONT_FILES=()

TMP_MOUNT=""
TMP_MAPPER_NAME=""

loop_dev=""
find_cont_path=""
files_list=""
manual_cont_path=""

container_path=""
MOUNT_PATH=""
CONT_NAME=""
CONT_ALIAS=""
CONT_TARGET=""
CONT_PATH=""
dest_path=""

LUKS_HEADER_SIZE="16"
TOTAL_REAL_SIZE="0"
FS_SIZE_MB="0"
DISPLAY_KEYSLOTS_COUNT="0"
CALC_MIN_SIZE="0"
CALC_RESIZE2FS_MIN_MB="0"
CALC_SAFETY_LEVEL=""
CALC_CONT_SIZE_MB="0"
CALC_CONT_SIZE_BYTES="0"
RESIZE2FS_MIN_BLOCKS=""
BLOCK_SIZE=""
ACTUAL_BLOCKS_MB=""

USE_KEYFILE="false"
keyfile_path=""
keyfile_name=""
keyfile_dir=""
backup_path=""
backup_file=""
container=""
mounted_flag="false"
HEADER_SET="false"


# ===========================================================================
# Platform detection for correct package manager
# ===========================================================================
PKG_MANAGER=""
PKG_INSTALL=""

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_INSTALL="apt-get install -y"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
        PKG_INSTALL="pacman -S --noconfirm --needed"
    else
        PKG_MANAGER=""
        PKG_INSTALL=""
    fi
}


# ===========================================================================
# Sudo / doas shim (Arch minimal installs sometimes don't have sudo)
# ===========================================================================
if ! command -v sudo >/dev/null 2>&1; then
    if command -v doas >/dev/null 2>&1; then
        sudo() { doas "$@"; }
    else
        printf 'Error: neither sudo nor doas found. Install one to proceed.\n' >&2
        exit 1
    fi
fi


# ===========================================================================
# Secure temporary dir
# ===========================================================================
TMP_MOUNT=$(mktemp -d "${TMPDIR:-/tmp}/luks_mnt.XXXXXX") || {
    printf '%b\n' "${RED}Error: Failed to create secure temporary directory${NC}" >&2
    exit 1
}

if command -v openssl >/dev/null 2>&1; then
    RAND_HEX=$(openssl rand -hex 4)
else
    RAND_HEX=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 8)
fi
TMP_MAPPER_NAME="luks_tmp_${RAND_HEX}"


# ===========================================================================
# Cleanup on error / forced exit
# ===========================================================================
cleanup() {
    local exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        [[ -n "${CONT_ALIAS}" ]] && cryptsetup luksClose "${CONT_ALIAS}" 2>/dev/null
        [[ -n "$loop_dev" ]] && losetup -d "$loop_dev" 2>/dev/null
        return "$exit_code"
    fi

    local cleanup_errors="0"

    if [[ -n "${MOUNT_PATH}" ]] && mountpoint -q "${MOUNT_PATH}" 2>/dev/null; then
        if ! umount "${MOUNT_PATH}" 2>/dev/null; then
            d_warn "Warning: Failed to unmount ${MOUNT_PATH}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if mountpoint -q "${TMP_MOUNT}" 2>/dev/null; then
        if ! umount "${TMP_MOUNT}" 2>/dev/null; then
            d_warn "Warning: Failed to unmount ${TMP_MOUNT}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if [[ -n "${CONT_ALIAS}" ]]; then
        if cryptsetup status "${CONT_ALIAS}" &>/dev/null; then
            if ! cryptsetup luksClose "${CONT_ALIAS}" 2>/dev/null; then
                d_warn "Warning: Failed to close ${CONT_ALIAS}" >&2
                cleanup_errors=$((cleanup_errors + 1))
            fi
        fi
    fi

    if cryptsetup status "${TMP_MAPPER_NAME}" &>/dev/null; then
        if ! cryptsetup luksClose "${TMP_MAPPER_NAME}" 2>/dev/null; then
            d_warn "Warning: Failed to close ${TMP_MAPPER_NAME}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if [[ -n "$loop_dev" ]]; then
        if ! losetup -d "$loop_dev" 2>/dev/null; then
            d_warn "Warning: Failed to detach loop device" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    # Delete temp dir/files
    if [[ -d "${TMP_MOUNT}" ]]; then
        if ! rm -rf "${TMP_MOUNT}" 2>/dev/null; then
            d_warn "Warning: Failed to remove temp directory ${TMP_MOUNT}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi

        if ! rm -rf "/tmp/luks_mnt_"* 2>/dev/null; then
            d_warn "Warning: Failed to remove temp directory ${TMP_MOUNT}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if [[ "$cleanup_errors" -gt "0" ]]; then
        echo -e "${RED}Cleanup completed with $cleanup_errors errors. Manual intervention may be required.${NC}" >&2
        echo -e "${YELLOW}List any pre-existing containers:${NC}"
        echo -e "  ls /dev/mapper"
        echo -e "${YELLOW}Close any existing containers:${NC}"
        echo -e "  sudo cryptsetup close <mapper-alias>"
        echo -e "${YELLOW}Check for existing loop devices:${NC}"
        echo -e "  sudo losetup -l"
        echo -e "${YELLOW}Detach open loop devices:${NC}"
        echo -e "  sudo losetup -d <loop-device>\n"
    fi

    # Clear variables for security
    CONT_FILES=()
    loop_dev=""
    MOUNT_PATH=""
    TMP_MOUNT=""
    TMP_MAPPER_NAME=""
    files_list=""
    manual_cont_path=""
    CONT_NAME=""
    CONT_ALIAS=""
    CONT_TARGET=""
    CONT_PATH=""
    dest_path=""
    keyfile_path=""
    keyfile_name=""
    keyfile_dir=""
    backup_path=""
    backup_file=""
    container=""

    exit "$exit_code"
}

trap cleanup EXIT

# ===========================================================================
# Sudo permissions check
# ===========================================================================
check_privileges() {
    if ! sudo -n true 2>/dev/null; then
        d_warn "Note: This script requires sudo privileges. You may be prompted for your password."
    fi
}

# ===========================================================================
# Check available disk space
# ===========================================================================
check_disk_space() {
    local target_dir="$1"
    local required_mb="$2"
    local available_mb
    local buffer_mb
    local total_required_mb

    available_mb=$(df --output=avail -B 1M "${target_dir}" | tail -n 1)
    buffer_mb=$((required_mb * 2 / 100))
    total_required_mb=$((required_mb + buffer_mb))

    echo -e "\n🔎 ${BLUE}Checking disk space...${NC}"
    echo -e "   Required: ${required_mb} MB"
    echo -e "   Buffer ${BOLD}(2%)${NC}: ${buffer_mb} MB"
    echo -e "   Total needed: ${total_required_mb} MB"
    echo -e "   Available: ${available_mb} MB\n"

    if (( available_mb < total_required_mb )); then
        d_err "Error: Insufficient disk space:"
        echo -e "  Need: ${total_required_mb} MB${NC}"
        echo -e "  Available: ${available_mb} MB${NC}"
        echo -e "  Shortage: ${YELLOW}$((total_required_mb - available_mb)) MB${NC}"
        return 1
    fi

    d_ok "Sufficient disk space available"
    return 0
}

# ===========================================================================
# Find existing container
# ===========================================================================
find_con() {
    local find_cont_path
    local files_list

    echo
    read -rp "Specify LUKS container directory (eg. /home/user): " find_cont_path

    [[ ! "${find_cont_path}" =~ ^[a-zA-Z0-9_./-]+$ ]] && {
        d_err "Error: Path contains invalid characters. Use only letters, numbers, underscores, dots, slashes, and hyphens." >&2
        exit 1
    }
    [[ ! -d "${find_cont_path}" ]] && {
        d_err "Error: ${CYAN}'${find_cont_path}'${NC} is not a valid directory. Script will exit." >&2
        exit 1
    }
    [[ ! -r "${find_cont_path}" ]] && {
        d_err "Error: ${CYAN}'${find_cont_path}'${NC} is not readable. Please check directory permissions" >&2
        exit 1
    }

    CONT_FILES=()

    while IFS= read -r -d '' files_list; do
        if cryptsetup isLuks "$files_list" 2>/dev/null; then
            CONT_FILES+=("$files_list")
        fi
    done < <(find "${find_cont_path}" -maxdepth 1 -type f -size +16M -print0 2>/dev/null)

    [[ ${#CONT_FILES[@]} -eq "0" ]] && {
        d_exit "No LUKS-encrypted containers found in '${find_cont_path}'"
        exit 1
    }

    echo -e "\n═════════════════════════════════════════════════════════"
    echo -e "${YELLOW}Select LUKS container${NC}"
    echo -e "═════════════════════════════════════════════════════════\n"
    PS3=$'\nOption: '
    select CONT_TARGET in "${CONT_FILES[@]}" "Exit"; do
        [[ "$CONT_TARGET" == "Exit" ]] && {
            d_exit "No LUKS container selected. Script will exit here."
            exit 1
        }

        if [[ -n "$CONT_TARGET" ]]; then
            echo -e "${CYAN}'$CONT_TARGET'${NC} container selected."
            break
        else
            d_err "Invalid selection. Please choose a number from the list."
        fi
    done
}

# ===========================================================================
# Find container manually
# ===========================================================================
find_container_manually() {
    local manual_cont_path

    while true; do
        echo
        read -rp "Specify full path to LUKS container (eg. /home/user/luks.bin): " manual_cont_path
        if [[ ! -f "${manual_cont_path}" ]]; then
            echo -e "${RED}Error:${NC} Cannot find LUKS container.\nCheck if path is valid, file exits and is readable."
        else
            break
        fi
    done

    CONT_TARGET="$manual_cont_path"
}

# ===========================================================================
# Mount and verify container before resize
# ===========================================================================
verify_and_mount_container() {
    local container_path="$1"
    local fs_size
    local block_size
    local fs_size_mb
    local total_real_size
    local actual_blocks
    local loop_dev
    local attached_file
    local e2fsck_result
    local resize2fs_min_output

    [[ ! -f "${container_path}" ]] && {
        d_err "Error: Container file not found"
        exit 1
    }

    if ! findmnt "/dev/mapper/${TMP_MAPPER_NAME}" &>/dev/null; then
        if ! loop_dev=$(losetup -f --show --direct-io=on "${container_path}" 2>/dev/null) || [[ -z "$loop_dev" ]]; then
            d_err "Error: Failed to get loop device"
            exit 1
        fi

        attached_file=$(losetup -l "$loop_dev" 2>/dev/null | awk 'NR==2 {print $6}')
        if [[ "${attached_file}" != "${container_path}" ]]; then
            d_err "Error: Loop device verification failed!"
            losetup -d "$loop_dev" 2>/dev/null || true
            loop_dev=""
            exit 1
        fi

        if ! cryptsetup luksOpen "$loop_dev" "${TMP_MAPPER_NAME}"; then
            d_err "Error: Failed to open LUKS container! Wrong password or corrupted container."
            error_detach
            exit 1
        fi
    fi

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "Verifying container integrity..."
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

    echo -e "Running filesystem check (auto-fix)..."
    e2fsck -fy "/dev/mapper/${TMP_MAPPER_NAME}"
    e2fsck_result=$?
    if [[ "$e2fsck_result" -gt "2" ]]; then
        d_err "Error: Filesystem check failed (exit code: $e2fsck_result)! Container may be corrupted."
        echo -e "${YELLOW}Try running manually: sudo e2fsck -f /dev/mapper/${TMP_MAPPER_NAME}${NC}\n"
        error_detach
        exit 1
    fi
    d_ok "Filesystem check completed."

    echo -e "Querying resize2fs for absolute minimum size..."
    resize2fs_min_output=$(resize2fs -P "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null)
    RESIZE2FS_MIN_BLOCKS=$(echo "$resize2fs_min_output" | awk '/minimum size/{print $NF}')
    if [[ -n "$RESIZE2FS_MIN_BLOCKS" ]] && [[ "$RESIZE2FS_MIN_BLOCKS" =~ ^[0-9]+$ ]]; then
        echo -e "  resize2fs minimum: ${GRAY}${RESIZE2FS_MIN_BLOCKS} blocks${NC}"
    else
        d_warn "Warning: Could not query resize2fs minimum"
        RESIZE2FS_MIN_BLOCKS=""
    fi

    fs_size=$(dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
    block_size=$(dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block size" | awk '{print $3}')

    if [[ -z "$fs_size" ]] || [[ -z "$block_size" ]]; then
        d_err "Error: Could not determine filesystem size."
        error_detach
        exit 1
    fi

    fs_size_mb=$(( fs_size * block_size / 1024 / 1024 ))

    [[ ! -d "${TMP_MOUNT}" ]] && mkdir -p "${TMP_MOUNT}"

    echo -e "Mounting temporarily to check data size..."
    if ! mount "/dev/mapper/${TMP_MAPPER_NAME}" "${TMP_MOUNT}"; then
        d_err"Error: Failed to mount LUKS container!"
        error_detach
        exit 1
    fi

    total_real_size=$(du --apparent-size -smc "${TMP_MOUNT}" 2>/dev/null | grep total | awk '{print $1}')
    actual_blocks=$(du -smc "${TMP_MOUNT}" 2>/dev/null | grep total | awk '{print $1}')

    if [[ -z "$total_real_size" ]] || [[ "$total_real_size" -eq "0" ]]; then
        total_real_size=$(du -smc "${TMP_MOUNT}" 2>/dev/null | grep total | awk '{print $1}')
        actual_blocks="$total_real_size"
    fi

    if findmnt "/dev/mapper/${TMP_MAPPER_NAME}" &>/dev/null; then
        umount "${TMP_MOUNT}" 2>/dev/null || umount -l "${TMP_MOUNT}" 2>/dev/null
        rm -rf "${TMP_MOUNT}" 2>/dev/null
    fi

    d_ok "Container verified."

    echo
    echo -e "  Current filesystem size: ${fs_size_mb} MB"
    echo -e "  Current data size (apparent): ${total_real_size} MB"
    if [[ -n "$actual_blocks" ]] && [[ "$actual_blocks" -ne "$total_real_size" ]]; then
        echo -e "  Current data size (actual blocks): ${YELLOW}${actual_blocks} MB${NC}"
        echo -e "  Block overhead: ${GRAY}$((actual_blocks - total_real_size)) MB${NC}"
    fi

    # Close and unmount container before exit
    cryptsetup luksClose "${TMP_MAPPER_NAME}" 2>/dev/null
    losetup -d "$loop_dev" 2>/dev/null
    loop_dev=""

    TOTAL_REAL_SIZE="$total_real_size"
    FS_SIZE_MB="$fs_size_mb"
    BLOCK_SIZE="$block_size"
    ACTUAL_BLOCKS_MB="$actual_blocks"

    return 0
}

# ===========================================================================
# Calculate minimum safe container size for shrinking
# ===========================================================================
calculate_min_safe_size() {
    local fs_size_mb="$1"
    local data_size_mb="$2"
    local resize2fs_min_blocks="$RESIZE2FS_MIN_BLOCKS"

    if [[ -z "$fs_size_mb" ]] || [[ -z "$data_size_mb" ]]; then
        d_err "Error: Missing required parameters"
        return 1
    fi
    if [[ ! "$fs_size_mb" =~ ^[0-9]+$ ]] || [[ ! "$data_size_mb" =~ ^[0-9]+$ ]]; then
        d_err "Error: Size values must be positive integers"
        return 1
    fi
    if [[ "$data_size_mb" -gt "$fs_size_mb" ]]; then
        d_err  "Error: Data size cannot exceed filesystem size"
        return 1
    fi
    if [[ "$fs_size_mb" -eq "0" ]]; then
        d_err "Error: Filesystem size cannot be zero"
        return 1
    fi

    if [[ -z "$resize2fs_min_blocks" ]] || [[ "$resize2fs_min_blocks" -eq "0" ]]; then
        d_err "Error: resize2fs minimum not available. Was 0verify_and_mount_container called first?"
        return 1
    fi

    CALC_RESIZE2FS_MIN_MB=$((resize2fs_min_blocks * BLOCK_SIZE / 1024 / 1024))
    CALC_MIN_SIZE="$CALC_RESIZE2FS_MIN_MB"

    if [[ "$CALC_RESIZE2FS_MIN_MB" -ge "$fs_size_mb" ]]; then
        CALC_SAFETY_LEVEL="CANNOT_SHRINK"
    elif [[ "$CALC_RESIZE2FS_MIN_MB" -gt $((fs_size_mb * 3 / 4)) ]]; then
        CALC_SAFETY_LEVEL="AGGRESSIVE"
    else
        CALC_SAFETY_LEVEL="SAFE"
    fi

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    echo -e "${BLUE} Shrink Size Analysis${NC}"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"
    echo -e "  Current container size:      ${CALC_CONT_SIZE_MB} MB"
    echo -e "  Current filesystem size:     ${fs_size_mb} MB"
    echo -e "  Data content (apparent):     ${YELLOW}${data_size_mb} MB${NC}"
    if [[ -n "$ACTUAL_BLOCKS_MB" ]] && [[ "$ACTUAL_BLOCKS_MB" -gt "$data_size_mb" ]]; then
        echo -e "  Block-level overhead:        ${GRAY}$((ACTUAL_BLOCKS_MB - data_size_mb)) MB${NC}"
    fi
    echo -e "  ─────────────────────────────────────────────"
    echo -e "  ${CYAN}resize2fs absolute minimum:  ${CALC_RESIZE2FS_MIN_MB} MB${NC}"
    echo -e "    (${resize2fs_min_blocks} blocks x ${BLOCK_SIZE} bytes)"
    echo -e "  ─────────────────────────────────────────────"
    echo -e "  ${GREEN}Minimum filesystem size:     ${CALC_MIN_SIZE} MB${NC}"
    echo -e "  ${GRAY}Minimum container size:      $((CALC_MIN_SIZE + LUKS_HEADER_SIZE)) MB${NC}"
    echo -e "  ─────────────────────────────────────────────"

    case "$CALC_SAFETY_LEVEL" in
        "SAFE")
            echo -e "  Shrink headroom:             ${GREEN}GOOD${NC}"
            ;;
        "AGGRESSIVE")
            echo -e "  Shrink headroom:             ${YELLOW}LIMITED${NC}"
            echo -e "  ${YELLOW}resize2fs minimum exceeds 75% of current size.${NC}"
            echo -e "  ${YELLOW}Only small shrink targets are possible.${NC}"
            ;;
        "CANNOT_SHRINK")
            echo -e "${RED}⛔ CRITICAL: Cannot safely shrink this filesystem.${NC}"
            echo -e "${RED}The resize2fs minimum (${CALC_RESIZE2FS_MIN_MB} MB) already${NC}"
            echo -e "${RED}equals or exceeds the current size (${fs_size_mb} MB).${NC}"
            ;;
    esac

    echo && echo
    echo -e "• Shrinking carries inherent risk of data loss."
    echo -e "• ALWAYS create a backup before proceeding.${NC}"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"

    if [[ "$CALC_SAFETY_LEVEL" == "CANNOT_SHRINK" ]]; then
        d_warn "${YELLOW}Shrinking is not possible for this container!${NC}"
        echo -e "${YELLOW}The filesystem is already at or below its resize2fs${NC}"
        echo -e "${YELLOW}minimum size.${NC}"
        echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"
        echo -e "\n${BLUE}Script will exit${NC}\n"
    fi

    return 0
}

# ===========================================================================
# Unmount & detach on error
# ===========================================================================
error_detach() {
    if mountpoint -q "${TMP_MOUNT}" 2>/dev/null; then
        umount "${TMP_MOUNT}" 2>/dev/null || umount -l "${TMP_MOUNT}" 2>/dev/null
    fi
    if cryptsetup status "${TMP_MAPPER_NAME}" &>/dev/null; then
        cryptsetup luksClose "${TMP_MAPPER_NAME}" 2>/dev/null
    fi
    [[ -n "$loop_dev" ]] && losetup -d "$loop_dev" 2>/dev/null

    # Delete temp dir/files
    { rm -rf "${TMP_MOUNT}" 2>/dev/null; } || \
        d_warn "Warning: Failed to remove temp directory ${TMP_MOUNT}"
    { rm -rf "/tmp/luks_mnt_"* 2>/dev/null; } || \
        d_warn "Warning: Failed to remove temp directory /tmp/luks_mount_xxxx"
}

# ===========================================================================
# Manual mount instructions
# ===========================================================================
manual_mount_instructions() {
    echo -e "\n══════════════════════════════════════════════════════"
    echo -e "${YELLOW}To open and mount:${NC}"
    echo -e "  sudo losetup -f --show </path/to/container.bin>"
    echo -e "  sudo cryptsetup luksOpen <loop-device> <alias> \\"
    echo -e "  ${CYAN}--key-file <keyfile>${NC}"
    echo -e "  sudo mount /dev/mapper/<loop-device> <mount-dir>"
    echo -e "  sudo chown -R <username>:<username> <mount-dir>"
    echo -e "\n${YELLOW}To unmount, close, & detach:${NC}"
    echo -e "  sudo umount <mount-dir>"
    echo -e "  sudo cryptsetup luksClose <alias>"
    echo -e "  sudo losetup -d <loop-device>"
    echo -e "══════════════════════════════════════════════════════\n"
}

# ===========================================================================
# Display keyslot information
# ===========================================================================
display_keyslots() {
    local container_path="$1"
    local luks_dump
    local luks_version
    local enabled_count="0"
    local json_dump
    local slots
    local in_keyslots
    local current_slot
    local line
    local priority
    local slot
    local status
    local slot_num

    luks_dump=$(cryptsetup luksDump "${container_path}" 2>/dev/null)

    if [[ -z "$luks_dump" ]]; then
        d_err "Error: Could not read LUKS header"
        DISPLAY_KEYSLOTS_COUNT="0"
        return 1
    fi

    luks_version=$(echo "$luks_dump" | grep -i "^Version:" | awk '{print $2}')
    echo -e "${CYAN}LUKS Version:${NC} ${luks_version:-Unknown}"

    if [[ "$luks_version" == "2" ]]; then
        echo -e "\n${CYAN}Keyslot Status:${NC}"

        json_dump=$(cryptsetup luksDump --dump-json-metadata "${container_path}" 2>/dev/null)

        if [[ -n "$json_dump" ]] && command -v jq &>/dev/null; then
            slots=$(echo "$json_dump" | jq -r '.keyslots | keys[]' 2>/dev/null)
            if [[ -n "$slots" ]]; then
                for slot in $slots; do
                    priority=$(echo "$json_dump" | jq -r ".keyslots[\"$slot\"].priority // \"normal\"" 2>/dev/null)
                    case "$priority" in
                        normal|prefer)
                            echo -e "  Slot ${slot}: ${GREEN}ENABLED${NC} (Priority: $priority)"
                            enabled_count=$((enabled_count + 1))
                            ;;
                        ignore)
                            echo -e "  Slot ${slot}: ${RED}DISABLED${NC} (Priority: $priority)"
                            ;;
                        *)
                            echo -e "  Slot ${slot}: ${YELLOW}UNKNOWN${NC} (Priority: $priority)"
                            ;;
                    esac
                done
            fi
        else
            in_keyslots="0"
            current_slot=""

            while IFS= read -r line; do
                if [[ "$line" =~ ^Keyslots:$ ]]; then
                    in_keyslots="1"
                    continue
                fi

                if [[ "$in_keyslots" -eq "1" ]] && [[ "$line" =~ ^(Tokens:|Digests:) ]]; then
                    in_keyslots="0"
                    continue
                fi

                if [[ "$in_keyslots" -eq "1" ]]; then
                    if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]+luks2 ]]; then
                        current_slot="${BASH_REMATCH[1]}"
                    fi

                    if [[ -n "$current_slot" ]] && [[ "$line" =~ Priority:[[:space:]]*(.+) ]]; then
                        priority="${BASH_REMATCH[1]}"
                        case "$priority" in
                            normal|prefer)
                                echo -e "  Slot ${current_slot}: ${GREEN}ENABLED${NC} (Priority: $priority)"
                                enabled_count=$((enabled_count + 1))
                                ;;
                            ignore)
                                echo -e "  Slot ${current_slot}: ${RED}DISABLED${NC} (Priority: $priority)"
                                ;;
                            *)
                                echo -e "  Slot ${current_slot}: ${YELLOW}UNKNOWN${NC} (Priority: $priority)"
                                ;;
                        esac
                        current_slot=""
                    fi
                fi
            done <<< "$luks_dump"
        fi
    else
        echo -e "\n${CYAN}Keyslot Status:${NC}"
        while IFS= read -r line; do
            if [[ "$line" =~ ^Key[[:space:]]Slot[[:space:]]([0-9]+):[[:space:]]*(.+) ]]; then
                slot_num="${BASH_REMATCH[1]}"
                status="${BASH_REMATCH[2]}"
                if [[ "$status" == "ENABLED" ]]; then
                    echo -e "  Key Slot ${slot_num}: ${GREEN}ENABLED${NC}"
                    enabled_count=$((enabled_count + 1))
                else
                    echo -e "  Key Slot ${slot_num}: ${RED}DISABLED${NC}"
                fi
            fi
        done <<< "$luks_dump"
    fi

    echo -e "\n${CYAN}Summary:${NC} ${GREEN}${enabled_count} active${NC} keyslot(s) found"

    DISPLAY_KEYSLOTS_COUNT="$enabled_count"
    return 0
}

# ===========================================================================
# Backup LUKS header
# ===========================================================================
backup_luks_header() {
    local container_path="$1"
    local backup_path
    local backup_file

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "LUKS Header Backup"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

    read -rp "Enter backup directory (full path): " backup_path

    if [[ ! "$backup_path" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        d_err "Error: Invalid characters in path"
        return 1
    fi

    if [[ ! -d "$backup_path" ]]; then
        echo -e "${YELLOW}Directory doesn't exist. Creating...${NC}"
        mkdir -p "$backup_path" || { d_err "Failed to create directory."; return 1; }
    fi

    backup_file="$backup_path/$(basename "$container_path")_header_$(date +%Y%m%d).img"

    echo -e "\nBacking up to: ${CYAN}$backup_file${NC}"
    if cryptsetup -q luksHeaderBackup "$container_path" --header-backup-file "$backup_file"; then

        # Set secure permissions
        chmod 600 "$backup_file" 2>/dev/null
        chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$backup_file" 2>/dev/null || \
            chown root:root "$backup_file" 2>/dev/null || true

        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ LUKS header backed up successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "  Backup: ${CYAN}$backup_file${NC}"
        echo -e "  Size: $(sudo stat -c%s "$backup_file" | numfmt --to=iec) bytes"
        echo -e "  Permissions: $(sudo stat -c%a "$backup_file")"
        echo -e "\n${YELLOW}Restore command:${NC}"
        echo -e "  sudo cryptsetup luksHeaderRestore <container> \\"
        echo -e "  --header-backup-file <backup-header>\n"
    else
        d_err "Header backup failed!"
        return 1
    fi
}

# ===========================================================================
# Restore LUKS header
# ===========================================================================
restore_luks_header() {
    local container_path="$1"
    local backup_file=""
    local missing_header_flag=""
    local restore_reply
    local backup_perms
    local backup_size
    local continue_small
    local check_uuid
    local temp_loop
    local backup_uuid

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "LUKS Header Restore"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ ⚠️  CRITICAL WARNING: Header Restore Operation      ║${NC}"
    echo -e "${RED}║                                                    ║${NC}"
    echo -e "${RED}║ Restoring a header will OVERWRITE existing keys!   ║${NC}"
    echo -e "${RED}║ Any passphrases/keyfiles not in the backup will    ║${NC}"
    echo -e "${RED}║ be PERMANENTLY LOST!                               ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}\n"

    sleep 2

    if cryptsetup isLuks "${container_path}"; then
        echo -e "${YELLOW}Current container keyslots:${NC}"
        display_keyslots "${container_path}"
        echo
    else
        echo -e "${YELLOW}Cannot detect if target image is a LUKS container${NC}"
        echo -e "This can mean either:\n 1. Container is corrupted/damaged\n 2. Header is missing"
        echo -e "    (eg. a nuked header for anti-forensics)\n"
        read -rp "Do you want to proceed with header restore attempt? [y/n] " restore_reply
        if [[ ! "${restore_reply,,}" == "y" ]]; then
            d_exit "Header restore cancelled."
            return 1
        fi
        missing_header_flag="1"
    fi

    read -rp "Enter path to header backup file (eg. /home/user/luks-header.img): " backup_file

    if [[ ! "$backup_file" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        d_err "Error: Invalid characters in backup file path."
        return 1
    fi

    if [[ ! -f "$backup_file" ]]; then
        d_err "Error: Backup file '$backup_file' does not exist."
        return 1
    fi

    if [[ ! -r "$backup_file" ]]; then
        d_err "Error: Backup file is not readable. Check permissions."
        return 1
    fi

    backup_perms=$(stat -c%a "$backup_file" 2>/dev/null)
    if [[ -n "$backup_perms" ]] && [[ "$backup_perms" != "600" ]] && [[ "$backup_perms" != "400" ]]; then
        echo -e "\n${YELLOW}Warning:${NC} Backup file permissions are $backup_perms (expected 600 or 400)."
        echo -e "${YELLOW}This may indicate the backup was exposed to other users.${NC}"
        echo -e "${YELLOW}Depending on your security profile, this may or may not be a problem.${NC}"
    fi

    backup_size=$(stat -c%s "$backup_file" 2>/dev/null)
    if [[ "$backup_size" -lt "1048576" ]]; then
        echo -e "\n${YELLOW}Warning:${NC} Backup file is unusually small (${backup_size} bytes)."
        echo -e "A valid LUKS header backup is typically 16-64 MB."
        read -rp "Continue anyway? [y/N]: " continue_small
        if [[ "${continue_small,,}" != "y" ]]; then
            d_exit "Operation cancelled."
            return 0
        fi
    fi

    echo -e "\n${BLUE}Validating backup file...${NC}"
    if cryptsetup isLuks "$backup_file" 2>/dev/null; then
        d_ok "Backup file appears to be a valid LUKS header"
    else
        echo -e "${YELLOW}⚠️ Backup file is not recognized as a standalone LUKS container.${NC}"
        echo -e "${YELLOW}  This is normal if it's a header-only backup.${NC}"
    fi

    if [[ ! "$missing_header_flag" == "1" ]]; then
        echo -e "\n${CYAN}Current container UUID:${NC}"
        cryptsetup luksUUID "${container_path}" 2>/dev/null || echo -e "${YELLOW}Could not read UUID${NC}"

        echo -e "\n${YELLOW}Would you like to verify the backup UUID?${NC}"
        read -rp "This helps ensure you're restoring the correct header [y/N]: " check_uuid
        check_uuid="${check_uuid:-n}"

        if [[ "${check_uuid,,}" == "y" ]]; then
            temp_loop=$(losetup -f --show --read-only "$backup_file" 2>/dev/null)
            if [[ -n "$temp_loop" ]]; then
                backup_uuid=$(cryptsetup luksUUID "$temp_loop" 2>/dev/null)
                losetup -d "$temp_loop" 2>/dev/null
                if [[ -n "$backup_uuid" ]]; then
                    echo -e "Compare UUIDs to make sure they match..."
                    echo -e "\n${CYAN}Backup UUID: ${backup_uuid}${NC}"
                else
                    echo -e "${YELLOW}Could not read UUID from backup${NC}"
                fi
            else
                echo -e "${YELLOW}Could not set up loop device for UUID check${NC}"
            fi
        fi
    fi

    if [[ ! "$missing_header_flag" == "1" ]]; then
        if cryptsetup status "$(basename "${container_path}")" &>/dev/null; then
            d_err "Error: Container appears to be in use. Please close it first."
            return 1
        fi
    fi

    echo -e "\n${BLUE}Restoring LUKS header from backup...${NC}"
    if cryptsetup -q luksHeaderRestore "${container_path}" --header-backup-file "$backup_file"; then
        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ LUKS header restored successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"

        echo -e "\n${YELLOW}Updated keyslots:${NC}"
        display_keyslots "${container_path}"

        echo -e "\n${YELLOW}IMPORTANT:${NC} Test that you can open the container with the"
        echo -e "passphrases from the backup before removing old copies.\n"
    else
        echo -e "${RED}✗ Header restore failed!${NC}"
        echo -e "${YELLOW}The container header may be in an inconsistent state.${NC}"
        echo -e "${YELLOW}DO NOT use the container until this is resolved.${NC}\n"

        backup_file=""
        return 1
    fi

    backup_file=""
}

# ===========================================================================
# Erase LUKS header
# ===========================================================================
erase_luks_header() {
    local container_path="$1"
    local container_size
    local keyslot_count
    local in_use="false"
    local loop_devices
    local luks_dump
    local luks_version
    local header_size_mb
    local header_size_kb
    local container_size_mb
    local create_backup
    local final_confirm

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "Erase LUKS Header"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

    echo -e "${RED}╔═════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ 🛑  DESTRUCTIVE OPERATION - READ CAREFULLY          ║${NC}"
    echo -e "${RED}║                                                     ║${NC}"
    echo -e "${RED}║ Erasing the LUKS header will:                       ║${NC}"
    echo -e "${RED}║ • PERMANENTLY destroy all encryption keys           ║${NC}"
    echo -e "${RED}║ • Make data IRRECOVERABLE (even with passphrase)    ║${NC}"
    echo -e "${RED}║ • Effectively render the container useless          ║${NC}"
    echo -e "${RED}║                                                     ║${NC}"
    echo -e "${RED}║ This is NOT reversible!                             ║${NC}"
    echo -e "${RED}╚═════════════════════════════════════════════════════╝${NC}\n"

    sleep 3

    echo -e "${YELLOW}Container information:${NC}"
    echo -e "  Path: ${CYAN}${container_path}${NC}"
    container_size=$(stat -c%s "${container_path}" 2>/dev/null)
    echo -e "  Size: ${CYAN}$(numfmt --to=iec "$container_size" 2>/dev/null)${NC}\n"

    display_keyslots "${container_path}"

    keyslot_count="$DISPLAY_KEYSLOTS_COUNT"
    if [[ "$keyslot_count" -eq "0" ]]; then
        d_warn "Warning: No active keyslots detected. Container may already be damaged."
    fi

    echo -e "\nVerifying LUKS header..."
    if ! cryptsetup isLuks "${container_path}" 2>/dev/null; then
        d_err "Error: This file does not appear to be a valid LUKS container."
        return 1
    fi
    d_ok "Valid LUKS header detected"

    echo -e "\nChecking if container is in use..."
    loop_devices=$(losetup -l 2>/dev/null | grep "${container_path}")
    if [[ -n "$loop_devices" ]]; then
        d_warn "Container is currently attached to a loop device:"
        echo "$loop_devices"
        in_use="true"
    fi

    if cryptsetup status "$(basename "${container_path}")" &>/dev/null; then
        d_warn "Container appears to be open (mapped)"
        in_use="true"
    fi

    if [[ "$in_use" == "true" ]]; then
        echo -e "\n${RED}Error:${NC} Container must be closed and detached before erasing the header."
        echo -e "Please close it manually first:\n"
        echo -e "  sudo cryptsetup luksClose <mapper-name>"
        echo -e "  sudo losetup -d <loop-device>\n"
        return 1
    fi
    d_ok "Container is not in use"

    echo
    luks_dump=$(cryptsetup luksDump "${container_path}" 2>/dev/null)
    luks_version=$(echo "$luks_dump" | grep -i "^Version:" | awk '{print $2}')

    if [[ "$luks_version" == "2" ]]; then
        header_size_mb="16"
        header_size_kb=$((header_size_mb * 1024))
        echo -e "Header size to wipe: ${header_size_mb}MB (standard LUKS2 metadata area)"
        echo -e "This matches the size of a LUKS header backup file"
    else
        header_size_mb="2"
        header_size_kb=$((header_size_mb * 1024))
        echo -e "${CYAN}Header size to wipe:${NC} 2MB (complete LUKS1 header)"
    fi

    echo
    d_info "Only header area will be overwritten"

    container_size_mb=$(( container_size / 1024 / 1024 ))
    if [[ "$container_size_mb" -lt "$header_size_mb" ]]; then
        echo -e "\n${RED}Warning:${NC} Container (${container_size_mb}MB) is smaller than planned header wipe (${header_size_mb}MB)."
        echo -e "This will overwrite the entire container. Investigate why before continuing."
        header_size_mb="$container_size_mb"
        header_size_kb=$((header_size_mb * 1024))
    fi

    echo -e "\n${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠️ LAST CHANCE TO BACKUP${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "Would you like to create a final header backup first?"
    echo -e "This is STRONGLY recommended if you haven't already.\n"
    read -rp "Create backup before erasing? (default: y) [Y/n]: " create_backup
    create_backup="${create_backup:-y}"

    if [[ "${create_backup,,}" == "y" ]]; then
        backup_luks_header "${container_path}"
    fi

    echo -e "\n${RED}═══════════════════════════════════════════════════════${NC}"
    echo -e "${RED}🚩 FINAL WARNING${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
    echo -e "You are about to PERMANENTLY destroy the LUKS header."
    echo -e "All encryption keys will be lost FOREVER."
    echo -e "Data will be IRRECOVERABLE."
    echo
    read -rp "Type 'I UNDERSTAND' in uppercase to proceed: " final_confirm

    if [[ "$final_confirm" != "I UNDERSTAND" ]]; then
        echo -e "${BLUE}Operation cancelled.${NC}\n"
        return 0
    fi

    echo -e "\n${BLUE}Erasing LUKS header...${NC}"
    echo -e "Overwriting first ${header_size_mb}MB of the container with random data..."

    if dd if=/dev/urandom of="${container_path}" bs=1M count="$header_size_mb" conv=notrunc status=progress; then
        echo -e "\n${BLUE}Verifying erasure...${NC}"

        if cryptsetup isLuks "${container_path}" 2>/dev/null; then
            d_warn "Warning: Container still appears to be LUKS. Trying additional wipe..."
            dd if=/dev/zero of="${container_path}" bs=1K count="$header_size_kb" conv=notrunc status=progress 2>/dev/null
            if cryptsetup isLuks "${container_path}" 2>/dev/null; then
                d_err "Header may not be fully erased. Manual intervention required."
                echo -e "${YELLOW}Try: sudo dd if=/dev/urandom of=${container_path} bs=1M count=${header_size_mb} conv=notrunc${NC}\n"
                return 1
            fi
        fi

        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ LUKS header erased successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "  Container: ${CYAN}${container_path}${NC}"
        echo -e "  Header area wiped: ${CYAN}${header_size_mb}MB${NC}"
        echo -e "  Status: ${RED}LUKS header destroyed - data irrecoverable${NC}"
        echo -e "\n${YELLOW}The container file still exists but is no longer usable.${NC}"
        echo -e "${YELLOW}To reuse you will need to manually restore header to the${NC}"
        echo -e "${YELLOW}encrypted container since it is now unrecognizable${NC}"
        echo -e "${YELLOW}from random disk noise.${NC}"
    else
        d_err "Header erasure failed!"
        echo -e "${YELLOW}Check if you have write permissions to the container.${NC}\n"
        return 1
    fi

    echo
}

# ===========================================================================
# Validate numeric user input
# ===========================================================================
validate_positive_integer() {
    local value="$1"
    local field_name="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        d_err "Error: $field_name must be a positive integer."
        return 1
    fi

    if [[ "$value" -eq "0" ]]; then
        d_err "Error: $field_name must be greater than 0."
        return 1
    fi

    return 0
}

# ===========================================================================
# Add keyfile to LUKS container
# ===========================================================================
add_keyfile() {
    local container_path="$1"
    local keyfile_choice
    local keyfile_dir
    local keyfile_name
    local keyfile_size
    local confirm_large
    local keyfile_size_actual
    local keyfile_perms

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "Add Keyfile to LUKS Container"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

    echo -e "${YELLOW}Current keyslots:${NC}"
    display_keyslots "${container_path}"

    echo
    d_info "Keyfiles provide an alternative way to unlock your container."
    echo -e "    They can be used alongside or instead of passwords.\n"

    echo -e "Choose keyfile source:"
    echo -e "  ${BLUE}1)${NC} ${CYAN}Generate new random keyfile${NC}"
    echo -e "  ${BLUE}2)${NC} ${CYAN}Use existing keyfile${NC}\n"
    read -rp "Enter choice [1-2]: " keyfile_choice

    if [[ "$keyfile_choice" == "1" ]]; then
        read -rp "Enter directory to save keyfile (full path): " keyfile_dir

        if [[ ! "${keyfile_dir}" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
            d_err "Error: Invalid characters in directory path"
            return 1
        fi

        if [[ ! -d "${keyfile_dir}" ]]; then
            mkdir -p "${keyfile_dir}" || { d_err "Failed to create directory"; return 1; }
        fi

        read -rp "Enter keyfile name (e.g. my_key.key): " keyfile_name

        if [[ ! "${keyfile_name}" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
            d_err "Error: Invalid characters in keyfile name"
            return 1
        fi

        keyfile_path="${keyfile_dir}/${keyfile_name}"

        while true; do
            read -rp "Keyfile size in bytes (recommended: 4096): " keyfile_size
            keyfile_size="${keyfile_size:-4096}"

            if [[ "$keyfile_size" -gt "65536" ]]; then
                d_warn "Warning: Keyfile size exceeds 64KB. Large keyfiles are unnecessary."
                read -rp "Continue with $keyfile_size bytes? [y/N]: " confirm_large
                [[ "${confirm_large,,}" != "y" ]] && continue
            fi

            if validate_positive_integer "$keyfile_size" "Keyfile size"; then
                break
            fi
        done

        echo -e "\n${CYAN}Generating random keyfile...${NC}"

        dd if=/dev/urandom of="${keyfile_path}" bs=1 count="$keyfile_size" 2>/dev/null

        keyfile_size_actual=$(stat -c%s "${keyfile_path}" 2>/dev/null)
        if [[ "$keyfile_size_actual" -ne "$keyfile_size" ]]; then
            d_err "Error: Keyfile size mismatch. Expected: $keyfile_size, Got: ${keyfile_size_actual}."
            rm -f "${keyfile_path}" 2>/dev/null
            return 1
        fi

        chmod 600 "${keyfile_path}"
        chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${keyfile_path}" 2>/dev/null || \
            chown root:root "${keyfile_path}" 2>/dev/null || true

        d_ok "Keyfile generated: ${keyfile_path}"
        echo -e "  Size: ${keyfile_size_actual} bytes"
        echo -e "  Permissions: $(stat -c%a "${keyfile_path}")"
    else
        read -rp "Enter path to existing keyfile: " keyfile_path
        if [[ ! -f "${keyfile_path}" ]]; then
            d_err "Error: Keyfile not found."
            return 1
        fi

        keyfile_perms=$(stat -c%a "${keyfile_path}" 2>/dev/null)
        if [[ -n "$keyfile_perms" ]] && [[ "$keyfile_perms" != "600" ]] && [[ "$keyfile_perms" != "400" ]]; then
            d_warn "Caution: Keyfile permissions are $keyfile_perms. Recommend setting to 600 for  stricter security."
        fi
    fi

    echo -e "\n${BLUE}Adding keyfile to LUKS container...${NC}"

    if cryptsetup -q -y luksAddKey "${container_path}" "${keyfile_path}"; then
        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ Keyfile added successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "  Container: ${CYAN}${container_path}${NC}"
        echo -e "  Keyfile: ${CYAN}${keyfile_path}${NC}"
        echo -e "\n${YELLOW}Updated keyslots:${NC}"
        display_keyslots "${container_path}"

        echo -e "\n${YELLOW}To open with keyfile:${NC}"
        echo -e "  sudo cryptsetup luksOpen <loop-device> <alias> \\"
        echo -e "  --key-file ${keyfile_path}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    else
        d_err "Failed to add keyfile!"
        keyfile_dir=""
        keyfile_name=""
        return 1
    fi

    echo
    # Clear keyfile variables for security
    keyfile_dir=""
    keyfile_name=""
}

# ===========================================================================
# Change LUKS password
# ===========================================================================
change_password() {
    local container_path="$1"
    local pwd_choice

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "Change LUKS Container Password"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

    echo -e "${YELLOW}Current keyslots:${NC}"
    display_keyslots "${container_path}"

    echo -e "\n${YELLOW}Options:${NC}"
    echo -e "  ${BLUE}1)${NC} ${CYAN}Add new password to a new keyslot${NC}"
    echo -e "  ${BLUE}2)${NC} ${CYAN}Change existing password (requires current password)${NC}"
    echo -e "  ${BLUE}3)${NC} ${CYAN}Back to main menu${NC}"
    echo
    read -rp "Enter choice [1-3]: " pwd_choice

    case "$pwd_choice" in
        1)
            echo -e "\n${BLUE}Adding new password to a new keyslot...${NC}\n"
            #echo -e "${YELLOW}Enter current passphrase when prompted, then new passphrase.${NC}"

            if cryptsetup -q -y luksAddKey "${container_path}"; then
                d_ok "New password added successfully!"
                echo -e "\n${YELLOW}Updated keyslots:${NC}"
                display_keyslots "${container_path}"

		echo && echo
                d_info "Tip: You can now optionally remove the old"
		echo -e "    keyslot with option 9 (Remove Keyslot)"
            else
                d_err "Failed to add new password!"
                return 1
            fi
            ;;
        2)
            echo -e "\n${CYAN}Changing password for existing keyslot...${NC}"

            if cryptsetup -q luksChangeKey "${container_path}"; then
                d_ok "Password changed successfully!"
                echo -e "\n${YELLOW}Updated keyslots:${NC}"
                display_keyslots "${container_path}"
            else
                d_err "Failed to change password!"
                return 1
            fi
            ;;
        3)
            echo -e "${BLUE}Returning to main menu...${NC}"
            return 0
            ;;
        *)
            d_err "Invalid choice"
            return 1
            ;;
    esac
    echo
}

# ===========================================================================
# Remove target keyslot
# ===========================================================================
remove_keyslot() {
    local container_path="$1"
    local enabled_count
    local luks_dump
    local luks_version
    local enabled_slot_numbers=()
    local json_dump
    local slot
    local priority
    local in_keyslots
    local current_slot
    local line
    local slot_number
    local is_enabled
    local enabled_slot
    local continue_anyway
    local confirm

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "Remove Keyslot from LUKS Container"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

    echo -e "${YELLOW}Current keyslots:${NC}"
    display_keyslots "${container_path}"
    enabled_count="$DISPLAY_KEYSLOTS_COUNT"

    luks_dump=$(cryptsetup luksDump "${container_path}" 2>/dev/null)
    luks_version=$(echo "$luks_dump" | grep -i "^Version:" | awk '{print $2}')

    if [[ "$enabled_count" -le "1" ]]; then
        echo -e "\n${RED}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║ ⚠️ CRITICAL: Only ${enabled_count} active keyslot remaining!         ║${NC}"
        echo -e "${RED}║ Removing the last keyslot will permanently destroy   ║${NC}"
        echo -e "${RED}║ all access to your encrypted data!                   ║${NC}"
        echo -e "${RED}║                                                      ║${NC}"
        echo -e "${RED}║ This operation will be BLOCKED for your protection.  ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
        echo -e "\n${YELLOW}To proceed, first add another keyslot (Option 8)${NC}"
        echo -e "${YELLOW}or add a keyfile (Option 7), then try again.${NC}\n"
        return 1
    fi

    echo -e "\n\n1. Removing a keyslot will permanently delete that key."
    echo -e "   Make sure you have another way to unlock the container."
    echo -e "2. ${RED}Never remove the last remaining key slot.${NC} Doing so makes"
    echo -e "   the encrypted data permanently inaccessible!"
    echo -e "3. Remaining keyslot cannot be a keyfile (sanity check)."
    echo
    echo -e "${YELLOW}To auto-detect which slot a passphrase unlocks:${NC}"
    echo -e "  sudo cryptsetup open --test-passphrase --verbose \\"
    echo -e "  ${container_path}"
    echo -e "\nOutput will indicate: 'Key slot X unlocked'\n"

    if [[ "$luks_version" == "2" ]]; then
        json_dump=$(cryptsetup luksDump --dump-json-metadata "${container_path}" 2>/dev/null)
        if [[ -n "$json_dump" ]] && command -v jq &>/dev/null; then
            while IFS= read -r slot; do
                priority=$(echo "$json_dump" | jq -r ".keyslots[\"$slot\"].priority // \"normal\"" 2>/dev/null)
                if [[ "$priority" == "normal" ]] || [[ "$priority" == "prefer" ]]; then
                    enabled_slot_numbers+=("$slot")
                fi
            done < <(echo "$json_dump" | jq -r '.keyslots | keys[]' 2>/dev/null)
        else
            in_keyslots="0"
            current_slot=""
            while IFS= read -r line; do
                if [[ "$line" =~ ^Keyslots:$ ]]; then
                    in_keyslots="1"
                    continue
                fi
                if [[ "$in_keyslots" -eq "1" ]] && [[ "$line" =~ ^(Tokens:|Digests:) ]]; then
                    in_keyslots="0"
                    continue
                fi
                if [[ "$in_keyslots" -eq "1" ]]; then
                    if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]+luks2 ]]; then
                        current_slot="${BASH_REMATCH[1]}"
                    fi
                    if [[ -n "$current_slot" ]] && [[ "$line" =~ Priority:[[:space:]]*(normal|prefer) ]]; then
                        enabled_slot_numbers+=("$current_slot")
                        current_slot=""
                    fi
                fi
            done <<< "$luks_dump"
        fi
    else
        while IFS= read -r line; do
            if [[ "$line" =~ ^Key[[:space:]]Slot[[:space:]]([0-9]+):[[:space:]]*ENABLED ]]; then
                enabled_slot_numbers+=("${BASH_REMATCH[1]}")
            fi
        done <<< "$luks_dump"
    fi

    echo -e "═══════════════════════════════════════"
    echo -e "${CYAN}🔑 Enabled keyslots:${NC} ${enabled_slot_numbers[*]}"
    echo -e "═══════════════════════════════════════\n"

    while true; do
        read -rp "Enter keyslot number to remove (or 'q' to quit): " slot_number

        if [[ "$slot_number" == "q" ]]; then
            d_exit "Operation cancelled."
            return 0
        fi

        if [[ ! "$slot_number" =~ ^[0-9]+$ ]]; then
            d_err "Error: Please enter a valid number."
            continue
        fi

        is_enabled="false"
        for enabled_slot in "${enabled_slot_numbers[@]}"; do
            if [[ "$enabled_slot" == "$slot_number" ]]; then
                is_enabled="true"
                break
            fi
        done

        if [[ "$is_enabled" == "false" ]]; then
            d_warn "Warning: Keyslot $slot_number doesn't appear to be enabled."
            read -rp "Continue anyway? [y/N]: " continue_anyway
            if [[ "${continue_anyway,,}" != "y" ]]; then
                d_exit "Operation cancelled."
                return 0
            fi
        fi

        echo -e "\nAre you sure you want to remove keyslot $slot_number?"
        read -rp "Type 'YES' in uppercase to confirm: " confirm
        if [[ "$confirm" != "YES" ]]; then
            d_exit "Operation cancelled."
            return 0
        fi

        break
    done

    echo -e "\n${BLUE}Removing keyslot $slot_number...${NC}"

    if cryptsetup -q luksKillSlot "${container_path}" "$slot_number"; then
        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ Keyslot $slot_number removed successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "\n${YELLOW}Remaining keyslots:${NC}"
        display_keyslots "${container_path}"
    else
        d_err "Failed to remove keyslot!"
        echo -e "${YELLOW}Make sure you're using a valid passphrase, slot exists and keyslot is not a keyfile.${NC}\n"
        return 1
    fi
    echo
}

# ===========================================================================
# Show container information
# ===========================================================================
show_container_info() {
    local container_path="$1"
    local file_size
    local luks_dump
    local luks_version
    local luks_type
    local cipher
    local hash
    local uuid
    local label
    local found_slot
    local json_dump
    local slots
    local slot
    local priority
    local show_full
    local line
    local in_keyslot
    local current_slot
    local has_key
    local slot_priority
    local status

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "LUKS Container Information"
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

    echo -e "  Container: ${CYAN}${container_path}${NC}"

    file_size=$(stat -c%s "${container_path}" 2>/dev/null)
    if [[ -n "$file_size" ]]; then
        echo -e "  File size: ${CYAN}$(numfmt --to=iec "$file_size")${NC} ($file_size bytes)"
    fi

    luks_dump=$(cryptsetup luksDump "${container_path}" 2>/dev/null)

    if [[ -z "$luks_dump" ]]; then
        d_err "Error: Could not read LUKS header"
        return 1
    fi

    luks_version=$(echo "$luks_dump" | grep -E "^[[:space:]]*Version:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    luks_type=$(echo "$luks_dump" | grep -E "^[[:space:]]*Type:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    cipher=$(echo "$luks_dump" | grep -E "^[[:space:]]*cipher:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    hash=$(echo "$luks_dump" | grep -E "^[[:space:]]*Hash:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    uuid=$(echo "$luks_dump" | grep -E "^[[:space:]]*UUID:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    label=$(echo "$luks_dump" | grep -E "^[[:space:]]*Label:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')

    if [[ -z "$cipher" ]]; then
        cipher=$(echo "$luks_dump" | grep -E "^[[:space:]]*Cipher:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    fi

    if [[ -z "$luks_type" ]]; then
        if [[ "$luks_version" == "1" ]]; then
            luks_type="LUKS1"
        elif [[ "$luks_version" == "2" ]]; then
            luks_type="LUKS2"
        else
            luks_type="Unknown"
        fi
    fi

    echo -e "\n${YELLOW}  LUKS Configuration:${NC}"
    echo -e "    Type:    ${CYAN}${luks_type:-Unknown}${NC}"
    echo -e "    Version: ${CYAN}${luks_version:-Unknown}${NC}"
    echo -e "    Cipher:  ${CYAN}${cipher:-Unknown}${NC}"
    echo -e "    Hash:    ${CYAN}${hash:-Unknown}${NC}"
    [[ -n "$uuid" && "$uuid" != "(no label)" ]] && echo -e "    UUID:    ${CYAN}${uuid}${NC}"
    [[ -n "$label" && "$label" != "(no label)" ]] && echo -e "    Label:   ${CYAN}${label}${NC}"

    echo -e "\n${YELLOW}  Keyslots:${NC}"

    found_slot="0"

    json_dump=$(cryptsetup luksDump --dump-json-metadata "${container_path}" 2>/dev/null)

    if [[ -n "$json_dump" ]] && command -v jq &>/dev/null; then
        slots=$(echo "$json_dump" | jq -r '.keyslots | keys[]' 2>/dev/null)
        if [[ -n "$slots" ]]; then
            for slot in $slots; do
                priority=$(echo "$json_dump" | jq -r ".keyslots[\"$slot\"].priority // \"normal\"" 2>/dev/null)
                if [[ "$priority" == "ignore" ]]; then
                    echo -e "    Slot ${slot}: ${RED}DISABLED${NC} (Priority: $priority)"
                else
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC} (Priority: $priority)"
                fi
                found_slot="1"
            done
        fi
    elif echo "$luks_dump" | grep -q "^Keyslots:"; then
        declare -A slot_data
        declare -A slot_priority_data

        in_keyslot="0"
        current_slot=""
        has_key="0"
        slot_priority=""

        while IFS= read -r line; do
            if [[ "$line" =~ ^Keyslots: ]]; then
                in_keyslot="1"
                continue
            fi

            if [[ "$in_keyslot" -eq "1" ]] && [[ "$line" =~ ^[A-Za-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
                if [[ -n "$current_slot" ]]; then
                    slot_data[$current_slot]="$has_key"
                    slot_priority_data[$current_slot]="$slot_priority"
                fi
                in_keyslot="0"
                current_slot=""
                has_key="0"
                slot_priority=""
                continue
            fi

            if [[ "$in_keyslot" -eq "1" ]]; then
                if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]+luks2 ]]; then
                    if [[ -n "$current_slot" ]]; then
                        slot_data[$current_slot]="$has_key"
                        slot_priority_data[$current_slot]="$slot_priority"
                    fi

                    current_slot="${BASH_REMATCH[1]}"
                    has_key="0"
                    slot_priority=""
                elif [[ -n "$current_slot" ]] && [[ "$line" =~ "Key:" ]]; then
                    if [[ "$line" =~ [0-9]+[[:space:]]+bits ]]; then
                        has_key="1"
                    fi
                elif [[ -n "$current_slot" ]] && [[ "$line" =~ "Priority:" ]]; then
                    slot_priority=$(echo "$line" | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
                fi
            fi
        done <<< "$luks_dump"

        if [[ "$in_keyslot" -eq "1" ]] && [[ -n "$current_slot" ]]; then
            slot_data[$current_slot]="$has_key"
            slot_priority_data[$current_slot]="$slot_priority"
        fi

        for slot in $(echo "${!slot_data[@]}" | tr ' ' '\n' | sort -n); do
            if [[ ${slot_data[$slot]} -eq "1" ]]; then
                if [[ -n "${slot_priority_data[$slot]}" ]]; then
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC} (Priority: ${slot_priority_data[$slot]})"
                else
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC}"
                fi
            else
                echo -e "    Slot ${slot}: ${RED}DISABLED${NC}"
            fi
            found_slot="1"
        done
    fi

    if [[ "$found_slot" -eq "0" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^Key[[:space:]]+Slot[[:space:]]+([0-9]+):[[:space:]]+(.*) ]]; then
                slot="${BASH_REMATCH[1]}"
                status="${BASH_REMATCH[2]}"

                if [[ "$status" == "DISABLED" ]] || [[ "$status" == *"DISABLED"* ]]; then
                    echo -e "    Slot ${slot}: ${RED}DISABLED${NC}"
                else
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC}"
                fi
                found_slot=1
            fi
        done <<< "$luks_dump"
    fi

    if [[ "$found_slot" -eq "0" ]]; then
        echo -e "    ${YELLOW}No keyslot information found${NC}"
    fi

    echo
    echo -e "${YELLOW}Show full LUKS header dump?${NC}"
    read -rp "[y/N]: " show_full
    show_full="${show_full:-n}"

    if [[ "${show_full,,}" == "y" ]]; then
        echo -e "\n${CYAN}╔════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║       Full LUKS Header Dump                ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}\n"
        printf '  %s\n' "${luks_dump//$'\n'/$'\n'  }"
        echo
    fi

    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
}


# ===========================================================================
# Main codeblock
# ===========================================================================

USERNAME="${SUDO_USER:-$USER}"

echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}\n"
echo -e "${YELLOW}   << Create & mount LUKS containers script $VRS >>${NC}"
echo -e "\nEncrypted block devices (partitions) are not supported,"
echo -e "only LUKS file containers / images with .bin extension.\n"

check_privileges

echo -e "\n${BLUE}Checking if required packages are installed...${NC}"
detect_pkg_manager

need_install=()
command -v cryptsetup >/dev/null 2>&1 || need_install+=("cryptsetup")
command -v e2fsck     >/dev/null 2>&1 || need_install+=("e2fsprogs")
command -v resize2fs  >/dev/null 2>&1 || need_install+=("e2fsprogs")
command -v losetup    >/dev/null 2>&1 || need_install+=("util-linux")
command -v fallocate  >/dev/null 2>&1 || need_install+=("util-linux")

if [[ ${#need_install[@]} -gt 0 ]]; then
    if [[ -n "$PKG_INSTALL" ]]; then
        echo -e "${YELLOW}Installing missing packages via ${PKG_MANAGER}: ${need_install[*]}${NC}"
        $PKG_INSTALL "${need_install[@]}" || {
            d_err "Auto-install failed. Please install manually: ${need_install[*]}"
            exit 1
        }
    else
        d_err "No supported package manager found (apt or pacman)."
        echo -e "    ${RED}Please install manually: ${need_install[*]}${NC}"
        exit 1
    fi
fi
d_ok "Installed. Ready to proceed."

# ===========================================================================
# Main menu
# ===========================================================================
while true; do
    echo -e "\n═════════════════════════════════════════════════════════"
    echo -e "${YELLOW}Choose from the following options${NC}"
    echo -e "═════════════════════════════════════════════════════════\n"
    echo -e "  ${BLUE}1)${NC} ${CYAN}Create new LUKS container${NC}"
    echo -e "  ${BLUE}2)${NC} ${CYAN}Expand existing LUKS container${NC} (Grow)"
    echo -e "  ${BLUE}3)${NC} ${CYAN}Truncate existing LUKS container${NC} (Shrink)"
    echo -e "  ${BLUE}4)${NC} ${CYAN}Backup LUKS header${NC}"
    echo -e "  ${BLUE}5)${NC} ${CYAN}Overwrite/Restore LUKS header${NC}"
    echo -e "  ${BLUE}6)${NC} ${CYAN}Erase LUKS header${NC}"
    echo -e "  ${BLUE}7)${NC} ${CYAN}Add keyfile to container${NC}"
    echo -e "  ${BLUE}8)${NC} ${CYAN}Add keyslot/Change password${NC}"
    echo -e "  ${BLUE}9)${NC} ${CYAN}Remove keyslot${NC}"
    echo -e "  ${BLUE}10)${NC} ${CYAN}Show container information${NC}"
    echo -e "  ${BLUE}11)${NC} ${BLUE}Exit${NC}\n"

    read -rp "Enter choice [1-11]: " TASK_NUM

    if [[ "$TASK_NUM" =~ ^(4|6|7|8|9|10)$ ]]; then
        find_con

        case "$TASK_NUM" in
            4)
                backup_luks_header "$CONT_TARGET"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read -r _
                continue
                ;;
            6)
                erase_luks_header "$CONT_TARGET"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read -r _
                continue
                ;;
            7)
                add_keyfile "$CONT_TARGET"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read -r _
                continue
                ;;
            8)
                change_password "$CONT_TARGET"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read -r _
                continue
                ;;
            9)
                remove_keyslot "$CONT_TARGET"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read -r _
                continue
                ;;
            10)
                show_container_info "$CONT_TARGET"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read -r _
                continue
                ;;
        esac
    fi

    if [[ "$TASK_NUM" == "11" ]]; then
        d_exit "Script will exit."
        error_detach
        exit 0
    elif [[ "$TASK_NUM" == "5" ]]; then
        find_container_manually
        restore_luks_header "$CONT_TARGET"
        echo -e "${BLUE}Press Enter to return to main menu...${NC}"
        read -r _
    elif [[ "$TASK_NUM" == "1" ]]; then
        break
    elif [[ "$TASK_NUM" == "2" ]] || [[ "$TASK_NUM" == "3" ]]; then
        find_con

        echo -e "\n${BLUE}Opening LUKS container for analysis...${NC}"
        verify_and_mount_container "$CONT_TARGET"

        CALC_CONT_SIZE_BYTES=$(wc -c < "$CONT_TARGET")
        CALC_CONT_SIZE_MB=$((CALC_CONT_SIZE_BYTES / 1024 / 1024))
        echo -e "  Current LUKS container size: ${CYAN}${CALC_CONT_SIZE_MB} MB${NC}\n"

        if [[ "$TASK_NUM" == "2" ]]; then
            while true; do
                echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
                d_step "Set LUKS container target size..."
                echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

                read -rp "Specify the new expanded LUKS container size (in MB):  " TOTAL_CONT_SIZE

                if [[ ! "$TOTAL_CONT_SIZE" =~ ^[0-9]+$ ]]; then
                    d_err "Error: Invalid size. Numerical values only."
                elif [[ "$TOTAL_CONT_SIZE" -gt "1048576" ]]; then
                    d_err "Error: Maximum container size is 1TB (1048576 MB)."
                elif [[ "$TOTAL_CONT_SIZE" -le "$CALC_CONT_SIZE_MB" ]]; then
                    #echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
                    d_warn "Warning: Specified size is the same or less than"
                    echo -e "    ${YELLOW}existing LUKS container. Select a larger size to continue.${NC}\n"
                    #echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}\n"
                else
                    break
                fi
            done

            CONTAINER_DIR=$(dirname "$CONT_TARGET")
            if ! check_disk_space "$CONTAINER_DIR" "$TOTAL_CONT_SIZE"; then
                d_err "Cannot proceed due to insufficient disk space."
                exit 1
            fi

            CALC2=$(awk "BEGIN {printf \"%.2f\", $TOTAL_CONT_SIZE / 1024}")
            echo -e "New LUKS container size will be ${CYAN}$TOTAL_CONT_SIZE MB${NC} (approx ${CALC2} GB)."
            read -rp "Is this correct? [y/n] " RESP1

            if [[ "${RESP1,,}" == "y" ]]; then
                echo
                d_warn "CAUTION: Risk of data corruption if LUKS container is"
                echo -e "    ${YELLOW}interrupted or fails while resizing!${NC}"
                sleep 2

                echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
                d_step "Expanding container file..."
                echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

                NEW_CONT_SIZE=$((TOTAL_CONT_SIZE - CALC_CONT_SIZE_MB))
                FILE_SIZE_BEFORE=$(stat -c%s "$CONT_TARGET" 2>/dev/null)
                FILE_SIZE_BEFORE_MB=$((FILE_SIZE_BEFORE / 1024 / 1024))

                echo -e "Current file size: ${CYAN}${FILE_SIZE_BEFORE_MB} MB${NC}"
                echo -e "Need to add: ${GRAY}${NEW_CONT_SIZE} MB${NC}"
                echo -e "Expected final size: ${CYAN}${TOTAL_CONT_SIZE} MB${NC}"

                echo -e "Attempting fallocate..."
                fallocate -l "+${NEW_CONT_SIZE}M" "$CONT_TARGET" 2>&1
                fallocate_result=$?

                FILE_SIZE_AFTER=$(stat -c%s "$CONT_TARGET" 2>/dev/null)
                FILE_SIZE_AFTER_MB=$((FILE_SIZE_AFTER / 1024 / 1024))

                if [[ "$fallocate_result" -ne "0" ]] || [[ "$FILE_SIZE_AFTER_MB" -le "$CALC_CONT_SIZE_MB" ]]; then
                    if [[ "$fallocate_result" -ne "0" ]]; then
                        d_warn "fallocate failed (exit code: ${fallocate_result})"
                    else
                        echo -e "(fallocate appeared to succeed but file didn't grow)"
                    fi

                    echo -e "${YELLOW}Falling back to dd method...${NC}"

                    dd if=/dev/zero of="$CONT_TARGET" bs=1M count=0 seek="$TOTAL_CONT_SIZE" 2>/dev/null

                    FILE_SIZE_AFTER=$(stat -c%s "$CONT_TARGET" 2>/dev/null)
                    FILE_SIZE_AFTER_MB=$((FILE_SIZE_AFTER / 1024 / 1024))

                    if [[ "$FILE_SIZE_AFTER_MB" -le "$CALC_CONT_SIZE_MB" ]]; then
                        echo -e "${YELLOW}dd seek failed, using truncate to set exact size...${NC}"
                        truncate -s "${TOTAL_CONT_SIZE}M" "$CONT_TARGET"
                        FILE_SIZE_FINAL=$(stat -c%s "$CONT_TARGET" 2>/dev/null)
                        FILE_SIZE_FINAL_MB=$((FILE_SIZE_FINAL / 1024 / 1024))
                    else
                        FILE_SIZE_FINAL_MB="$FILE_SIZE_AFTER_MB"
                    fi
                else
                    d_ok "fallocate succeeded"
                    FILE_SIZE_FINAL_MB="$FILE_SIZE_AFTER_MB"
                fi

                if [[ "$FILE_SIZE_FINAL_MB" -le "$CALC_CONT_SIZE_MB" ]]; then
                    echo -e "\n${RED}╔══════════════════════════════════════════════════════╗${NC}"
                    echo -e "${RED}║ ERROR: File expansion FAILED!                       ║${NC}"
                    echo -e "${RED}║ File size: ${FILE_SIZE_FINAL_MB} MB (expected: ${TOTAL_CONT_SIZE} MB)        ║${NC}"
                    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
                    echo -e "\n${YELLOW}Manual workaround:${NC}"
                    echo -e "  sudo truncate -s ${TOTAL_CONT_SIZE}M \"$CONT_TARGET\""
                    echo -e "  Then run the script again.\n"
                    exit 1
                fi

                d_ok "Container file expanded: ${CALC_CONT_SIZE_MB} MB → ${FILE_SIZE_FINAL_MB} MB"

                if ! loop_dev=$(losetup -f --show --direct-io=on "$CONT_TARGET" 2>/dev/null) || [[ -z "$loop_dev" ]]; then
                    d_err "Error: Failed to get loop device"
                    exit 1
                fi

                attached_verify=$(losetup -l "$loop_dev" 2>/dev/null | awk 'NR==2 {print $6}')
                if [[ "$attached_verify" != "$CONT_TARGET" ]]; then
                    d_err "Error: Loop device verification failed!"
                    losetup -d "$loop_dev" 2>/dev/null || true
                    loop_dev=""
                    exit 1
                fi

                LOOP_SIZE=$(blockdev --getsize64 "$loop_dev" 2>/dev/null)
                LOOP_SIZE_MB=$((LOOP_SIZE / 1024 / 1024))

                if [[ "$LOOP_SIZE_MB" -ne "$FILE_SIZE_FINAL_MB" ]]; then
                    echo -e "${YELLOW}Loop device size (${LOOP_SIZE_MB}MB) doesn't match file size (${FILE_SIZE_FINAL_MB}MB)${NC}"
                    echo -e "${YELLOW}Refreshing loop device...${NC}"
                    losetup -c "$loop_dev" 2>/dev/null || true
                    sleep 1

                    LOOP_SIZE=$(blockdev --getsize64 "$loop_dev" 2>/dev/null)
                    LOOP_SIZE_MB=$((LOOP_SIZE / 1024 / 1024))
                    echo -e "Loop device size after refresh: ${CYAN}${LOOP_SIZE_MB} MB${NC}"

                    if [[ "$LOOP_SIZE_MB" -ne "$FILE_SIZE_FINAL_MB" ]]; then
                        echo -e "${YELLOW}Re-attaching loop device...${NC}"
                        losetup -d "$loop_dev" 2>/dev/null
                        sleep 1
                        loop_dev=$(losetup -f --show --direct-io=on "$CONT_TARGET" 2>/dev/null)
                        LOOP_SIZE=$(blockdev --getsize64 "$loop_dev" 2>/dev/null)
                        LOOP_SIZE_MB=$((LOOP_SIZE / 1024 / 1024))
                        echo -e "Loop device size after re-attach: ${CYAN}${LOOP_SIZE_MB} MB${NC}"
                    fi
                fi

                echo -e "\n${BLUE}Opening container...${NC}"
                if ! cryptsetup luksOpen "$loop_dev" "${TMP_MAPPER_NAME}"; then
                    d_err "Error: Failed to open LUKS container!"
                    error_detach
                    exit 1
                fi
                d_ok "Container opened"

                LUKS_SIZE_BEFORE=$(blockdev --getsize64 "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null)
                LUKS_SIZE_MB_BEFORE=$((LUKS_SIZE_BEFORE / 1024 / 1024))

                echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
                d_step "Filesystem check..."
                echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"
                e2fsck -fy "/dev/mapper/${TMP_MAPPER_NAME}"
                e2fsck_result=$?
                if [[ "$e2fsck_result" -gt "2" ]]; then
                    d_err "Error: Filesystem check failed!"
                    error_detach
                    exit 1
                fi
                d_ok "Filesystem check passed."

                echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
                d_step "Resizing LUKS device..."
                echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"
                echo -e "Current LUKS size: ${CYAN}${LUKS_SIZE_MB_BEFORE} MB${NC}"
                echo -e "Loop device size: ${CYAN}${LOOP_SIZE_MB} MB${NC}"
                echo -e "Expected LUKS after resize: ${YELLOW} $((LOOP_SIZE_MB - 18)) MB${NC} (minus header)\n"

                if ! cryptsetup resize "/dev/mapper/${TMP_MAPPER_NAME}"; then
                    d_err "LUKS resize failed!"
                    error_detach
                    exit 1
                fi

                LUKS_SIZE_AFTER=$(blockdev --getsize64 "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null)
                LUKS_SIZE_MB_AFTER=$((LUKS_SIZE_AFTER / 1024 / 1024))

                EXPECTED_LUKS_MB=$((LOOP_SIZE_MB - 18))

                if [[ "$LUKS_SIZE_MB_AFTER" -gt "$LUKS_SIZE_MB_BEFORE" ]]; then
                    d_ok "LUKS device grew: ${LUKS_SIZE_MB_BEFORE} MB → ${LUKS_SIZE_MB_AFTER} MB"
                elif [[ "$LUKS_SIZE_MB_AFTER" -eq "$LUKS_SIZE_MB_BEFORE" ]] && [[ "$LUKS_SIZE_MB_AFTER" -ge "$EXPECTED_LUKS_MB" ]]; then
                    d_ok "LUKS device latest size: ${LUKS_SIZE_MB_AFTER} MB"
                    echo -e "${YELLOW}    (Loop device: ${LOOP_SIZE_MB} MB, LUKS overhead: $((LOOP_SIZE_MB - LUKS_SIZE_MB_AFTER)) MB)${NC}"
                else
                    d_err "Error: LUKS device did not grow as expected!${NC}"
                    echo -e "${RED}    Before: ${LUKS_SIZE_MB_BEFORE} MB${NC}"
                    echo -e "${RED}    After:  ${LUKS_SIZE_MB_AFTER} MB${NC}"
                    echo -e "${RED}    Expected: ~${EXPECTED_LUKS_MB} MB${NC}"
                    echo -e "${RED}    Loop device: ${LOOP_SIZE_MB} MB${NC}\n"
                    error_detach
                    exit 1
                fi

                echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
                d_step "Expanding filesystem..."
                echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

                FS_SIZE_BEFORE=$(dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                FS_BLOCK=$(dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block size" | awk '{print $3}')
                FS_SIZE_MB_BEFORE=$((FS_SIZE_BEFORE * FS_BLOCK / 1024 / 1024))

                resize2fs -p "/dev/mapper/${TMP_MAPPER_NAME}"
                resize_result=$?

                FS_SIZE_AFTER=$(dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                FS_SIZE_MB_AFTER=$((FS_SIZE_AFTER * FS_BLOCK / 1024 / 1024))

                if [[ "$resize_result" -eq "0" ]] && [[ "$FS_SIZE_MB_AFTER" -gt "$FS_SIZE_MB_BEFORE" ]]; then
                    d_ok "Filesystem expanded: ${FS_SIZE_MB_BEFORE} MB → ${FS_SIZE_MB_AFTER} MB"
                else
                    echo -e "${YELLOW}Trying forced resize...${NC}"
                    resize2fs -f "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null
                    FS_SIZE_AFTER=$(dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                    FS_SIZE_MB_AFTER=$((FS_SIZE_AFTER * FS_BLOCK / 1024 / 1024))
                    if [[ "$FS_SIZE_MB_AFTER" -gt "$FS_SIZE_MB_BEFORE" ]]; then
                        d_ok "Forced filesystem expansion: ${FS_SIZE_MB_BEFORE} MB → ${FS_SIZE_MB_AFTER} MB"
                    else
                        d_err "Filesystem expansion failed!"
                        error_detach
                        exit 1
                    fi
                fi

                echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
                echo -e "${GREEN}✓ Container expansion complete!${NC}"
                echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
                echo -e "Container file size: ${GREEN}${FILE_SIZE_FINAL_MB} MB${NC}"
                echo -e "Filesystem size: ${GREEN}${FS_SIZE_MB_AFTER} MB${NC}"

            else
                d_exit "LUKS container resizing cancelled."
                error_detach
                exit 1
            fi

        elif [[ "$TASK_NUM" == "3" ]]; then
            calculate_min_safe_size "$FS_SIZE_MB" "$TOTAL_REAL_SIZE"

            if [[ "$CALC_SAFETY_LEVEL" == "CANNOT_SHRINK" ]]; then
                error_detach
                exit 1
            fi

            echo -e "\n${MAGENTA}${UNDERLINE}Shrink operation${NC}: shrink filesystem →→ resize"
            echo -e "the LUKS payload →→ truncate the container file"
            echo -e "to match.\n"
            echo -e "  Filesystem size range:"
            echo -e "  ${GREEN}${CALC_MIN_SIZE} MB${NC} to ${GREEN}$((FS_SIZE_MB - 1)) MB${NC}\n"

            while true; do
                read -rp "Specify the new filesystem size (in MB): " TARGET_FS_SIZE_MB

                if [[ ! "$TARGET_FS_SIZE_MB" =~ ^[0-9]+$ ]]; then
                    d_err "Error: Invalid size. Numerical values only."
                elif [[ "$TARGET_FS_SIZE_MB" -lt "$CALC_MIN_SIZE" ]]; then
                    echo -e "\n${RED}═════════════════════════════════════════════════════════${NC}"
                    echo -e "${RED}⛔ BLOCKED:${NC} Target size (${TARGET_FS_SIZE_MB} MB) is below the"
                    echo -e "resize2fs absolute minimum of ${CALC_MIN_SIZE} MB."
                    echo -e "${RED}═════════════════════════════════════════════════════════${NC}"
                elif [[ "$TARGET_FS_SIZE_MB" -ge "$FS_SIZE_MB" ]]; then
                    echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
                    d_warn "Warning: Target (${TARGET_FS_SIZE_MB} MB) is not smaller than"
                    echo -e "${YELLOW}the current filesystem (${FS_SIZE_MB} MB). Pick a smaller size.${NC}"
                    echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}"
                else
                    break
                fi
            done

            CALC2=$(awk "BEGIN {printf \"%.2f\", $TARGET_FS_SIZE_MB / 1024}")
            echo -e "New LUKS filesystem will be ${CYAN}$TARGET_FS_SIZE_MB MB${NC} (approx ${CALC2} GB)."
            read -rp "Is this correct? [y/n] " RESP2

            if [[ "${RESP2,,}" != "y" ]]; then
                d_exit "LUKS container resizing cancelled."
                error_detach
                exit 1
            fi

            if ! findmnt "/dev/mapper/${TMP_MAPPER_NAME}" &>/dev/null; then
                if ! loop_dev=$(losetup -f --show --direct-io=on "$CONT_TARGET" 2>/dev/null) || [[ -z "$loop_dev" ]]; then
                    d_err "Error: Failed to get loop device"
                    error_detach
                    exit 1
                fi

                attached_verify2=$(losetup -l "$loop_dev" 2>/dev/null | awk 'NR==2 {print $6}')
                if [[ "$attached_verify2" != "$CONT_TARGET" ]]; then
                    d_err "Error: Loop device verification failed!"
                    losetup -d "$loop_dev" 2>/dev/null || true
                    loop_dev=""
                    error_detach
                    exit 1
                fi

                echo -e "\n${BLUE}Opening LUKS container...${NC}"
                if ! cryptsetup luksOpen "$loop_dev" "${TMP_MAPPER_NAME}"; then
                    d_err "Error: Failed to open LUKS container!"
                    error_detach
                    exit 1
                fi
                d_ok "Container opened"
            fi

            echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
            d_step "Checking filesystem integrity..."
            echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"
            e2fsck -fy "/dev/mapper/${TMP_MAPPER_NAME}"
            e2fsck_result=$?
            if [[ "$e2fsck_result" -gt "2" ]]; then
                d_err "Error: Filesystem check failed!"
                error_detach
                exit 1
            fi
            d_ok "Filesystem check passed."

            echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
            d_step "Shrinking filesystem to ${TARGET_FS_SIZE_MB}MB..."
            echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

            if ! resize2fs -p "/dev/mapper/${TMP_MAPPER_NAME}" "${TARGET_FS_SIZE_MB}M"; then
                d_err "Error: resize2fs failed to shrink to ${TARGET_FS_SIZE_MB}MB."
                echo -e "${YELLOW}The filesystem is unchanged. Try a larger target.${NC}\n"
                error_detach
                exit 1
            fi
            d_ok "Filesystem shrunk."

            new_fs_blocks=$(dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
            new_fs_block_size=$(dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block size" | awk '{print $3}')
            new_fs_size_mb=$((new_fs_blocks * new_fs_block_size / 1024 / 1024))

	    echo
            echo -e "  Filesystem blocks: ${CYAN}${new_fs_blocks}${NC}"
            echo -e "  Block size:        ${CYAN}${new_fs_block_size}${NC}"
            echo -e "  Actual FS size:    ${CYAN}${new_fs_size_mb} MB${NC}"

            fs_sectors=$((new_fs_blocks * (new_fs_block_size / 512)))

            alignment_sectors="8"
            payload_sectors=$(( (fs_sectors + alignment_sectors - 1) / alignment_sectors * alignment_sectors ))

            header_sectors=$(cryptsetup luksDump "$CONT_TARGET" 2>/dev/null | awk '/Payload offset:/{print $3}')
            if [[ -z "$header_sectors" ]] || [[ "$header_sectors" -eq 0 ]]; then
                lv=$(cryptsetup luksDump "$CONT_TARGET" 2>/dev/null | grep -i "^Version:" | awk '{print $2}')
                if [[ "$lv" == "2" ]]; then
                    header_sectors="32768"
                else
                    header_sectors="4096"
                fi
            fi

            container_sectors=$((header_sectors + payload_sectors))
            container_mb=$(( (container_sectors * 512 + 1048575) / 1048576 ))

            echo -e "\n${GRAY}LUKS container sector math:${NC}"
            echo -e "  Filesystem sectors: ${GRAY}${fs_sectors}${NC}"
            echo -e "  Aligned payload:    ${GRAY}${payload_sectors}${NC}"
            echo -e "  LUKS header:        ${GRAY}${header_sectors}${NC}"
            echo -e "  Total container:    ${GRAY}${container_sectors}${NC}"
            echo -e "  ${YELLOW}New container size: ${container_mb} MB${NC}"

            echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
            d_step "Shrinking LUKS device..."
            echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

            if ! cryptsetup resize --size "${payload_sectors}" "/dev/mapper/${TMP_MAPPER_NAME}"; then
                d_err "Error: Failed to resize LUKS device!"
                error_detach
                exit 1
            fi
            d_ok "LUKS device resized to ${payload_sectors} sectors."

            echo -e "\n${BLUE}Closing LUKS and detaching loop device...${NC}"
            cryptsetup luksClose "${TMP_MAPPER_NAME}" 2>/dev/null || \
                cryptsetup luksClose "${TMP_MAPPER_NAME}" --force 2>/dev/null || true
            if [[ -n "$loop_dev" ]]; then
                losetup -d "$loop_dev" 2>/dev/null
                loop_dev=""
            fi

            if ! truncate -s "${container_mb}M" "$CONT_TARGET"; then
                d_err "Error: Failed to truncate file!"
                error_detach
                exit 1
            fi

            final_size_bytes=$(stat -c%s "$CONT_TARGET" 2>/dev/null)
            final_size_mb=$((final_size_bytes / 1024 / 1024))
            d_ok "File truncated to ${final_size_mb} MB"

            echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
            d_step "Final verification..."
            echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

            if verify_and_mount_container "$CONT_TARGET"; then
                echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
                echo -e "${GREEN}✓ Container successfully shrunk!${NC}"
                echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"

                final_cont_bytes=$(wc -c < "$CONT_TARGET")
                final_cont_mb=$((final_cont_bytes / 1024 / 1024))

                echo -e "Final container size:  ${GREEN}${final_cont_mb} MB${NC}"
                echo -e "Final filesystem size: ${GREEN}${new_fs_size_mb} MB${NC}"
                echo -e "Space saved:           ${GREEN}$((CALC_CONT_SIZE_MB - final_cont_mb)) MB${NC}"

            else
                d_err "Final verification failed!"
                error_detach
                exit 1
            fi
        fi

        error_detach
        manual_mount_instructions
        exit 0

    else
        d_err "Invalid selection. Please choose a number from the list [1-11]."
    fi
done


# ===========================================================================
# Create container file
# ===========================================================================
create_con() {
    echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
    d_step "Creating LUKS container file..."
    echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"
    if command -v fallocate &>/dev/null; then
        fallocate -l "${CONT_SIZE}M" "$CONT_PATH/$CONT_NAME.bin" 2>/dev/null || {
            echo -e "${YELLOW}fallocate failed, falling back to dd...${NC}"
            dd if=/dev/zero of="$CONT_PATH/$CONT_NAME.bin" bs=1M count="$CONT_SIZE" status=progress
        }
    else
        dd if=/dev/zero of="$CONT_PATH/$CONT_NAME.bin" bs=1M count="$CONT_SIZE" status=progress
    fi
}


# ===========================================================================
# Create new comtainer
# ===========================================================================
# STEP 1: Create new name
echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
d_step "LUKS Container filename"
echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

while true; do
    read -rp "Create a name for your LUKS container: " CONT_NAME
    if [[ ! "$CONT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        d_err "Error: Name contains invalid characters. Use only letters, numbers, hyphens, and underscores."
    else
        break
    fi
done
echo -e "\n${CYAN}'$CONT_NAME.bin'${NC} set."

# STEP 2: Create alias
echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
d_step "LUKS Container alias"
echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

while true; do
    echo -e "Create an ${YELLOW}alias${NC} to identify the LUKS container."
    read -rp "(eg. company-records or cloud_archive): " CONT_ALIAS

    #alias_chrs_count=$(echo "${CONT_ALIAS}" | wc -m)
    alias_chrs_count=${#CONT_ALIAS}

    if [[ -z "${CONT_ALIAS}" ]]; then
        d_err "Error: No alias set. Please create an alias."
    elif [[ ! "${CONT_ALIAS}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        d_err "Error: Alias contains invalid characters."
    elif [[ "$alias_chrs_count" -gt "18" ]]; then
        d_err "Error: Alias too long. Use less than 18 characters."
    else
        break
    fi
done
echo -e "\n${CYAN}'${CONT_ALIAS}'${NC} alias set for $CONT_NAME.bin"

# STEP 3: Location select
echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
d_step "LUKS Container location"
echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

while true; do
    read -rp "Type the LUKS container storage path (full path): " dest_path
    read -rp "Is '$dest_path' correct? [y/n] " RESP3

    if [[ "${RESP3,,}" != "y" ]]; then
        echo -e "Try again or <Ctrl+C> to cancel...\n"
    elif [[ ! "$dest_path" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        d_err "Error: Path contains invalid characters."
    elif [[ ! -d "$dest_path" ]]; then
        d_err "Error: Directory '$dest_path' does not exist."
        exit 1
    elif [[ -f "$dest_path/${CONT_NAME}.bin" ]]; then
        d_warn "Warning: Existing LUKS container already found."
        echo -e "    ${YELLOW}Change path (or rename) to continue.${NC}"
    elif cryptsetup status "${CONT_ALIAS}" &>/dev/null; then
        d_err "LUKS container alias '${CONT_ALIAS}' already exists & is in use."
        exit 1
    else
        CONT_PATH="$dest_path"
        break
    fi
done

# STEP 4: Size select
echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
d_step "LUKS Container target size"
echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"

while true; do
    read -rp "Type in the size of the LUKS container in MB: " CONT_SIZE

    if ! [[ "$CONT_SIZE" =~ ^[0-9]+$ ]]; then
        d_err "Error: Invalid input. Use numerical values only."
    elif [[ "$CONT_SIZE" -gt "1048576" ]]; then
        d_err "Error: Maximum container size is 1TB (1048576 MB)."
    elif (( CONT_SIZE < 100 )); then
        d_err "Error: Minimum size is 100 MB. Input larger size."
        continue
    elif ! check_disk_space "$CONT_PATH" "$CONT_SIZE"; then
        d_err "Cannot proceed due to insufficient disk space."
        exit 1
    else
        read -rp "Is '$CONT_SIZE' MB correct? [y/n] " RESP4
        if [[ "${RESP4,,}" != "y" ]]; then
            echo -e "Try again or <Ctrl+C> to cancel...\n"
            continue
        else
            if (( CONT_SIZE >= 1024 )); then
                CALC=$(awk "BEGIN {printf \"%.2f\", $CONT_SIZE / 1024}")
                echo -e "  ${BLUE}Estimated size:${NC} $CONT_SIZE MB ≈ ${CALC} GB"
            fi
            break
        fi
    fi
done

# STEP 5: Keyfile setup
echo -e "\n${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}"
d_step "Keyfile Setup"
echo -e "${BLUE}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${NC}\n"
echo -e "Would you like to add a keyfile to unlock this"
echo -e "container?"
echo -e "  ${BLUE}1)${NC} ${CYAN}Password only (default)${NC}"
echo -e "  ${BLUE}2)${NC} ${CYAN}Add a keyfile in addition to password${NC}"
echo -e "  ${BLUE}3)${NC} ${CYAN}Add a keyfile instead of password${NC}\n"

read -rp "Enter choice [1-3]: " keyfile_setup_choice
keyfile_setup_choice="${keyfile_setup_choice:-1}"

USE_KEYFILE="false"

if [[ "$keyfile_setup_choice" == "2" ]] || [[ "$keyfile_setup_choice" == "3" ]]; then
    echo -e "\n${CYAN}Keyfile Configuration:${NC}"

    read -rp "Enter directory to save keyfile: " keyfile_dir

    if [[ ! "${keyfile_dir}" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        d_err "Error: Invalid characters in directory path."
        keyfile_dir="$CONT_PATH"
        echo -e "${YELLOW}Falling back to: ${keyfile_dir}${NC}"
    fi

    if [[ ! -d "${keyfile_dir}" ]]; then
        mkdir -p "${keyfile_dir}" || { d_err "Failed to create directory."; keyfile_dir="$CONT_PATH"; }
    fi

    read -rp "Enter keyfile name (default: ${CONT_NAME}.keyfile): " keyfile_name

    if [[ ! "${keyfile_name}" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        d_err "Error: Invalid characters in keyfile name. Using default."
        keyfile_name="${CONT_NAME}.keyfile"
    fi

    keyfile_path="${keyfile_dir}/${keyfile_name}"

    while true; do
        read -rp "Keyfile size in bytes (default: 4096): " keyfile_size
        keyfile_size="${keyfile_size:-4096}"

        if [[ "$keyfile_size" -gt "65536" ]]; then
            echo -e "${YELLOW}Warning: Keyfile size exceeds 64KB. Large keyfiles are unnecessary.${NC}"
            read -rp "Continue with $keyfile_size bytes? [y/N]: " confirm_large
            if [[ "${confirm_large,,}" != "y" ]]; then
                continue
            fi
        fi

        if validate_positive_integer "$keyfile_size" "Keyfile size"; then
            break
        fi
    done

    echo -e "\n${CYAN}Generating random keyfile...${NC}"

    dd if=/dev/urandom of="${keyfile_path}" bs=1 count="$keyfile_size" 2>/dev/null

    keyfile_size_actual=$(stat -c%s "${keyfile_path}" 2>/dev/null)
    if [[ "$keyfile_size_actual" -ne "$keyfile_size" ]]; then
        d_err "Error: Keyfile size mismatch. Expected: $keyfile_size, Got: $keyfile_size_actual"
        rm -f "${keyfile_path}" 2>/dev/null
        exit 1
    fi

    chmod 600 "${keyfile_path}"
    if ! chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${keyfile_path}" 2>/dev/null; then
        chown root:root "${keyfile_path}" 2>/dev/null
    fi

    d_ok "Keyfile generated: ${keyfile_path}"
    echo -e "    Size: ${keyfile_size_actual} bytes"
    echo -e "    Permissions: $(stat -c%a "${keyfile_path}")"

    USE_KEYFILE="true"
fi

# STEP 6: Create container
create_con
d_ok "'${CONT_NAME}.bin' created in $CONT_PATH"

if ! loop_dev=$(losetup -f --show --direct-io=on "$CONT_PATH/${CONT_NAME}.bin" 2>/dev/null) || [[ -z "$loop_dev" ]]; then
    d_err "Failed to get loop device."
    exit 1
fi

attached_verify3=$(losetup -l "$loop_dev" 2>/dev/null | awk 'NR==2 {print $6}')
if [[ "$attached_verify3" != "$CONT_PATH/${CONT_NAME}.bin" ]]; then
    d_err "Error: Loop device verification failed!"
    losetup -d "$loop_dev" 2>/dev/null || true
    loop_dev=""
    exit 1
fi

# STEP 7: Format LUKS
if [[ "$USE_KEYFILE" == true ]] && [[ "$keyfile_setup_choice" == "3" ]]; then
    echo -e  "\nCreating LUKS container with keyfile only..."
    cryptsetup -q -y luksFormat "$loop_dev" --key-file="${keyfile_path}"
elif [[ "$USE_KEYFILE" == true ]] && [[ "$keyfile_setup_choice" == "2" ]]; then
    echo -e "\nCreating LUKS container with password..."
    if cryptsetup -q -y luksFormat "$loop_dev"; then
        d_ok "LUKS container formatted with password"
        echo -e "\nAdding keyfile..."
        cryptsetup -q -y luksAddKey "$loop_dev" "${keyfile_path}"
    fi
else
    cryptsetup -q -y luksFormat "$loop_dev"
fi

exit_code2=$?
if [[ "$exit_code2" -ne "0" ]]; then
    d_err "Error: LUKS format failed."
    losetup -d "$loop_dev" 2>/dev/null
    exit 1
fi

echo
d_ok "LUKS container formatted"

# STEP 8: Open LUKS
echo -e "\n${BLUE}Opening LUKS container...${NC}"

if [[ "$USE_KEYFILE" == true ]] && [[ "$keyfile_setup_choice" == "3" ]]; then
    cryptsetup luksOpen "$loop_dev" "${CONT_ALIAS}" --key-file="${keyfile_path}"
else
    cryptsetup luksOpen "$loop_dev" "${CONT_ALIAS}"
fi

exit_code3=$?
if [[ "$exit_code3" -ne "0" ]]; then
    d_err "Error: Failed to open LUKS container."
    losetup -d "$loop_dev" 2>/dev/null
    exit 1
fi

# STEP 9: Create ext4 filesystem
if ! mkfs.ext4 -F "/dev/mapper/${CONT_ALIAS}"; then
    d_err "Error: Filesystem creation failed."
    cryptsetup luksClose "${CONT_ALIAS}" 2>/dev/null
    losetup -d "$loop_dev" 2>/dev/null
    exit 1
fi

d_ok "Filesystem created"
echo

# ===========================================================================
# Header backup prompt
# ===========================================================================
read -rp "Do you want to backup the LUKS container header? (default: n) [y/N] " RESP5
RESP5="${RESP5:-n}"

if [[ "${RESP5,,}" = "y" ]]; then
    container="$CONT_PATH/${CONT_NAME}.bin"
    backup_file="$CONT_PATH/${CONT_NAME}_header_$(date +%Y%m%d).img"

    if cryptsetup -q luksHeaderBackup "$container" --header-backup-file "$backup_file"; then
        d_ok "LUKS header backed up successfully!"
	echo
        HEADER_SET="true"
    else
        d_err "Header backup failed!"
	HEADER_SET="false"
    fi
else
    echo -e "LUKS header backup skipped."
fi


# ===========================================================================
# Mount prompt
# ===========================================================================
read -rp "Do you want to mount the LUKS container? (default: n) [y/N] " RESP6
RESP6="${RESP6:-n}"

if [[ "${RESP6,,}" = "y" ]]; then
    read -rp "Type the mount path (full path): " MOUNT_PATH
    if [[ -d "${MOUNT_PATH}" ]]; then
        if ! mount "/dev/mapper/${CONT_ALIAS}" "${MOUNT_PATH}"; then
            d_err "Error: Failed to mount container."
            mounted_flag="false"
        fi

        chown -R "$USERNAME":"$USERNAME" "${MOUNT_PATH}" 2>/dev/null
	echo
        d_ok "LUKS container mounted to: ${MOUNT_PATH}"
	echo
        mounted_flag="true"
    else
        d_err "Error: Cannot find the specified path '${MOUNT_PATH}'"
        read -rp "Would you like to create the directory? [y/n] " RESP7
        if [[ "${RESP7,,}" = "y" ]]; then
            mkdir -p "${MOUNT_PATH}"
            if ! mount "/dev/mapper/${CONT_ALIAS}" "${MOUNT_PATH}"; then
                d_err "Error: Failed to mount container."
                rmdir "${MOUNT_PATH}" 2>/dev/null
                mounted_flag="false"
            fi

            chown -R "$USERNAME":"$USERNAME" "${MOUNT_PATH}" 2>/dev/null
            d_ok "LUKS container mounted to: ${MOUNT_PATH}"
            mounted_flag="true"
        else
            d_exit "LUKS container won't be mounted."
        fi
    fi
else
    echo -e "Mounting LUKS container skipped."
fi

if [[ "$mounted_flag" == "false" ]]; then
    manual_mount_instructions
fi

# ===========================================================================
# Success summary
# ===========================================================================
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ LUKS container successfully created!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "  Container file: ${CYAN}$CONT_PATH/${CONT_NAME}.bin${NC}"
if [[ "$HEADER_SET" == "true" ]]; then
    echo -e "  Header:         ${CYAN}${backup_file}${NC}"
    echo -e "  Permissions:    $(sudo stat -c%a "$backup_file")"
fi
if [[ "$USE_KEYFILE" == "true" ]]; then
    echo -e "  Keyfile:        ${CYAN}${keyfile_path}${NC}"
fi
if [[ "$mounted_flag" == "true" ]]; then
    echo -e "  Mount point:    ${CYAN}${MOUNT_PATH}${NC}"
    echo -e "  Mapper name:    ${CYAN}$CONT_ALIAS${NC}"
    echo -e "\n${YELLOW}To unmount and close:${NC}"
    echo -e "  sudo umount $MOUNT_PATH"
    echo -e "  sudo cryptsetup luksClose $CONT_ALIAS"
    echo -e "  sudo losetup -d $loop_dev"
else
    echo -e "  Size:           ${CYAN}$CONT_SIZE MB${NC}"
fi
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}\n"

# Final cleanup
error_detach


##############
# SCRIPT END #
##############
