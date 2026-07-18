#!/bin/bash

# Version variable
VRS=v4.4

##############################################
# Script to create & mount a LUKS container. #
# Supports multiple file containers (.bin)   #
# Block devices (partitions) unsupported.    #
##############################################

# Colors
BLACK='\033[0;30m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
GRAY="\e[90m"

# Effects
UNDERLINE='\033[4m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Constants
LUKS_HEADER_SIZE=16  # MB for header overhead

# Global array for container files
CONT_FILES=()

# Initialize global variables (prevent unbound variable errors)
LOSP=""
loop_dev=""
MOUNT_PATH=""
CON_ALIAS=""
CONT_TARGET1=""
TOTAL_REAL_SIZE=0
FS_SIZE_MB=0
SKIP_CLEANUP=""
DISPLAY_KEYSLOTS_COUNT=0

# Shrink calculation globals
CALC_MIN_SIZE=0
CALC_MIN_CONTAINER=0
CALC_RESIZE2FS_MIN=0
CALC_RESIZE2FS_MIN_MB=0
CALC_SAFETY_LEVEL=""
CALC_CONT_SIZE_MB=0
RESIZE2FS_MIN_BLOCKS=""

# Use secure temporary directory
TMP_MOUNT=$(mktemp -d /tmp/luks_mnt.XXXXXX)
if [[ -z "$TMP_MOUNT" ]] || [[ ! -d "$TMP_MOUNT" ]]; then
    echo -e "${RED}Error: Failed to create secure temporary directory${NC}" >&2
    exit 1
fi

# Use unpredictable temporary mapper name
TMP_MAPPER_NAME="luks_tmp_$(openssl rand -hex 4 2>/dev/null || cat /dev/urandom | tr -dc 'a-z0-9' | head -c 8)"

###########################################################
# Cleanup open or mounted containers on error/forced exit #
###########################################################
cleanup() {
    local exit_code=$?

    if [[ -n "$SKIP_CLEANUP" ]]; then
        exit $exit_code
    fi

    # Cleanup with error reporting
    local cleanup_errors=0

    if [[ -n "$MOUNT_PATH" ]] && mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
        if ! sudo umount "$MOUNT_PATH" 2>/dev/null; then
            echo -e "${YELLOW}Warning: Failed to unmount $MOUNT_PATH${NC}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if mountpoint -q "$TMP_MOUNT" 2>/dev/null; then
        if ! sudo umount "$TMP_MOUNT" 2>/dev/null; then
            echo -e "${YELLOW}Warning: Failed to unmount $TMP_MOUNT${NC}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if [[ -n "$CON_ALIAS" ]]; then
        if sudo cryptsetup status "$CON_ALIAS" &>/dev/null; then
            if ! sudo cryptsetup luksClose "$CON_ALIAS" 2>/dev/null; then
                echo -e "${YELLOW}Warning: Failed to close $CON_ALIAS${NC}" >&2
                cleanup_errors=$((cleanup_errors + 1))
            fi
        fi
    fi

    if sudo cryptsetup status "$TMP_MAPPER_NAME" &>/dev/null; then
        if ! sudo cryptsetup luksClose "$TMP_MAPPER_NAME" 2>/dev/null; then
            echo -e "${YELLOW}Warning: Failed to close $TMP_MAPPER_NAME${NC}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if [[ -n "$LOSP" ]]; then
        if ! sudo losetup -d "$LOSP" 2>/dev/null; then
            echo -e "${YELLOW}Warning: Failed to detach loop device.${NC}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi
    if [[ -n "$loop_dev" ]]; then
        if ! sudo losetup -d "$loop_dev" 2>/dev/null; then
            echo -e "${YELLOW}Warning: Failed to detach loop device.${NC}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if [[ -d "$TMP_MOUNT" ]]; then
        if ! rm -rf "$TMP_MOUNT" 2>/dev/null; then
            echo -e "${YELLOW}Warning: Failed to remove temp directory $TMP_MOUNT${NC}" >&2
            cleanup_errors=$((cleanup_errors + 1))
        fi
    fi

    if [[ $cleanup_errors -gt 0 ]]; then
        echo -e "${RED}Cleanup completed with $cleanup_errors errors. Manual intervention may be required.${NC}" >&2
        echo -e "${YELLOW}Check for existing loop devices with:${NC}"
        echo -e "  sudo losetup -l"
        echo -e "${YELLOW}Detach open loop devices with:${NC}"
        echo -e "  sudo losetup -d <loop-device>"
    fi

    exit $exit_code
}

trap cleanup EXIT

# Privilege validation (uncomment to make strict checks)
check_privileges() {
    #if [[ $EUID -eq 0 ]]; then
        #echo -e "${YELLOW}Warning: Running as root directly. Consider using sudo for specific commands for better audit trails.${NC}"
    #fi

    if ! sudo -n true 2>/dev/null; then
        echo -e "${YELLOW}Note: This script requires sudo privileges. You may be prompted for your password.${NC}"
    fi
}

##############################
# Check available disk space #
##############################
check_disk_space() {
    local target_dir="$1"
    local required_mb="$2"

    local available_mb=$(df --output=avail -B 1M "$target_dir" | tail -n 1)
    local buffer_mb=$((required_mb / 10))
    local total_required_mb=$((required_mb + buffer_mb))

    echo -e "\n${CYAN}Checking disk space...${NC}"
    echo -e "  Required: ${required_mb} MB"
    echo -e "  Buffer (10%): ${buffer_mb} MB"
    echo -e "  Total needed: ${total_required_mb} MB"
    echo -e "  Available: ${available_mb} MB"

    if (( available_mb < total_required_mb )); then
        echo -e "${RED}Error:${NC} Insufficient disk space!"
        echo -e "  Need: ${total_required_mb} MB"
        echo -e "  Available: ${available_mb} MB"
        echo -e "  Shortage: $((total_required_mb - available_mb)) MB"
        return 1
    else
        echo -e "${GREEN}✓ Sufficient disk space available${NC}\n"
        return 0
    fi
}

###########################
# Find existing container #
###########################
find_con () {
    local exs_path
    local file

    echo
    read -p "Specify LUKS container directory (full path): " exs_path

    # Strict path validation
    if [[ ! "$exs_path" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        echo -e "\n${RED}Error:${NC} Path contains invalid characters. Use only letters, numbers, underscores, dots, slashes, and hyphens.\n" >&2
        exit 1
    fi

    if [[ ! -d "$exs_path" ]]; then
        echo -e "\n${RED}Error:${NC} ${CYAN}'$exs_path'${NC} is not a valid directory. Script will exit.\n" >&2
        exit 1
    elif [[ ! -r "$exs_path" ]]; then
        echo -e "\n${RED}Error:${NC} ${CYAN}'$exs_path'${NC} is not readable. Please check directory permissions.\n" >&2
        exit 1
    fi

    CONT_FILES=()

    while IFS= read -r -d '' file; do
        if sudo cryptsetup isLuks "$file" 2>/dev/null; then
            CONT_FILES+=("$file")
        fi
    done < <(find "$exs_path" -maxdepth 1 -type f -size +16M -print0 2>/dev/null)

    if [[ ${#CONT_FILES[@]} -eq 0 ]]; then
        echo -e "\n${BLUE}No LUKS-encrypted containers found in${NC} '$exs_path'\n"
        exit 1
    fi

    echo -e "\n═════════════════════════════════════════════════════════"
    echo -e "${YELLOW}Select LUKS container${NC}"
    echo -e "═════════════════════════════════════════════════════════\n"
    PS3=$'\nOption: '
    select CONT_TARGET1 in "${CONT_FILES[@]}" "Exit"; do
        if [[ "$CONT_TARGET1" == "Exit" ]]; then
            echo -e "${BLUE}No LUKS container selected. Script will exit here.${NC}\n"
            exit 1
        elif [[ -n "$CONT_TARGET1" ]]; then
            echo -e "\n${CYAN}'$CONT_TARGET1'${NC} container selected."
            break
        else
            echo "Invalid selection. Please choose a number from the list."
        fi
    done
}

############################################
# Mount and verify container before resize #
############################################
verify_and_mount_container() {
    local container_path="$1"
    local unmount_flag="$2"
    local fs_size block_size fs_size_mb total_real_size actual_blocks

    # Validate container path
    if [[ ! -f "$container_path" ]]; then
        echo -e "${RED}Error: Container file not found${NC}\n"
        exit 1
    fi

    if ! findmnt "/dev/mapper/${TMP_MAPPER_NAME}" &>/dev/null; then
        # Atomic loop device attachment
        local loop_dev
        loop_dev=$(sudo losetup -f --show --direct-io=on "$container_path" 2>/dev/null)
        if [[ $? -ne 0 ]] || [[ -z "$loop_dev" ]]; then
            echo -e "${RED}Error: Failed to get loop device${NC}\n"
            exit 1
        fi

        # Verify the loop device is actually attached to our file
        local attached_file
        attached_file=$(sudo losetup -l "$loop_dev" 2>/dev/null | awk 'NR==2 {print $6}')
        if [[ "$attached_file" != "$container_path" ]]; then
            echo -e "${RED}Error: Loop device verification failed!${NC}\n"
            sudo losetup -d "$loop_dev" 2>/dev/null || true
            loop_dev=""
            exit 1
        fi

        sudo cryptsetup luksOpen "$loop_dev" "$TMP_MAPPER_NAME"
        if [[ $? -ne 0 ]]; then
            echo -e "\n${RED}Error: Failed to open LUKS container! Wrong password or corrupted container.${NC}\n"
            error_detach
            exit 1
        fi
    fi

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Verifying container integrity...${NC}"
    echo -e "${BLUE}===============================================${NC}\n"
    echo -e "Running filesystem check (auto-fix)..."
    sudo e2fsck -fy "/dev/mapper/${TMP_MAPPER_NAME}"
    local e2fsck_result=$?
    if [[ $e2fsck_result -gt 2 ]]; then
        echo -e "\n${RED}Error: Filesystem check failed (exit code: $e2fsck_result)! Container may be corrupted.${NC}"
        echo -e "${YELLOW}Try running manually: sudo e2fsck -f /dev/mapper/${TMP_MAPPER_NAME}${NC}\n"
        error_detach
        exit 1
    fi
    echo -e "${GREEN}✓ Filesystem check completed.${NC}\n"

    # Capture resize2fs minimum BEFORE mounting (device is open but unmounted)
    echo -e "Querying resize2fs for absolute minimum size..."
    local resize2fs_min_output
    resize2fs_min_output=$(sudo resize2fs -P "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null)
    RESIZE2FS_MIN_BLOCKS=$(echo "$resize2fs_min_output" | awk '/minimum size/{print $NF}')
    if [[ -n "$RESIZE2FS_MIN_BLOCKS" ]] && [[ "$RESIZE2FS_MIN_BLOCKS" =~ ^[0-9]+$ ]]; then
        echo -e "  resize2fs minimum: ${GRAY}${RESIZE2FS_MIN_BLOCKS} blocks${NC}"
    else
        echo -e "  ${YELLOW}Warning: Could not query resize2fs minimum${NC}"
        RESIZE2FS_MIN_BLOCKS=""
    fi

    fs_size=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
    block_size=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block size" | awk '{print $3}')

    if [[ -z "$fs_size" ]] || [[ -z "$block_size" ]]; then
        echo -e "${RED}Error: Could not determine filesystem size.${NC}\n"
        error_detach
        exit 1
    fi

    fs_size_mb=$(( fs_size * block_size / 1024 / 1024 ))

    if [[ ! -d "$TMP_MOUNT" ]]; then
        sudo mkdir -p "$TMP_MOUNT"
    fi

    echo -e "Mounting temporarily to check data size..."
    sudo mount "/dev/mapper/${TMP_MAPPER_NAME}" "$TMP_MOUNT"
    if [[ $? -ne 0 ]]; then
        echo -e "\n${RED}Error: Failed to mount LUKS container!${NC}\n"
        error_detach
        exit 1
    fi

    # Capture BOTH apparent size and actual block usage
    total_real_size=$(du --apparent-size -smc "$TMP_MOUNT" 2>/dev/null | grep total | awk '{print $1}')
    actual_blocks=$(du -smc "$TMP_MOUNT" 2>/dev/null | grep total | awk '{print $1}')

    if [[ -z "$total_real_size" ]] || [[ "$total_real_size" -eq 0 ]]; then
        total_real_size=$(du -smc "$TMP_MOUNT" 2>/dev/null | grep total | awk '{print $1}')
        actual_blocks=$total_real_size
    fi

    if findmnt "/dev/mapper/${TMP_MAPPER_NAME}" &>/dev/null; then
        sudo umount "$TMP_MOUNT" 2>/dev/null || sudo umount -l "$TMP_MOUNT" 2>/dev/null
        sudo rm -rf "$TMP_MOUNT" 2>/dev/null
    fi

    echo -e "\n${GREEN}✓ Container verified.${NC}\n"
    echo -e "  Current filesystem size: ${fs_size_mb} MB"
    echo -e "  Current data size (apparent): ${total_real_size} MB"
    if [[ -n "$actual_blocks" ]] && [[ "$actual_blocks" -ne "$total_real_size" ]]; then
        echo -e "  Current data size (actual blocks): ${YELLOW}${actual_blocks} MB${NC}"
        echo -e "  Block overhead: ${GRAY}$((actual_blocks - total_real_size)) MB${NC}"
    fi

    if [[ -z $unmount_flag ]]; then
        sudo cryptsetup luksClose "$TMP_MAPPER_NAME" 2>/dev/null
        sudo losetup -d "$loop_dev" 2>/dev/null
        loop_dev=""
    fi

    TOTAL_REAL_SIZE=$total_real_size
    FS_SIZE_MB=$fs_size_mb
    BLOCK_SIZE=$block_size
    FS_BLOCKS=$fs_size
    ACTUAL_BLOCKS_MB=$actual_blocks

    return 0
}


########################################################
# Calculate minimum safe container size for shrinking  #
########################################################
calculate_min_safe_size() {
    local fs_size_mb=$1
    local data_size_mb=$2

    # Validate inputs
    if [[ -z "$fs_size_mb" ]] || [[ -z "$data_size_mb" ]]; then
        echo -e "${RED}Error: Missing required parameters${NC}\n" >&2
        return 1
    fi

    if [[ ! "$fs_size_mb" =~ ^[0-9]+$ ]] || [[ ! "$data_size_mb" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: Size values must be positive integers${NC}\n" >&2
        return 1
    fi

    if [[ $data_size_mb -gt $fs_size_mb ]]; then
        echo -e "${RED}Error: Data size cannot exceed filesystem size${NC}\n" >&2
        return 1
    fi

    if [[ $fs_size_mb -eq 0 ]]; then
        echo -e "${RED}Error: Filesystem size cannot be zero${NC}\n" >&2
        return 1
    fi

    # Use resize2fs minimum captured during verify
    local resize2fs_min_blocks="$RESIZE2FS_MIN_BLOCKS"

    if [[ -z "$resize2fs_min_blocks" ]] || [[ "$resize2fs_min_blocks" -eq 0 ]]; then
        echo -e "${RED}Error: resize2fs minimum not available. Was verify_and_mount_container called first?${NC}\n" >&2
        return 1
    fi

    CALC_RESIZE2FS_MIN=$resize2fs_min_blocks
    CALC_RESIZE2FS_MIN_MB=$((resize2fs_min_blocks * BLOCK_SIZE / 1024 / 1024))

    # DYNAMIC SAFETY MARGIN calc: Scale with container size
    local dynamic_safety_mb
    if [[ $fs_size_mb -lt 1024 ]]; then
        dynamic_safety_mb=64
    elif [[ $fs_size_mb -lt 10240 ]]; then
        dynamic_safety_mb=128
    elif [[ $fs_size_mb -lt 51200 ]]; then
        dynamic_safety_mb=256
    elif [[ $fs_size_mb -lt 102400 ]]; then
        dynamic_safety_mb=512
    else
        dynamic_safety_mb=1024
    fi

    # PRACTICAL MINIMUM calc: resize2fs minimum + safety margin
    local practical_min_mb=$((CALC_RESIZE2FS_MIN_MB + dynamic_safety_mb))

    # Ensure practical minimum doesn't exceed current filesystem
    if [[ $practical_min_mb -gt $fs_size_mb ]]; then
        practical_min_mb=$fs_size_mb
    fi

    # Add LUKS header for final container size
    local final_container_min_mb=$((practical_min_mb + LUKS_HEADER_SIZE))

    # BLOCK OVERHEAD ESTIMATE (if actual > apparent)
    local block_overhead_mb=0
    if [[ -n "$ACTUAL_BLOCKS_MB" ]] && [[ "$ACTUAL_BLOCKS_MB" -gt "$data_size_mb" ]]; then
        block_overhead_mb=$((ACTUAL_BLOCKS_MB - data_size_mb))
    fi

    # Store results in variables
    CALC_MIN_SIZE=$practical_min_mb
    CALC_MIN_CONTAINER=$final_container_min_mb

    # Determine safety level
    if [[ $practical_min_mb -ge $fs_size_mb ]]; then
        CALC_SAFETY_LEVEL="CANNOT_SHRINK"
    elif [[ $CALC_RESIZE2FS_MIN_MB -gt $((fs_size_mb / 2)) ]]; then
        CALC_SAFETY_LEVEL="CRITICAL"
    elif [[ $practical_min_mb -gt $((fs_size_mb * 3 / 4)) ]]; then
        CALC_SAFETY_LEVEL="AGGRESSIVE"
    else
        CALC_SAFETY_LEVEL="SAFE"
    fi

    # Display analysis banner
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Shrink Size Analysis${NC}"
    echo -e "${BLUE}===============================================${NC}"
    echo -e "  Current container size:      ${CALC_CONT_SIZE_MB} MB"
    echo -e "  Current filesystem size:     ${fs_size_mb} MB"
    echo -e "  Data content (apparent):     ${YELLOW}${data_size_mb} MB${NC}"
    if [[ $block_overhead_mb -gt 0 ]]; then
        echo -e "  Block-level overhead:        ${GRAY}${block_overhead_mb} MB${NC}"
    fi
    echo -e "  ─────────────────────────────────────────────"
    echo -e "  ${CYAN}resize2fs absolute minimum:  ${CALC_RESIZE2FS_MIN_MB} MB${NC}"
    echo -e "    (${resize2fs_min_blocks} blocks x ${BLOCK_SIZE} bytes)"
    echo -e "  ${GRAY}Dynamic safety margin:       ${dynamic_safety_mb} MB${NC}"
    echo -e "  ─────────────────────────────────────────────"
    echo -e "  ${GREEN}PRACTICAL MINIMUM (safe):    ${practical_min_mb} MB${NC}"
    echo -e "  ${GRAY}Minimum container size:      ${final_container_min_mb} MB${NC}"
    echo -e "  ─────────────────────────────────────────────"

    case $CALC_SAFETY_LEVEL in
        "SAFE")
            echo -e "  Safety margin:               ${GREEN}ADEQUATE${NC}"
            ;;
        "AGGRESSIVE")
            echo -e "  Safety margin:               ${YELLOW}REDUCED${NC}"
            echo -e "  ${YELLOW}Container is more than 75% full. Shrink with caution.${NC}"
            ;;
        "CRITICAL")
            echo -e "  Safety margin:               ${RED}MINIMAL${NC}"
            echo -e "  ${RED}resize2fs minimum exceeds 50% of current size.${NC}"
            ;;
        "CANNOT_SHRINK")
            echo -e "${RED}⛔ CRITICAL: Cannot safely shrink below current${NC}"
            echo -e "${RED}size. The filesystem minimum (${CALC_RESIZE2FS_MIN_MB} MB) leaves no${NC}"
            echo -e "${RED}room for shrink.${NC}"
            ;;
    esac

    # Important information banner
    echo -e "\n${YELLOW}Important:${NC}"
    echo -e "• Shrinking carries inherent risk of data loss."
    echo -e "• ${BOLD}ALWAYS create a backup before proceeding.${NC}"
    echo -e "• The resize2fs minimum is the ABSOLUTE floor"
    echo -e "  - never go below it."
    echo -e "${BLUE}===============================================${NC}"

    # Shrink target too small display
    if [[ "$CALC_SAFETY_LEVEL" == "CANNOT_SHRINK" ]]; then
        echo -e "${YELLOW}Shrinking is not possible for this container!${NC}"
        echo -e "${YELLOW}Consider removing files or creating a new smaller${NC}"
        echo -e "${YELLOW}container.${NC}"
        echo -e "${BLUE}===============================================${NC}"
        echo -e "\n${BLUE}Script will exit${NC}\n"
    fi

    return 0
}


#############################
# Unmount & detach on error #
#############################
error_detach () {
    # Check if mounted before attempting unmount
    if mountpoint -q "$TMP_MOUNT" 2>/dev/null; then
        sudo umount "$TMP_MOUNT" 2>/dev/null || sudo umount -l "$TMP_MOUNT" 2>/dev/null
    fi
    if sudo cryptsetup status "$TMP_MAPPER_NAME" &>/dev/null; then
        sudo cryptsetup luksClose "$TMP_MAPPER_NAME" 2>/dev/null
    fi
    [[ -n "$loop_dev" ]] && sudo losetup -d "$loop_dev" 2>/dev/null
    [[ -n "$LOSP" ]] && sudo losetup -d "$LOSP" 2>/dev/null
    [[ -d "$TMP_MOUNT" ]] && rm -rf "$TMP_MOUNT" 2>/dev/null

    # Reset global variables to prevent stale references
    loop_dev=""
    LOSP=""
}

#############################
# Manual mount instructions #
#############################
manual_mount_ins() {
echo -e "\n══════════════════════════════════════════════════════"
echo -e "${YELLOW}To open, mount, & set write permissions on dir:${NC}"
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

###############################
# Display keyslot information #
###############################
display_keyslots() {
    local container_path="$1"
    local luks_dump
    luks_dump=$(sudo cryptsetup luksDump "$container_path" 2>/dev/null)

    if [[ -z "$luks_dump" ]]; then
        echo -e "${RED}Error: Could not read LUKS header${NC}"
        DISPLAY_KEYSLOTS_COUNT=0
        return 1
    fi

    # Always detect LUKS version fresh
    local luks_version
    luks_version=$(echo "$luks_dump" | grep -i "^Version:" | awk '{print $2}')

    echo -e "${CYAN}LUKS Version:${NC} ${luks_version:-Unknown}"

    # Count enabled keyslots
    local enabled_count=0

    if [[ "$luks_version" == "2" ]]; then
        # LUKS2 format
        echo -e "\n${CYAN}Keyslot Status:${NC}"

        # Use JSON metadata for robust LUKS2 parsing
        # Replace fragile text parsing with JSON where available
        local json_dump
        json_dump=$(sudo cryptsetup luksDump --dump-json-metadata "$container_path" 2>/dev/null)

        if [[ -n "$json_dump" ]] && command -v jq &>/dev/null; then
            # Use jq for robust JSON parsing if available
            local slots
            slots=$(echo "$json_dump" | jq -r '.keyslots | keys[]' 2>/dev/null)
            if [[ -n "$slots" ]]; then
                for slot in $slots; do
                    local priority
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
            # Fallback to text parsing
            local in_keyslots=0
            local current_slot=""

            while IFS= read -r line; do
                # Exact match for "Keyslots:" (the section header, not "Keyslots area:")
                if [[ "$line" =~ ^Keyslots:$ ]]; then
                    in_keyslots=1
                    continue
                fi

                # Exit keyslots section on Tokens: or Digests: sections
                if [[ $in_keyslots -eq 1 ]] && [[ "$line" =~ ^(Tokens:|Digests:) ]]; then
                    in_keyslots=0
                    continue
                fi

                # Only process lines while in keyslots section
                if [[ $in_keyslots -eq 1 ]]; then
                    # Make sure it's a keyslot entry with format "  N: luks2"
                    if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]+luks2 ]]; then
                        current_slot="${BASH_REMATCH[1]}"
                    fi

                    # Match priority for current slot
                    if [[ -n "$current_slot" ]] && [[ "$line" =~ Priority:[[:space:]]*(.+) ]]; then
                        local priority="${BASH_REMATCH[1]}"
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
        # LUKS1 format
        echo -e "\n${CYAN}Keyslot Status:${NC}"
        while IFS= read -r line; do
            if [[ "$line" =~ ^Key[[:space:]]Slot[[:space:]]([0-9]+):[[:space:]]*(.+) ]]; then
                local slot_num="${BASH_REMATCH[1]}"
                local status="${BASH_REMATCH[2]}"
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

    # Store the count in a global variable instead of using return
    DISPLAY_KEYSLOTS_COUNT=$enabled_count
    return 0
}


######################
# Backup LUKS header #
######################
backup_luks_header() {
    local container_path="$1"
    local backup_path

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Header Backup${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "${YELLOW}⚠️ IMPORTANT:${NC} The LUKS header contains encryption"
    echo -e "keys. If the header is damaged, all data is lost."
    echo -e "Keep backups safe!\n"

    read -p "Enter backup directory (full path): " backup_path

    # Validate backup path
    if [[ ! "$backup_path" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        echo -e "${RED}Error: Invalid characters in path${NC}\n"
        return 1
    fi

    if [[ ! -d "$backup_path" ]]; then
        echo -e "${YELLOW}Directory doesn't exist. Creating...${NC}"
        sudo mkdir -p "$backup_path" || { echo -e "${RED}Failed to create directory.${NC}\n"; return 1; }
    fi

    local backup_file="$backup_path/$(basename "$container_path")_header_$(date +%Y%m%d).img"

    echo -e "\n${CYAN}Backing up to:${NC} $backup_file"
    sudo cryptsetup luksHeaderBackup "$container_path" --header-backup-file "$backup_file"

    if [[ $? -eq 0 ]]; then
        # Set restrictive permissions on backup (to prevent world-readable LUKS header backups)
        # Optional
        #sudo chmod 600 "$backup_file"
        #sudo chown root:root "$backup_file" 2>/dev/null || true

        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ LUKS header backed up successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "  Backup: ${CYAN}$backup_file${NC}"
        echo -e "  Size: $(sudo stat -c%s "$backup_file" | numfmt --to=iec) bytes"
        echo -e "  Permissions: $(sudo stat -c%a "$backup_file")"
        echo -e "\n${YELLOW}Restore command:${NC}"
        echo -e "  sudo cryptsetup luksHeaderRestore <container> \\"
        echo -e "  --header-backup-file <backup-header>"
    else
        echo -e "${RED}✗ Header backup failed!${NC}"
        return 1
    fi
    echo
}

#######################
# Restore LUKS header #
#######################
restore_luks_header() {
    local container_path="$1"
    local backup_file

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Header Restore${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ ⚠️  CRITIAL WARNING: Header Restore Operation       ║${NC}"
    echo -e "${RED}║                                                    ║${NC}"
    echo -e "${RED}║ Restoring a header will OVERWRITE existing keys!   ║${NC}"
    echo -e "${RED}║ Any passphrases/keyfiles not in the backup will    ║${NC}"
    echo -e "${RED}║ be PERMANENTLY LOST!                               ║${NC}"
    echo -e "${RED}║ This operation is typically used for:              ║${NC}"
    echo -e "${RED}║ • Recovering from header corruption                ║${NC}"
    echo -e "${RED}║ • Restoring lost passphrases from backup           ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${YELLOW}To recover header from intentional deletion (eg. nuked${NC}"
    echo -e "${YELLOW}header for anti-forensics) you will need to restore${NC}"
    echo -e "${YELLOW}header manually:${NC}"
    echo -e "  sudo cryptsetup luksHeaderRestore <container> \\"
    echo -e "  --header-backup-file <header.img>\n"
    echo -e "  ─────────────────────────────────────────────\n"

    # Show current keyslots for comparison
    echo -e "${YELLOW}Current container keyslots:${NC}"
    display_keyslots "$container_path"
    echo

    # Get backup file path
    read -p "Enter path to header backup file (.img): " backup_file

    # Validate backup file path
    if [[ ! "$backup_file" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        echo -e "\n${RED}Error:${NC} Invalid characters in backup file path.\n"
        return 1
    fi

    # Sanity checks on backup file
    if [[ ! -f "$backup_file" ]]; then
        echo -e "\n${RED}Error:${NC} Backup file '$backup_file' does not exist.\n"
        return 1
    fi

    if [[ ! -r "$backup_file" ]]; then
        echo -e "\n${RED}Error:${NC} Backup file is not readable. Check permissions.\n"
        return 1
    fi

    # Check backup file permissions
    local backup_perms
    backup_perms=$(stat -c%a "$backup_file" 2>/dev/null)
    if [[ -n "$backup_perms" ]] && [[ "$backup_perms" != "600" ]] && [[ "$backup_perms" != "400" ]]; then
        echo -e "\n${YELLOW}Warning:${NC} Backup file permissions are $backup_perms (expected 600 or 400)."
        echo -e "${YELLOW}This may indicate the backup was exposed to other users.${NC}"
        echo -e "${YELLOW}Depending on your security profile, this may or may not be a problem.${NC}"
    fi

    # Check if it looks like a valid LUKS header
    local backup_size
    backup_size=$(sudo stat -c%s "$backup_file" 2>/dev/null)
    if [[ "$backup_size" -lt 1048576 ]]; then  # Less than 1MB is suspicious
        echo -e "\n${YELLOW}Warning:${NC} Backup file is unusually small (${backup_size} bytes)."
        echo -e "A valid LUKS header backup is typically 16-64 MB."
        read -p "Continue anyway? [y/N]: " continue_small
        if [[ "${continue_small,,}" != "y" ]]; then
            echo -e "${BLUE}Operation cancelled.${NC}\n"
            return 0
        fi
    fi

    # Try to detect if backup file is a valid LUKS header
    echo -e "\n${BLUE}Validating backup file...${NC}"
    if sudo cryptsetup isLuks "$backup_file" 2>/dev/null; then
        echo -e "${GREEN}✓ Backup file appears to be a valid LUKS header${NC}"
    else
        echo -e "${YELLOW}⚠️ Backup file is not recognized as a standalone LUKS container.${NC}"
        echo -e "${YELLOW}  This is normal if it's a header-only backup.${NC}"
    fi

    # Verify backup was made for the same container (optional UUID check)
    echo -e "\n${CYAN}Current container UUID:${NC}"
    sudo cryptsetup luksUUID "$container_path" 2>/dev/null || echo -e "${YELLOW}Could not read UUID${NC}"

    echo -e "\n${YELLOW}Would you like to verify the backup UUID?${NC}"
    read -p "This helps ensure you're restoring the correct header [y/N]: " check_uuid
    if [[ "${check_uuid,,}" == "y" ]]; then
        local temp_loop
        temp_loop=$(sudo losetup -f --show --read-only "$backup_file" 2>/dev/null)
        if [[ -n "$temp_loop" ]]; then
            local backup_uuid
            backup_uuid=$(sudo cryptsetup luksUUID "$temp_loop" 2>/dev/null)
            sudo losetup -d "$temp_loop" 2>/dev/null
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

    # Verify container is not currently in use
    if sudo cryptsetup status "$(basename "$container_path")" &>/dev/null; then
        echo -e "\n${RED}Error:${NC} Container appears to be in use. Please close it first.\n"
        return 1
    fi

    # Perform the restore
    echo -e "\n${BLUE}Restoring LUKS header from backup...${NC}"
    sudo cryptsetup luksHeaderRestore "$container_path" --header-backup-file "$backup_file"

    if [[ $? -eq 0 ]]; then
        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ LUKS header restored successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"

        echo -e "\n${YELLOW}Updated keyslots:${NC}"
        display_keyslots "$container_path"

        echo -e "\n${YELLOW}IMPORTANT:${NC} Test that you can open the container with the"
        echo -e "passphrases from the backup before removing old copies.\n"
    else
        echo -e "${RED}✗ Header restore failed!${NC}"
        echo -e "${YELLOW}The container header may be in an inconsistent state.${NC}"
        echo -e "${YELLOW}DO NOT use the container until this is resolved.${NC}\n"
        return 1
    fi
}

######################
# Erase LUKS header  #
######################
erase_luks_header() {
    local container_path="$1"

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Erase LUKS Header${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

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

    # Show container information
    echo -e "${YELLOW}Container information:${NC}"
    echo -e "  Path: ${CYAN}$container_path${NC}"
    local container_size
    container_size=$(sudo stat -c%s "$container_path" 2>/dev/null)
    echo -e "  Size: ${CYAN}$(numfmt --to=iec "$container_size" 2>/dev/null)${NC}\n"

    # Show keyslots
    display_keyslots "$container_path"

    local keyslot_count=$DISPLAY_KEYSLOTS_COUNT
    if [[ $keyslot_count -eq 0 ]]; then
        echo -e "\n${RED}Warning:${NC} No active keyslots detected. Container may already be damaged.\n"
    fi

    # Verify LUKS header is detectable
    echo -e "\n${CYAN}Verifying LUKS header...${NC}"
    if ! sudo cryptsetup isLuks "$container_path" 2>/dev/null; then
        echo -e "${RED}Error:${NC} This file does not appear to be a valid LUKS container.\n"
        return 1
    fi
    echo -e "${GREEN}✓ Valid LUKS header detected${NC}"

    # Check if container is in use
    echo -e "\n${CYAN}Checking if container is in use...${NC}"
    local in_use=false
    local loop_devices
    loop_devices=$(sudo losetup -l 2>/dev/null | grep "$container_path")
    if [[ -n "$loop_devices" ]]; then
        echo -e "${RED}⚠️ Container is currently attached to a loop device:${NC}"
        echo "$loop_devices"
        in_use=true
    fi

    if sudo cryptsetup status "$(basename "$container_path")" &>/dev/null; then
        echo -e "${RED}⚠️ Container appears to be open (mapped)${NC}"
        in_use=true
    fi

    if [[ "$in_use" == true ]]; then
        echo -e "\n${RED}Error:${NC} Container must be closed and detached before erasing the header."
        echo -e "Please close it manually first:\n"
        echo -e "  sudo cryptsetup luksClose <mapper-name>"
        echo -e "  sudo losetup -d <loop-device>\n"
        return 1
    fi
    echo -e "${GREEN}✓ Container is not in use${NC}\n"

    # Determine precise header size based on LUKS version
    local luks_dump
    luks_dump=$(sudo cryptsetup luksDump "$container_path" 2>/dev/null)
    local luks_version
    luks_version=$(echo "$luks_dump" | grep -i "^Version:" | awk '{print $2}')

    local header_size_mb
    local header_size_kb

    if [[ "$luks_version" == "2" ]]; then
        # LUKS2 header backup is exactly 16MB (the standard metadata area)
        header_size_mb=16
        header_size_kb=$((header_size_mb * 1024))
        echo -e "${CYAN}Header size to wipe:${NC} ${header_size_mb}MB (standard LUKS2 metadata area)"
        echo -e "${YELLOW}Note: This matches the size of a LUKS header backup file${NC}"
    else
        # LUKS1 header is exactly 2MB
        header_size_mb=2
        header_size_kb=$((header_size_mb * 1024))
        echo -e "${CYAN}Header size to wipe:${NC} 2MB (complete LUKS1 header)"
    fi

    echo -e "${YELLOW}Only header area will be overwritten, not the encrypted${NC}"
    echo -e "${YELLOW}data.${NC}"

    # Warn if container is smaller than header size
    local container_size_mb=$(( container_size / 1024 / 1024 ))
    if [[ $container_size_mb -lt $header_size_mb ]]; then
        echo -e "\n${RED}Warning:${NC} Container (${container_size_mb}MB) is smaller than planned header wipe (${header_size_mb}MB)."
        echo -e "This will overwrite the entire container."
        header_size_mb=$container_size_mb
        header_size_kb=$((header_size_mb * 1024))
    fi

    # Backup reminder
    echo -e "\n${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}🔑 LAST CHANCE TO BACKUP${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    echo -e "Would you like to create a final header backup first?"
    echo -e "This is STRONGLY recommended if you haven't already.\n"
    read -p "Create backup before erasing? [Y/n]: " create_backup
    create_backup=${create_backup:-y}

    if [[ "${create_backup,,}" == "y" ]]; then
        backup_luks_header "$container_path"
        echo
    fi

    # Multiple confirmations for safety
    echo -e "\n${RED}═══════════════════════════════════════════════════════${NC}"
    echo -e "${RED}CONFIRMATION REQUIRED${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════${NC}"

    echo -e "${CYAN}'$container_path'${NC} ${YELLOW}header${NC} will be erased.\n"
    read -p "Type 'ERASE' in uppercase to proceed: " confirm_erase

    if [[ "$confirm_erase" != "ERASE" ]]; then
        echo -e "${BLUE}Operation cancelled.${NC}\n"
        return 0
    fi

    echo -e "\n${RED}═══════════════════════════════════════════════════════${NC}"
    echo -e "${RED}FINAL WARNING${NC}"
    echo -e "${RED}═══════════════════════════════════════════════════════${NC}"
    echo -e "You are about to PERMANENTLY destroy the LUKS header."
    echo -e "All encryption keys will be lost FOREVER."
    echo -e "Data will be IRRECOVERABLE."
    echo
    read -p "Type 'I UNDERSTAND' in uppercase to proceed: " final_confirm

    if [[ "$final_confirm" != "I UNDERSTAND" ]]; then
        echo -e "${BLUE}Operation cancelled.${NC}\n"
        return 0
    fi

    # Perform the header erasure
    echo -e "\n${BLUE}Erasing LUKS header...${NC}"
    echo -e "Overwriting first ${header_size_mb}MB of the container with random data..."

    # Use dd to overwrite the header area with random data
    sudo dd if=/dev/urandom of="$container_path" bs=1M count="$header_size_mb" conv=notrunc status=progress

    if [[ $? -eq 0 ]]; then
        # Verify the header is gone
        echo -e "\n${BLUE}Verifying erasure...${NC}"

        if sudo cryptsetup isLuks "$container_path" 2>/dev/null; then
            echo -e "${YELLOW}⚠️ Warning: Container still appears to be LUKS. Trying additional wipe...${NC}"

            # Use header_size_kb instead of undefined var
            sudo dd if=/dev/zero of="$container_path" bs=1K count="$header_size_kb" conv=notrunc status=progress 2>/dev/null
            if sudo cryptsetup isLuks "$container_path" 2>/dev/null; then
                echo -e "${RED}✗ Header may not be fully erased. Manual intervention required.${NC}"
                echo -e "${YELLOW}Try: sudo dd if=/dev/urandom of=\"$container_path\" bs=1M count=${header_size_mb} conv=notrunc${NC}\n"
                return 1
            fi
        fi

        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ LUKS header erased successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "  Container: ${CYAN}$container_path${NC}"
        echo -e "  Header area wiped: ${CYAN}${header_size_mb}MB${NC}"
        echo -e "  Status: ${RED}LUKS header destroyed - data irrecoverable${NC}"
        echo -e "\n${YELLOW}The container file still exists but is no longer usable${NC}.${NC}"
        echo -e "${YELLOW}To reuse you will need to manually restore header to the${NC}"
        echo -e "${YELLOW}encrypted container since it is now unrecognizable${NC}"
        echo -e "${YELLOW}from random disk noise:${NC}\n"
        echo -e "  sudo cryptsetup luksHeaderRestore <container> \\"
        echo -e "  --header-backup-file <header.img>"
    else
        echo -e "${RED}✗ Header erasure failed!${NC}"
        echo -e "${YELLOW}Check if you have write permissions to the container.${NC}\n"
        return 1
    fi
    echo
}

###############################
# Validate numeric user input #
###############################
validate_positive_integer() {
    local value="$1"
    local field_name="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} $field_name must be a positive integer.\n"
        return 1
    fi

    if [[ "$value" -eq 0 ]]; then
        echo -e "${RED}Error:${NC} $field_name must be greater than 0.\n"
        return 1
    fi

    return 0
}

#################################
# Add keyfile to LUKS container #
#################################
add_keyfile() {
    local container_path="$1"

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Add Keyfile to LUKS Container${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "${YELLOW}Current keyslots:${NC}"
    display_keyslots "$container_path"

    echo -e "\n${YELLOW}Keyfiles provide an alternative way to unlock your container.${NC}"
    echo -e "${YELLOW}They can be used alongside or instead of passwords.${NC}\n"

    # Option to generate or use existing keyfile
    echo -e "Choose keyfile source:"
    echo -e "  ${BLUE}1)${NC} ${CYAN}Generate new random keyfile${NC}"
    echo -e "  ${BLUE}2)${NC} ${CYAN}Use existing keyfile${NC}\n"
    read -p "Enter choice [1-2]: " keyfile_choice

    local keyfile_path

    if [[ "$keyfile_choice" == "1" ]]; then
        read -p "Enter directory to save keyfile: " keyfile_dir

        # Validate keyfile directory
        if [[ ! "$keyfile_dir" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
            echo -e "${RED}Error: Invalid characters in directory path${NC}\n"
            return 1
        fi

        if [[ ! -d "$keyfile_dir" ]]; then
            sudo mkdir -p "$keyfile_dir" || { echo -e "${RED}Failed to create directory.${NC}\n"; return 1; }
            # Secure parent directory permissions with restrictive permissions
            # Optional
            #sudo chmod 700 "$keyfile_dir"
        fi

        read -p "Enter keyfile name (e.g. my_key.key): " keyfile_name

        # Validate keyfile name
        if [[ ! "$keyfile_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
            echo -e "${RED}Error: Invalid characters in keyfile name${NC}\n"
            return 1
        fi

        keyfile_path="$keyfile_dir/$keyfile_name"

        while true; do
            read -p "Keyfile size in bytes (recommended: 4096): " keyfile_size
            keyfile_size=${keyfile_size:-4096}

            # Upper bound validation (for security)
            if [[ "$keyfile_size" -gt 65536 ]]; then
                echo -e "${YELLOW}Warning: Keyfile size exceeds 64KB. Large keyfiles are unnecessary.${NC}"
                read -p "Continue with $keyfile_size bytes? [y/N]: " confirm_large
                if [[ "${confirm_large,,}" != "y" ]]; then
                    continue
                fi
            fi

            if validate_positive_integer "$keyfile_size" "Keyfile size"; then
                break
            fi
        done

        echo -e "\n${CYAN}Generating random keyfile...${NC}"

        sudo dd if=/dev/urandom of="$keyfile_path" bs=1 count="$keyfile_size" 2>/dev/null

        # Verify keyfile was written correctly
        local keyfile_size_actual
        keyfile_size_actual=$(stat -c%s "$keyfile_path" 2>/dev/null)
        if [[ "$keyfile_size_actual" -ne "$keyfile_size" ]]; then
            echo -e "${RED}Error: Keyfile size mismatch. Expected: $keyfile_size, Got: $keyfile_size_actual${NC}"
            rm -f "$keyfile_path" 2>/dev/null
            return 1
        fi

        # Strict permissions (optional)
        #sudo chmod 600 "$keyfile_path"
        #sudo chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$keyfile_path" 2>/dev/null || \
            #sudo chown root:root "$keyfile_path" 2>/dev/null || true

        echo -e "${GREEN}✓ Keyfile generated: $keyfile_path${NC}"
        echo -e "  Size: ${keyfile_size_actual} bytes"
        echo -e "  Permissions: $(stat -c%a "$keyfile_path")"
    else
        read -p "Enter path to existing keyfile: " keyfile_path
        if [[ ! -f "$keyfile_path" ]]; then
            echo -e "${RED}Error: Keyfile not found.${NC}\n"
            return 1
        fi

        # Validate keyfile permissions
        local keyfile_perms
        keyfile_perms=$(stat -c%a "$keyfile_path" 2>/dev/null)
        if [[ -n "$keyfile_perms" ]] && [[ "$keyfile_perms" != "600" ]] && [[ "$keyfile_perms" != "400" ]]; then
            echo -e "${YELLOW}Caution: Keyfile permissions are $keyfile_perms. Recommend setting to 600 if you want stricter security.${NC}"
        fi
    fi

    echo -e "\n${CYAN}Adding keyfile to LUKS container...${NC}"
    echo -e "${YELLOW}You will need to enter an existing passphrase to authorize this.${NC}"
    sudo cryptsetup luksAddKey "$container_path" "$keyfile_path"

    if [[ $? -eq 0 ]]; then
        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ Keyfile added successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "  Container: ${CYAN}$container_path${NC}"
        echo -e "  Keyfile: ${CYAN}$keyfile_path${NC}"
        echo -e "\n${YELLOW}Updated keyslots:${NC}"
        display_keyslots "$container_path"

        echo -e "\n${YELLOW}To open with keyfile:${NC}"
        echo -e "  sudo cryptsetup luksOpen <loop-device> <alias> \\"
        echo -e "  --key-file $keyfile_path"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    else
        echo -e "${RED}✗ Failed to add keyfile!${NC}\n"
        return 1
    fi
    echo
}

########################
# Change LUKS password #
########################
change_password() {
    container_path="$1"

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Change LUKS Container Password${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "${YELLOW}Current keyslots:${NC}"
    display_keyslots "$container_path"

    echo -e "\n${YELLOW}Options:${NC}"
    echo -e "  ${BLUE}1)${NC} ${CYAN}Add new password to a new keyslot${NC}"
    echo -e "  ${BLUE}2)${NC} ${CYAN}Change existing password (requires current password)${NC}"
    echo -e "  ${BLUE}3)${NC} ${CYAN}Back to main menu${NC}"
    echo
    read -p "Enter choice [1-3]: " pwd_choice

    case "$pwd_choice" in
        1)
            echo -e "\n${BLUE}Adding new password to a new keyslot...${NC}\n"
            echo -e "${YELLOW}Enter current passphrase when prompted, then new passphrase.${NC}"
            sudo cryptsetup luksAddKey "$container_path"

            if [[ $? -eq 0 ]]; then
                echo -e "\n${GREEN}✓ New password added successfully!${NC}"
                echo -e "\n${YELLOW}Updated keyslots:${NC}"
                display_keyslots "$container_path"
                echo -e "\n${YELLOW}Tip: You can now optionally remove the old keyslot with option 9 (Remove Keyslot).${NC}"
            else
                echo -e "${RED}✗ Failed to add new password!${NC}"
                return 1
            fi
            ;;
        2)
            echo -e "\n${CYAN}Changing password for existing keyslot...${NC}"
            echo -e "${YELLOW}Enter the passphrase you want to change, then the new one.${NC}"
            sudo cryptsetup luksChangeKey "$container_path"

            if [[ $? -eq 0 ]]; then
                echo -e "\n${GREEN}✓ Password changed successfully!${NC}"
                echo -e "\n${YELLOW}Updated keyslots:${NC}"
                display_keyslots "$container_path"
            else
                echo -e "${RED}✗ Failed to change password!${NC}"
                return 1
            fi
            ;;
        3)
            echo -e "${BLUE}Returning to main menu...${NC}"
            return 0
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            return 1
            ;;
    esac
    echo
}

#########################
# Remove target keyslot #
#########################
remove_keyslot() {
    container_path="$1"

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Remove Keyslot from LUKS Container${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "${YELLOW}Current keyslots:${NC}"
    display_keyslots "$container_path"
    enabled_count=$DISPLAY_KEYSLOTS_COUNT

    # Get LUKS dump for validation
    luks_dump=$(sudo cryptsetup luksDump "$container_path" 2>/dev/null)
    luks_version=$(echo "$luks_dump" | grep -i "^Version:" | awk '{print $2}')

    if [[ $enabled_count -le 1 ]]; then
        echo -e "\n${RED}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║ ⚠️ CRITICAL: Only ${enabled_count} active keyslot remaining!         ║${NC}"
        echo -e "${RED}║ Removing the last keyslot will permanently destroy   ║${NC}"
        echo -e "${RED}║ all access to your encrypted data!                   ║${NC}"
        echo -e "${RED}║                                                      ║${NC}"
        echo -e "${RED}║ This operation will be BLOCKED for your protection.  ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
        echo -e "\n${YELLOW}To proceed, first add another keyslot (Option 6)${NC}"
        echo -e "${YELLOW}or add a keyfile (Option 5), then try again.${NC}\n"
        return 1
    fi

    echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}⚠️ WARNING:${NC} Removing a keyslot will permanently delete"
    echo -e "that key. Make sure you have another way to unlock the"
    echo -e "container."
    echo -e "${RED}\nNever remove the last remaining key slot.${NC} Doing so makes"
    echo -e "the encrypted data permanently inaccessible!"
    echo
    echo -e "${YELLOW}To auto-detect which slot a passphrase unlocks:${NC}"
    echo -e "  sudo cryptsetup open --test-passphrase --verbose \\"
    echo -e "  \"$container_path\""
    echo -e "\nOutput will indicate: 'Key slot X unlocked'"
    echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}\n"

    # Get list of enabled slot numbers for validation
    enabled_slot_numbers=()
    if [[ "$luks_version" == "2" ]]; then
        # Use JSON parsing for LUKS2 if available
        local json_dump
        json_dump=$(sudo cryptsetup luksDump --dump-json-metadata "$container_path" 2>/dev/null)
        if [[ -n "$json_dump" ]] && command -v jq &>/dev/null; then
            while IFS= read -r slot; do
                local priority
                priority=$(echo "$json_dump" | jq -r ".keyslots[\"$slot\"].priority // \"normal\"" 2>/dev/null)
                if [[ "$priority" == "normal" ]] || [[ "$priority" == "prefer" ]]; then
                    enabled_slot_numbers+=("$slot")
                fi
            done < <(echo "$json_dump" | jq -r '.keyslots | keys[]' 2>/dev/null)
        else
            # Fallback to text parsing
            in_keyslots=0
            current_slot=""
            while IFS= read -r line; do
                if [[ "$line" =~ ^Keyslots:$ ]]; then
                    in_keyslots=1
                    continue
                fi
                if [[ $in_keyslots -eq 1 ]] && [[ "$line" =~ ^(Tokens:|Digests:) ]]; then
                    in_keyslots=0
                    continue
                fi
                if [[ $in_keyslots -eq 1 ]]; then
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
        # Parse LUKS1 format
        while IFS= read -r line; do
            if [[ "$line" =~ ^Key[[:space:]]Slot[[:space:]]([0-9]+):[[:space:]]*ENABLED ]]; then
                enabled_slot_numbers+=("${BASH_REMATCH[1]}")
            fi
        done <<< "$luks_dump"
    fi

    echo -e "${CYAN}🔑 Enabled keyslots:${NC} ${enabled_slot_numbers[*]}\n"

    while true; do
        read -p "Enter keyslot number to remove (or 'q' to quit): " slot_number

        if [[ "$slot_number" == "q" ]]; then
            echo -e "${BLUE}Operation cancelled.${NC}"
            return 0
        fi

        # Validate input
        if [[ ! "$slot_number" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Error:${NC} Please enter a valid number.\n"
            continue
        fi

        # Check if it's in the enabled list
        is_enabled=false
        for enabled_slot in "${enabled_slot_numbers[@]}"; do
            if [[ "$enabled_slot" == "$slot_number" ]]; then
                is_enabled=true
                break
            fi
        done

        if [[ "$is_enabled" == false ]]; then
            echo -e "${YELLOW}Warning:${NC} Keyslot $slot_number doesn't appear to be enabled."
            read -p "Continue anyway? [y/N]: " continue_anyway
            if [[ "${continue_anyway,,}" != "y" ]]; then
                echo -e "${BLUE}Operation cancelled.${NC}\n"
                return 0
            fi
        fi

        # Final confirmation
        echo -e "\nAre you sure you want to remove keyslot $slot_number?"
        read -p "Type 'YES' in uppercase to confirm: " confirm
        if [[ "$confirm" != "YES" ]]; then
            echo -e "${BLUE}Operation cancelled.${NC}"
            return 0
        fi

        break
    done

    echo -e "\n${CYAN}Removing keyslot $slot_number...${NC}"
    echo -e "${YELLOW}You will need to enter a remaining valid passphrase/keyfile.${NC}"
    sudo cryptsetup luksKillSlot "$container_path" "$slot_number"

    if [[ $? -eq 0 ]]; then
        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ Keyslot $slot_number removed successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"

        # Show remaining keyslots
        echo -e "\n${YELLOW}Remaining keyslots:${NC}"
        display_keyslots "$container_path"
    else
        echo -e "${RED}✗ Failed to remove keyslot!${NC}"
        echo -e "${YELLOW}Make sure you're using a valid passphrase and the slot exists.${NC}\n"
        return 1
    fi
    echo
}

##############################
# Show container information #
##############################
show_container_info() {
    container_path="$1"

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Container Information${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "  Container: ${CYAN}$container_path${NC}"

    # Get file size
    file_size=$(sudo stat -c%s "$container_path" 2>/dev/null)
    if [[ -n "$file_size" ]]; then
        echo -e "  File size: ${CYAN}$(numfmt --to=iec "$file_size")${NC} ($file_size bytes)"
    fi

    # Get LUKS header info
    luks_dump=$(sudo cryptsetup luksDump "$container_path" 2>/dev/null)

    if [[ -z "$luks_dump" ]]; then
        echo -e "\n${RED}Error: Could not read LUKS header${NC}\n"
        return 1
    fi

    # Extract LUKS information
    luks_version=$(echo "$luks_dump" | grep -E "^[[:space:]]*Version:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    luks_type=$(echo "$luks_dump" | grep -E "^[[:space:]]*Type:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    cipher=$(echo "$luks_dump" | grep -E "^[[:space:]]*cipher:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    hash=$(echo "$luks_dump" | grep -E "^[[:space:]]*Hash:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    uuid=$(echo "$luks_dump" | grep -E "^[[:space:]]*UUID:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    label=$(echo "$luks_dump" | grep -E "^[[:space:]]*Label:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')

    # If LUKS2 fields not found, try LUKS1 format
    if [[ -z "$cipher" ]]; then
        cipher=$(echo "$luks_dump" | grep -E "^[[:space:]]*Cipher:" | head -1 | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
    fi

    # Determine LUKS type from version if not explicitly set
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

    # Display keyslot information - WITH PRIORITY
    echo -e "\n${YELLOW}  Keyslots:${NC}"

    found_slot=0

    # Use JSON metadata for LUKS2 when available
    local json_dump
    json_dump=$(sudo cryptsetup luksDump --dump-json-metadata "$container_path" 2>/dev/null)

    if [[ -n "$json_dump" ]] && command -v jq &>/dev/null; then
        # Use jq for robust JSON parsing
        local slots
        slots=$(echo "$json_dump" | jq -r '.keyslots | keys[]' 2>/dev/null)
        if [[ -n "$slots" ]]; then
            for slot in $slots; do
                local priority
                priority=$(echo "$json_dump" | jq -r ".keyslots[\"$slot\"].priority // \"normal\"" 2>/dev/null)
                if [[ "$priority" == "ignore" ]]; then
                    echo -e "    Slot ${slot}: ${RED}DISABLED${NC} (Priority: $priority)"
                else
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC} (Priority: $priority)"
                fi
                found_slot=1
            done
        fi
    elif echo "$luks_dump" | grep -q "^Keyslots:"; then
        # Fallback to text parsing for LUKS2
        in_keyslot=0
        current_slot=""
        has_key=0
        slot_priority=""
        slot_processed=0

        # Temporary storage for slot information
        declare -A slot_data
        declare -A slot_priority_data

        while IFS= read -r line; do
            # Check if we're entering the Keyslots section
            if [[ "$line" =~ ^Keyslots: ]]; then
                in_keyslot=1
                continue
            fi

            # Check if we're leaving the Keyslots section (next main section that doesn't start with whitespace)
            if [[ $in_keyslot -eq 1 ]] && [[ "$line" =~ ^[A-Za-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
                # Process the last slot before leaving
                if [[ -n "$current_slot" ]]; then
                    slot_data[$current_slot]=$has_key
                    slot_priority_data[$current_slot]=$slot_priority
                fi
                in_keyslot=0
                current_slot=""
                has_key=0
                slot_priority=""
                continue
            fi

            # Process keyslot entries
            if [[ $in_keyslot -eq 1 ]]; then
                # Match slot definition (e.g., "    0: luks2")
                if [[ "$line" =~ ^[[:space:]]+([0-9]+):[[:space:]]+luks2 ]]; then
                    # Store previous slot data
                    if [[ -n "$current_slot" ]]; then
                        slot_data[$current_slot]=$has_key
                        slot_priority_data[$current_slot]=$slot_priority
                    fi

                    # Start new slot
                    current_slot="${BASH_REMATCH[1]}"
                    has_key=0
                    slot_priority=""
                elif [[ -n "$current_slot" ]] && [[ "$line" =~ "Key:" ]]; then
                    # Check if it has actual key material (contains "bits")
                    if [[ "$line" =~ [0-9]+[[:space:]]+bits ]]; then
                        has_key=1
                    fi
                elif [[ -n "$current_slot" ]] && [[ "$line" =~ "Priority:" ]]; then
                    # Extract priority information
                    slot_priority=$(echo "$line" | awk -F':' '{print $2}' | sed 's/^[[:space:]]*//')
                fi
            fi
        done <<< "$luks_dump"

        # Store the very last slot if we ended while still in keyslots section
        if [[ $in_keyslot -eq 1 ]] && [[ -n "$current_slot" ]]; then
            slot_data[$current_slot]=$has_key
            slot_priority_data[$current_slot]=$slot_priority
        fi

        # Display all collected slots in order
        for slot in $(echo "${!slot_data[@]}" | tr ' ' '\n' | sort -n); do
            if [[ ${slot_data[$slot]} -eq 1 ]]; then
                if [[ -n "${slot_priority_data[$slot]}" ]]; then
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC} (Priority: ${slot_priority_data[$slot]})"
                else
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC}"
                fi
            else
                echo -e "    Slot ${slot}: ${RED}DISABLED${NC}"
            fi
            found_slot=1
        done
    fi

    # If no LUKS2 slots found, try LUKS1 format
    if [[ $found_slot -eq 0 ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^Key[[:space:]]+Slot[[:space:]]+([0-9]+):[[:space:]]+(.*) ]]; then
                slot="${BASH_REMATCH[1]}"
                status="${BASH_REMATCH[2]}"

                if [[ "$status" == "DISABLED" ]] || [[ "$status" == *"DISABLED"* ]]; then
                    echo -e "    Slot ${slot}: ${RED}DISABLED${NC}"
                elif [[ "$status" == "ENABLED" ]] || [[ "$status" == *"ENABLED"* ]]; then
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC}"
                else
                    echo -e "    Slot ${slot}: ${GREEN}ENABLED${NC}"
                fi
                found_slot=1
            fi
        done <<< "$luks_dump"
    fi

    if [[ $found_slot -eq 0 ]]; then
        echo -e "    ${YELLOW}No keyslot information found${NC}"
    fi

    # Show full dump on request
    echo
    echo -e "${YELLOW}Show full LUKS header dump?${NC}"
    read -p "[y/N]: " show_full
    if [[ "${show_full,,}" == "y" ]]; then
        echo -e "\n${CYAN}╔════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║       Full LUKS Header Dump                ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}\n"
        echo "$luks_dump" | sed 's/^/  /'
        echo
    fi

    echo -e "\n${BLUE}===============================================${NC}\n"
}


#######################################
# Obtaining username & home directory #
#######################################
USERNAME=${SUDO_USER:-$USER}
HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)

##################
# Welcome banner #
##################
echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}\n"
echo -e "${YELLOW}    Create & mount LUKS containers script $VRS${NC}"
echo -e "\nEncrypted block devices (partitions) are not supported,"
echo -e "only LUKS file containers / images with .bin extension."
echo -e "\n • Multiple LUKS file containers mountable."
echo -e " • Expand or shrink existing images."
echo -e " • Keyslot management."
echo -e " • Header backup & restore."
echo -e " • Keyfile support."
echo -e " • Display detailed container info."
echo -e " • Safe header erasure.\n"

# Check privileges before proceeding
check_privileges

echo -e "\n${BLUE}Checking if required packages are installed...${NC}"
if ! command -v cryptsetup &>/dev/null || ! command -v bc &>/dev/null; then
    sudo apt install cryptsetup bc e2fsprogs -y 2>/dev/null
fi
echo -e "${GREEN}✓ Installed. Ready to proceed.${NC}\n"

########################
# Action select prompt #
########################
while true; do
    echo -e "\n═════════════════════════════════════════════════════════"
    echo -e "${YELLOW}Choose from the following options${NC}"
    echo -e "═════════════════════════════════════════════════════════\n"
    echo -e "  ${BLUE}1)${NC} ${CYAN}Create new LUKS container${NC}"
    echo -e "  ${BLUE}2)${NC} ${CYAN}Expand existing LUKS container${NC} (Grow)"
    echo -e "  ${BLUE}3)${NC} ${CYAN}Truncate existing LUKS container${NC} (Shrink)"
    echo -e "  ${BLUE}4)${NC} ${CYAN}Backup LUKS header${NC}"
    echo -e "  ${BLUE}5)${NC} ${CYAN}Restore LUKS header${NC}"
    echo -e "  ${BLUE}6)${NC} ${CYAN}Erase LUKS header${NC}"
    echo -e "  ${BLUE}7)${NC} ${CYAN}Add keyfile to container${NC}"
    echo -e "  ${BLUE}8)${NC} ${CYAN}Add/Change container password${NC}"
    echo -e "  ${BLUE}9)${NC} ${CYAN}Remove keyslot${NC}"
    echo -e "  ${BLUE}10)${NC} ${CYAN}Show container information${NC}"
    echo -e "  ${BLUE}11)${NC} ${BLUE}Exit${NC}\n"

    read -p "Enter choice [1-11]: " TASK_NUM

    # Handle menu options that need container selection (4-10)
    if [[ "$TASK_NUM" =~ ^[4-9]$|^10$ ]]; then
        find_con

        case "$TASK_NUM" in
            4)
                backup_luks_header "$CONT_TARGET1"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            5)
                restore_luks_header "$CONT_TARGET1"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            6)
                erase_luks_header "$CONT_TARGET1"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            7)
                add_keyfile "$CONT_TARGET1"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            8)
                change_password "$CONT_TARGET1"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            9)
                remove_keyslot "$CONT_TARGET1"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            10)
                show_container_info "$CONT_TARGET1"
                echo -e "${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
        esac
    fi

    if [[ "$TASK_NUM" == "11" ]]; then
        echo -e "\n${BLUE}Script will exit.${NC}\n"
        exit 0
    elif [[ "$TASK_NUM" == "1" ]]; then
        break
    elif [[ "$TASK_NUM" == "2" ]] || [[ "$TASK_NUM" == "3" ]]; then
        # Find and verify container integrity before proceeding
        find_con

        echo -e "\n${BLUE}Opening LUKS container for analysis...${NC}"
        verify_and_mount_container "$CONT_TARGET1"

        CALC_CONT_SIZE_BYTES=$(sudo wc -c < "$CONT_TARGET1")
        CALC_CONT_SIZE_MB=$((CALC_CONT_SIZE_BYTES / 1024 / 1024))
        echo -e "  Current LUKS container size: ${CYAN}${CALC_CONT_SIZE_MB} MB${NC}\n"

        if [[ "$TASK_NUM" == "2" ]]; then
            while true; do
                # STEP 0: Set target container size
                echo -e "${BLUE}===============================================${NC}"
                echo -e "${BLUE}Set LUKS container target  size...${NC}"
                echo -e "${BLUE}===============================================${NC}"

                read -p "Specify the new expanded LUKS container size (in MB):  " TOTAL_CONT_SIZE

                # Upper bound validation to prevent resource exhaustion
                if [[ ! "$TOTAL_CONT_SIZE" =~ ^[0-9]+$ ]]; then
                    echo -e "\n${RED}Error:${NC} Invalid size. Numerical values only.\n"
                elif [[ "$TOTAL_CONT_SIZE" -gt 1048576 ]]; then
                    echo -e "\n${RED}Error:${NC} Maximum container size is 1TB (1048576 MB).\n"
                elif [[ "$TOTAL_CONT_SIZE" -le "$CALC_CONT_SIZE_MB" ]]; then
                    echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
                    echo -e "${YELLOW}⚠️  Warning:${NC} Specified size is the same or less than"
                    echo -e "existing LUKS container. Select a larger size to continue."
                    echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}\n"
                else
                    break
                fi
            done

            CONTAINER_DIR=$(dirname "$CONT_TARGET1")
            if ! check_disk_space "$CONTAINER_DIR" "$TOTAL_CONT_SIZE"; then
                echo -e "\n${RED}Cannot proceed due to insufficient disk space.${NC}\n"
                exit 1
            fi

            CALC2=$(awk "BEGIN {printf \"%.2f\", $TOTAL_CONT_SIZE / 1024}")
            echo -e "New LUKS container size will be ${CYAN}$TOTAL_CONT_SIZE MB${NC} (approx ${CALC2} GB)."
            read -p "Is this correct? [y/n] " RESP1

            if [[ "${RESP1,,}" == "y" ]]; then
                echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}CAUTION:${NC} Risk of data corruption if LUKS container is"
                echo -e "interrupted or fails while resizing. Please make a backup"
                echo -e "of LUKS container before proceeding!"
                echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}"
                sleep 1

                # STEP 1: Expand container
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Expanding container file...${NC}"
                echo -e "${BLUE}===============================================${NC}"

                NEW_CONT_SIZE=$((TOTAL_CONT_SIZE - CALC_CONT_SIZE_MB))
                FILE_SIZE_BEFORE=$(sudo stat -c%s "$CONT_TARGET1" 2>/dev/null)
                FILE_SIZE_BEFORE_MB=$((FILE_SIZE_BEFORE / 1024 / 1024))

                echo -e "Current file size: ${CYAN}${FILE_SIZE_BEFORE_MB} MB${NC}"
                echo -e "Need to add: ${GRAY}${NEW_CONT_SIZE} MB${NC}"
                echo -e "Expected final size: ${CYAN}${TOTAL_CONT_SIZE} MB${NC}"

                # Try fallocate first
                echo -e "\n${YELLOW}Attempting fallocate...${NC}"
                sudo fallocate -l "+${NEW_CONT_SIZE}M" "$CONT_TARGET1" 2>&1
                fallocate_result=$?

                # Check if file actually grew
                FILE_SIZE_AFTER=$(sudo stat -c%s "$CONT_TARGET1" 2>/dev/null)
                FILE_SIZE_AFTER_MB=$((FILE_SIZE_AFTER / 1024 / 1024))

                if [[ $fallocate_result -ne 0 ]] || [[ $FILE_SIZE_AFTER_MB -le $CALC_CONT_SIZE_MB ]]; then
                    if [[ $fallocate_result -ne 0 ]]; then
                        echo -e "${YELLOW}fallocate failed (exit code: $fallocate_result)${NC}"
                    else
                        echo -e "${YELLOW}(fallocate appeared to succeed but file didn't grow)${NC}"
                    fi

                    echo -e "${YELLOW}Falling back to dd method...${NC}"

                    # Use dd seek to extend file
                    sudo dd if=/dev/zero of="$CONT_TARGET1" bs=1M count=0 seek="$TOTAL_CONT_SIZE" 2>/dev/null

                    # Alternative: Use truncate
                    FILE_SIZE_AFTER=$(sudo stat -c%s "$CONT_TARGET1" 2>/dev/null)
                    FILE_SIZE_AFTER_MB=$((FILE_SIZE_AFTER / 1024 / 1024))

                    if [[ $FILE_SIZE_AFTER_MB -le $CALC_CONT_SIZE_MB ]]; then
                        echo -e "${YELLOW}dd seek failed, using truncate to set exact size...${NC}"
                        sudo truncate -s "${TOTAL_CONT_SIZE}M" "$CONT_TARGET1"
                        FILE_SIZE_FINAL=$(sudo stat -c%s "$CONT_TARGET1" 2>/dev/null)
                        FILE_SIZE_FINAL_MB=$((FILE_SIZE_FINAL / 1024 / 1024))
                    else
                        FILE_SIZE_FINAL_MB=$FILE_SIZE_AFTER_MB
                    fi
                else
                    echo -e "${GREEN}✓ fallocate succeeded${NC}\n"
                    FILE_SIZE_FINAL_MB=$FILE_SIZE_AFTER_MB
                fi

                # Final verification
                if [[ $FILE_SIZE_FINAL_MB -le $CALC_CONT_SIZE_MB ]]; then
                    echo -e "\n${RED}╔══════════════════════════════════════════════════════╗${NC}"
                    echo -e "${RED}║ ERROR: File expansion FAILED!                       ║${NC}"
                    echo -e "${RED}║ File size: ${FILE_SIZE_FINAL_MB} MB (expected: ${TOTAL_CONT_SIZE} MB)        ║${NC}"
                    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
                    echo -e "\n${YELLOW}Manual workaround:${NC}"
                    echo -e "  sudo truncate -s ${TOTAL_CONT_SIZE}M \"$CONT_TARGET1\""
                    echo -e "  Then run the script again.\n"
                    exit 1
                fi

                echo -e "\n${GREEN}✓ Container file expanded: ${CALC_CONT_SIZE_MB} MB → ${FILE_SIZE_FINAL_MB} MB${NC}"

                # Get fresh loop device with atomic loop
                loop_dev=$(sudo losetup -f --show --direct-io=on "$CONT_TARGET1" 2>/dev/null)
                if [[ $? -ne 0 ]] || [[ -z "$loop_dev" ]]; then
                    echo -e "\n${RED}Error:${NC} Failed to get loop device\n"
                    exit 1
                fi

                # Verify loop device attachment
                attached_verify=$(sudo losetup -l "$loop_dev" 2>/dev/null | awk 'NR==2 {print $6}')
                if [[ "$attached_verify" != "$CONT_TARGET1" ]]; then
                    echo -e "\n${RED}Error: Loop device verification failed!${NC}\n"
                    sudo losetup -d "$loop_dev" 2>/dev/null || true
                    loop_dev=""
                    exit 1
                fi

                LOOP_SIZE=$(sudo blockdev --getsize64 "$loop_dev" 2>/dev/null)
                LOOP_SIZE_MB=$((LOOP_SIZE / 1024 / 1024))

                if [[ $LOOP_SIZE_MB -ne $FILE_SIZE_FINAL_MB ]]; then
                    echo -e "${YELLOW}Loop device size (${LOOP_SIZE_MB}MB) doesn't match file size (${FILE_SIZE_FINAL_MB}MB)${NC}"
                    echo -e "${YELLOW}Refreshing loop device...${NC}"
                    sudo losetup -c "$loop_dev" 2>/dev/null || true
                    sleep 1

                    LOOP_SIZE=$(sudo blockdev --getsize64 "$loop_dev" 2>/dev/null)
                    LOOP_SIZE_MB=$((LOOP_SIZE / 1024 / 1024))
                    echo -e "Loop device size after refresh: ${CYAN}${LOOP_SIZE_MB} MB${NC}"

                    if [[ $LOOP_SIZE_MB -ne $FILE_SIZE_FINAL_MB ]]; then
                        echo -e "${YELLOW}Re-attaching loop device...${NC}"
                        sudo losetup -d "$loop_dev" 2>/dev/null
                        sleep 1
                        loop_dev=$(sudo losetup -f --show --direct-io=on "$CONT_TARGET1" 2>/dev/null)
                        LOOP_SIZE=$(sudo blockdev --getsize64 "$loop_dev" 2>/dev/null)
                        LOOP_SIZE_MB=$((LOOP_SIZE / 1024 / 1024))
                        echo -e "Loop device size after re-attach: ${CYAN}${LOOP_SIZE_MB} MB${NC}"
                    fi
                fi

                # STEP 3: Open LUKS
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Opening LUKS container...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                sudo cryptsetup luksOpen "$loop_dev" "$TMP_MAPPER_NAME"
                if [[ $? -ne 0 ]]; then
                    echo -e "\n${RED}Error:${NC} Failed to open LUKS container!\n"
                    error_detach
                    exit 1
                fi
                echo -e "${GREEN}✓ Container opened${NC}"

                # Read LUKS device size BEFORE resize
                LUKS_SIZE_BEFORE=$(sudo blockdev --getsize64 "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null)
                LUKS_SIZE_MB_BEFORE=$((LUKS_SIZE_BEFORE / 1024 / 1024))

                # STEP 4: Filesystem check
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Filesystem check...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                sudo e2fsck -fy "/dev/mapper/${TMP_MAPPER_NAME}"
                e2fsck_result=$?
                if [[ $e2fsck_result -gt 2 ]]; then
                    echo -e "\n${RED}Error: Filesystem check failed!${NC}\n"
                    error_detach
                    exit 1
                fi
                echo -e "${GREEN}✓ Filesystem check passed.${NC}"

                # STEP 5: Resize LUKS
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Resizing LUKS device...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                echo -e "Current LUKS size: ${CYAN}${LUKS_SIZE_MB_BEFORE} MB${NC}"
                echo -e "Loop device size: ${CYAN}${LOOP_SIZE_MB} MB${NC}"
                echo -e "Expected LUKS after resize: ${YELLOW} $((LOOP_SIZE_MB - 18)) MB${NC} (minus header)\n"

                sudo cryptsetup resize "/dev/mapper/${TMP_MAPPER_NAME}"
                if [[ $? -ne 0 ]]; then
                    echo -e "\n${RED}✗ LUKS resize failed!${NC}\n"
                    error_detach
                    exit 1
                fi

                # Read LUKS device size AFTER resize
                LUKS_SIZE_AFTER=$(sudo blockdev --getsize64 "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null)
                LUKS_SIZE_MB_AFTER=$((LUKS_SIZE_AFTER / 1024 / 1024))

                # Only report error if LUKS didn't grow AND it should have
                # Calculate expected LUKS size (loop size minus ~18MB header)
                EXPECTED_LUKS_MB=$((LOOP_SIZE_MB - 18))

                if [[ $LUKS_SIZE_MB_AFTER -gt $LUKS_SIZE_MB_BEFORE ]]; then
                    echo -e "${GREEN}✓ LUKS device grew: ${LUKS_SIZE_MB_BEFORE} MB → ${LUKS_SIZE_MB_AFTER} MB${NC}\n"
                elif [[ $LUKS_SIZE_MB_AFTER -eq $LUKS_SIZE_MB_BEFORE ]] && [[ $LUKS_SIZE_MB_AFTER -ge $EXPECTED_LUKS_MB ]]; then
                    # LUKS didn't grow because it was already at max size - this is OK
                    echo -e "${GREEN}✓ LUKS device latest size: ${LUKS_SIZE_MB_AFTER} MB${NC}"
                    echo -e "${YELLOW}  (Loop device: ${LOOP_SIZE_MB} MB, LUKS overhead: $((LOOP_SIZE_MB - LUKS_SIZE_MB_AFTER)) MB)${NC}"
                else
                    echo -e "${RED}Error: LUKS device did not grow as expected!${NC}"
                    echo -e "${YELLOW}  Before: ${LUKS_SIZE_MB_BEFORE} MB${NC}"
                    echo -e "${YELLOW}  After:  ${LUKS_SIZE_MB_AFTER} MB${NC}"
                    echo -e "${YELLOW}  Expected: ~${EXPECTED_LUKS_MB} MB${NC}"
                    echo -e "${YELLOW}  Loop device: ${LOOP_SIZE_MB} MB${NC}\n"
                    error_detach
                    exit 1
                fi

                # STEP 6: Expand filesystem
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Expanding filesystem...${NC}"
                echo -e "${BLUE}===============================================${NC}"

                FS_SIZE_BEFORE=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                FS_BLOCK=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block size" | awk '{print $3}')
                FS_SIZE_MB_BEFORE=$((FS_SIZE_BEFORE * FS_BLOCK / 1024 / 1024))

                sudo resize2fs -p "/dev/mapper/${TMP_MAPPER_NAME}"
                resize_result=$?

                FS_SIZE_AFTER=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                FS_SIZE_MB_AFTER=$((FS_SIZE_AFTER * FS_BLOCK / 1024 / 1024))

                if [[ $resize_result -eq 0 ]] && [[ $FS_SIZE_MB_AFTER -gt $FS_SIZE_MB_BEFORE ]]; then
                    echo -e "${GREEN}✓ Filesystem expanded: ${FS_SIZE_MB_BEFORE} MB → ${FS_SIZE_MB_AFTER} MB${NC}"
                else
                    echo -e "${YELLOW}Trying forced resize...${NC}"
                    sudo resize2fs -f "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null
                    FS_SIZE_AFTER=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                    FS_SIZE_MB_AFTER=$((FS_SIZE_AFTER * FS_BLOCK / 1024 / 1024))
                    if [[ $FS_SIZE_MB_AFTER -gt $FS_SIZE_MB_BEFORE ]]; then
                        echo -e "${GREEN}✓ Forced filesystem expansion: ${FS_SIZE_MB_BEFORE} MB → ${FS_SIZE_MB_AFTER} MB${NC}\n"
                    else
                        echo -e "${RED}✗ Filesystem expansion failed!${NC}\n"
                        error_detach
                        exit 1
                    fi
                fi

                # Final cleanup
                echo -e "\nClosing container..."
                error_detach

                sleep 2

                echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
                echo -e "${GREEN}✓ Container expansion complete!${NC}"
                echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
                echo -e "Container file size: ${GREEN}${FILE_SIZE_FINAL_MB} MB${NC}"
                echo -e "Filesystem size: ${GREEN}${FS_SIZE_MB_AFTER} MB${NC}"

            else
                echo -e "${BLUE}LUKS container resizing cancelled.${NC}\n"
                error_detach
                exit 1
            fi

        elif [[ "$TASK_NUM" == "3" ]]; then
            # Shrink logic
            # Step 0: Calculate safe minimum using resize2fs -P
            calculate_min_safe_size "$FS_SIZE_MB" "$TOTAL_REAL_SIZE"

            # Abort if cannot shrink
            if [[ "$CALC_SAFETY_LEVEL" == "CANNOT_SHRINK" ]]; then
                error_detach
                exit 1
            fi

            while true; do
                echo -e "\n${YELLOW}${UNDERLINE}Note:${NC} This operation requires shrinking the LUKS"
                echo -e "container filesystem first and then fitting the"
                echo -e "container around the new smaller size.\n"
                read -p "Specify the new filesystem size (in MB):  " TARGET_FS_SIZE_MB

                # Upper bound validation for shrink
                if [[ ! "$TARGET_FS_SIZE_MB" =~ ^[0-9]+$ ]]; then
                    echo -e "\n${RED}Error:${NC} Invalid size. Numerical values only."
                elif [[ "$TARGET_FS_SIZE_MB" -gt 1048576 ]]; then
                    echo -e "\n${RED}Error:${NC} Maximum container size is 1TB (1048576 MB)."
                elif [[ "$TARGET_FS_SIZE_MB" -lt "$CALC_RESIZE2FS_MIN_MB" ]]; then
                    echo -e "\n${RED}═════════════════════════════════════════════════════════${NC}"
                    echo -e "${RED}⛔ BLOCKED:${NC} Target size (${TARGET_FS_SIZE_MB} MB) is below resize2fs"
                    echo -e "absolute minimum of ${CALC_RESIZE2FS_MIN_MB} MB."
                    echo -e "${RED}═════════════════════════════════════════════════════════${NC}"
                elif [[ "$TARGET_FS_SIZE_MB" -lt "$CALC_MIN_SIZE" ]]; then
                    echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
                    echo -e "${YELLOW}⚠️  Warning:${NC} Target size (${TARGET_FS_SIZE_MB} MB) is below safe"
                    echo -e "minimum of ${CALC_MIN_SIZE} MB."
                    echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}"
                    read -p "Proceed anyway? [y/N]: " proceed_unsafe
                    if [[ "${proceed_unsafe,,}" == "y" ]]; then
                        break
                    fi
                elif [[ "$TARGET_FS_SIZE_MB" -ge "$CALC_CONT_SIZE_MB" ]]; then
                    echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
                    echo -e "${YELLOW}⚠️  Warning:${NC} Specified size is the same or greater than"
                    echo -e "existing LUKS container. Select a smaller size to continue."
                    echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}"
                else
                    break
                fi
            done

            CALC2=$(awk "BEGIN {printf \"%.2f\", $TARGET_FS_SIZE_MB / 1024}")

            echo -e "New LUKS filesystem will be ${CYAN}$TARGET_FS_SIZE_MB MB${NC} (approx ${CALC2} GB)."
            read -p "Is this correct? [y/n] " RESP2

            if [[ "${RESP2,,}" == "y" ]]; then
                # STEP 1: Open container (already open from verify, but ensure)
                if ! findmnt "/dev/mapper/${TMP_MAPPER_NAME}" &>/dev/null; then
                    # Atomic loop device attachment
                    loop_dev=$(sudo losetup -f --show --direct-io=on "$CONT_TARGET1" 2>/dev/null)
                    if [[ $? -ne 0 ]] || [[ -z "$loop_dev" ]]; then
                        echo -e "\n${RED}Error:${NC} Failed to get loop device\n"
                        error_detach
                        exit 1
                    fi

                    # Verify attachment
                    attached_verify2=$(sudo losetup -l "$loop_dev" 2>/dev/null | awk 'NR==2 {print $6}')
                    if [[ "$attached_verify2" != "$CONT_TARGET1" ]]; then
                        echo -e "\n${RED}Error: Loop device verification failed!${NC}\n"
                        sudo losetup -d "$loop_dev" 2>/dev/null || true
                        loop_dev=""
                        error_detach
                        exit 1
                    fi

                    echo -e "\n${BLUE}===============================================${NC}"
                    echo -e "${BLUE}Opening LUKS container...${NC}"
                    echo -e "${BLUE}===============================================${NC}"
                    sudo cryptsetup luksOpen "$loop_dev" "$TMP_MAPPER_NAME"
                    if [[ $? -ne 0 ]]; then
                        echo -e "\n${RED}Error:${NC} Failed to open LUKS container!\n"
                        error_detach
                        exit 1
                    fi
                    echo -e "${GREEN}✓ Container opened${NC}"
                fi

                # STEP 2: Filesystem check
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Checking filesystem integrity...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                sudo e2fsck -fy "/dev/mapper/${TMP_MAPPER_NAME}"
                e2fsck_result=$?
                if [[ $e2fsck_result -gt 2 ]]; then
                    echo -e "\n${RED}Error:${NC} Filesystem check failed!\n"
                    error_detach
                    exit 1
                fi
                echo -e "${GREEN}✓ Filesystem check passed.${NC}"

                # STEP 3: Shrink filesystem to target
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Shrinking filesystem to ${TARGET_FS_SIZE_MB}MB...${NC}"
                echo -e "${BLUE}===============================================${NC}"

                target_fs_size_str="${TARGET_FS_SIZE_MB}M"
                sudo resize2fs -p "/dev/mapper/${TMP_MAPPER_NAME}" "$target_fs_size_str"
                resize_result=$?

                if [[ $resize_result -ne 0 ]]; then
                    echo -e "${YELLOW}resize2fs failed with target. Trying minimum size...${NC}"
                    sudo resize2fs -M "/dev/mapper/${TMP_MAPPER_NAME}"
                    if [[ $? -ne 0 ]]; then
                        echo -e "\n${RED}Error:${NC} Failed to shrink filesystem!\n"
                        error_detach
                        exit 1
                    fi
                    # After -M, get the actual minimum and warn user
                    min_after_m=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                    min_after_m_mb=$((min_after_m * BLOCK_SIZE / 1024 / 1024))
                    TARGET_FS_SIZE_MB=$min_after_m_mb
                fi
                echo -e "${GREEN}✓ Filesystem shrunk.${NC}"

                # STEP 4: Get ACTUAL post-shrink filesystem size
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Getting new filesystem size...${NC}"
                echo -e "${BLUE}===============================================${NC}"

                new_fs_blocks=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                new_fs_block_size=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block size" | awk '{print $3}')
                new_fs_size_mb=$((new_fs_blocks * new_fs_block_size / 1024 / 1024))

                echo -e "Filesystem blocks: ${CYAN}${new_fs_blocks}${NC}"
                echo -e "Block size: ${CYAN}${new_fs_block_size}${NC}"
                echo -e "Filesystem size: ${CYAN}${new_fs_size_mb} MB${NC}"

                # STEP 5: Calculate exact LUKS payload and container sizes
                # LUKS payload must be at least filesystem size + alignment padding
                # Use the filesystem block count directly for sector math
                fs_sectors=$((new_fs_blocks * (new_fs_block_size / 512)))

                # Add alignment padding (LUKS2 uses 4096-byte = 8-sector alignment)
                alignment_sectors=8
                payload_sectors=$(( (fs_sectors + alignment_sectors - 1) / alignment_sectors * alignment_sectors ))

                # Get actual LUKS header offset (more accurate than fixed 18MB)
                header_sectors=$(sudo cryptsetup luksDump "$CONT_TARGET1" 2>/dev/null | awk '/Payload offset:/{print $3}')
                if [[ -z "$header_sectors" ]] || [[ "$header_sectors" -eq 0 ]]; then
                    # Fallback: detect LUKS version and use standard sizes
                    lv=$(sudo cryptsetup luksDump "$CONT_TARGET1" 2>/dev/null | grep -i "^Version:" | awk '{print $2}')
                    if [[ "$lv" == "2" ]]; then
                        header_sectors=32768  # 16MB
                    else
                        header_sectors=4096   # 2MB
                    fi
                fi

                container_sectors=$((header_sectors + payload_sectors))
                container_mb=$(( (container_sectors * 512 + 1048575) / 1048576 ))

                echo -e "\n${GRAY}Sector math:${NC}"
                echo -e "  Filesystem sectors: ${GRAY}${fs_sectors}${NC}"
                echo -e "  Aligned payload:    ${GRAY}${payload_sectors}${NC}"
                echo -e "  LUKS header:        ${GRAY}${header_sectors}${NC} sectors"
                echo -e "  Total container:    ${GRAY}${container_sectors}${NC} sectors"
                echo -e "  ${YELLOW}New container size: ${container_mb} MB${NC}"

                # STEP 6: Shrink LUKS device to exact payload size
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Shrinking LUKS device...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                sudo cryptsetup resize --size "${payload_sectors}" "/dev/mapper/${TMP_MAPPER_NAME}"
                if [[ $? -ne 0 ]]; then
                    echo -e "\n${RED}Error:${NC} Failed to resize LUKS device!\n"
                    error_detach
                    exit 1
                fi
                echo -e "${GREEN}✓ LUKS device resized to ${payload_sectors} sectors.${NC}"

                # STEP 7: Close LUKS and detach loop
                echo -e "\n${BLUE}Closing LUKS and detaching loop device...${NC}"
                sudo cryptsetup luksClose "$TMP_MAPPER_NAME" 2>/dev/null || sudo cryptsetup luksClose "$TMP_MAPPER_NAME" --force 2>/dev/null || true
                if [[ -n "$loop_dev" ]]; then
                    sudo losetup -d "$loop_dev" 2>/dev/null
                    loop_dev=""
                fi

                # STEP 8: Truncate file to exact container size
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Truncating container file...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                sudo truncate -s "${container_mb}M" "$CONT_TARGET1"
                if [[ $? -ne 0 ]]; then
                    echo -e "\n${RED}✗ Error: Failed to truncate file!${NC}\n"
                    error_detach
                    exit 1
                fi

                # Verify truncation
                final_size_bytes=$(sudo stat -c%s "$CONT_TARGET1" 2>/dev/null)
                final_size_mb=$((final_size_bytes / 1024 / 1024))
                echo -e "${GREEN}✓ File truncated to ${final_size_mb} MB${NC}"

                # STEP 9: Final verification
                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Final verification...${NC}"
                echo -e "${BLUE}===============================================${NC}"

                verify_and_mount_container "$CONT_TARGET1" "1"

                if [[ $? -eq 0 ]]; then
                    echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
                    echo -e "${GREEN}✓ Container successfully shrunk!${NC}"
                    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"

                    final_cont_bytes=$(sudo wc -c < "$CONT_TARGET1")
                    final_cont_mb=$((final_cont_bytes / 1024 / 1024))

                    echo -e "Final container size: ${GREEN}${final_cont_mb} MB${NC}"
                    echo -e "Final filesystem size: ${GREEN}${new_fs_size_mb} MB${NC}"
                    echo -e "Space saved: $((CALC_CONT_SIZE_MB - final_cont_mb)) MB"

                    # Final cleanup
                    error_detach
                else
                    echo -e "${RED}✗ Final verification failed!${NC}\n"
                    error_detach
                    exit 1
                fi

            else
                echo -e "${BLUE}LUKS container resizing cancelled.${NC}\n"
                error_detach
                exit 1
            fi
        fi

        manual_mount_ins
        SKIP_CLEANUP=1
        exit 0

    else
        echo -e "${RED}✗ Invalid selection.${NC} Please choose a number from the list [1-11].\n"
    fi
done

#####################################
# Function to create LUKS container #
#####################################
create_con() {
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Creating LUKS container file...${NC}"
    echo -e "${BLUE}===============================================${NC}"
    if command -v fallocate &>/dev/null; then
        sudo fallocate -l "${CON_SIZE1}M" "$MYPATH/$CON_NAME.bin" 2>/dev/null || { echo -e "${YELLOW}fallocate failed, falling back to dd...${NC}"; sudo dd if=/dev/zero of="$MYPATH/$CON_NAME.bin" bs=1M count="$CON_SIZE1" status=progress; }
    else
        sudo dd if=/dev/zero of="$MYPATH/$CON_NAME.bin" bs=1M count="$CON_SIZE1" status=progress
    fi
}

#############################
# Create new LUKS container #
#############################

# STEP 1: Set LUKS name
while true; do
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Container filename${NC}"
    echo -e "${BLUE}===============================================${NC}"
    read -p "Create a name for your LUKS container: " CON_NAME
    if [[ ! "$CON_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Error:${NC} Name contains invalid characters. Use only letters, numbers, hyphens, and underscores.\n"
    else
        break
    fi
done

echo -e "\n${CYAN}'$CON_NAME.bin'${NC} set."

# STEP 2: Set LUKS alias
while true;do
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Container alias${NC}"
    echo -e "${BLUE}===============================================${NC}"
    echo -e "Create an ${YELLOW}alias${NC} to identify the LUKS container."
    read -p "(eg. company-records or cloud_archive): " CON_ALIAS

    alias_chrs_count=$(echo "$CON_ALIAS" | wc -m)

    if [[ -z "$CON_ALIAS" ]]; then
        echo -e "${RED}Error:${NC} No alias set. Please create an alias.\n"
    elif [[ ! "$CON_ALIAS" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo -e "${RED}Error:${NC} Alias contains invalid characters.\n"
    elif [[ "$alias_chrs_count" -gt "18" ]]; then
        echo -e "${RED}Error:${NC} Alias too long. Use less than 18 characters.\n"
    else
        break
    fi
done

echo -e "\n${CYAN}'$CON_ALIAS'${NC} alias set for $CON_NAME.bin"

# STEP 3. Select LUKS container target location
while true; do
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Container location${NC}"
    echo -e "${BLUE}===============================================${NC}"
    read -p "Type the LUKS container storage path (full path): " SOURCED
    read -p "Is '$SOURCED' correct? [y/n] " RESP3

    if [[ "${RESP3,,}" != "y" ]]; then
        echo -e "Try again or <Ctrl+C> to cancel...\n"

    # Validate path
    elif [[ ! "$SOURCED" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        echo -e "${RED}Error:${NC} Path contains invalid characters.\n"
    elif [[ ! -d "$SOURCED" ]]; then
        echo -e "${RED}Error:${NC} Directory '$SOURCED' does not exist.\n"
        exit 1
    elif [[ -f "$SOURCED/$CON_NAME.bin" ]]; then
        echo -e "${YELLOW}⚠️ Warning:${NC} Existing LUKS container already found. Either delete or rename '$CON_NAME' to continue.\n"
    elif sudo cryptsetup status "$CON_ALIAS" &>/dev/null; then
        echo -e "${YELLOW}⚠️ Warning:${NC} LUKS container alias '$CON_ALIAS' already exists & is in use.\n"
        exit 1
    else
        MYPATH=${SOURCED}
        break
    fi
done

# STEP 4: Select LUKS target size
while true; do
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Container target size${NC}"
    echo -e "${BLUE}===============================================${NC}"
    read -p "Type in the size of the LUKS container in MB: " CON_SIZE1

    if ! [[ "$CON_SIZE1" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} Invalid input. Use numerical values only.\n"

    # Upper bound validation
    elif [[ "$CON_SIZE1" -gt 1048576 ]]; then
        echo -e "${RED}Error:${NC} Maximum container size is 1TB (1048576 MB).\n"
    elif (( CON_SIZE1 < 100 )); then
        echo -e "${RED}Error:${NC} Minimum size is 100 MB. Input larger size.\n"
        continue
    elif ! check_disk_space "$MYPATH" "$CON_SIZE1"; then
        echo -e "${RED}✗ Cannot proceed due to insufficient disk space.${NC}\n"
        exit 1
    else
        read -p "Is '$CON_SIZE1' MB correct? [y/n] " RESP4
        if [[ "${RESP4,,}" != "y" ]]; then
            echo -e "Try again or <Ctrl+C> to cancel...\n"
            continue
        else
            # Calculate size in GB
            if (( CON_SIZE1 >= 1024 )); then
                # Using awk instead of bc
                CALC=$(awk "BEGIN {printf \"%.2f\", $CON_SIZE1 / 1024}")
                echo -e "  ${BLUE}Estimated size:${NC} $CON_SIZE1 MB ≈ ${CALC} GB"
            fi
            break
        fi
    fi
done

# STEP 5: Ask about keyfile during creation
echo -e "\n${BLUE}===============================================${NC}"
echo -e "${BLUE}Keyfile Setup${NC}"
echo -e "${BLUE}===============================================${NC}"
echo -e "Would you like to add a keyfile to unlock this"
echo -e "container?"
echo -e "  ${BLUE}1)${NC} ${CYAN}Password only (default)${NC}"
echo -e "  ${BLUE}2)${NC} ${CYAN}Add a keyfile in addition to password${NC}"
echo -e "  ${BLUE}3)${NC} ${CYAN}Add a keyfile instead of password${NC}\n"
read -p "Enter choice [1-3]: " keyfile_setup_choice
keyfile_setup_choice=${keyfile_setup_choice:-1}

USE_KEYFILE=false
KEYFILE_PATH=""

if [[ "$keyfile_setup_choice" == "2" ]] || [[ "$keyfile_setup_choice" == "3" ]]; then
    echo -e "\n${CYAN}Keyfile Configuration:${NC}"

    read -p "Enter directory to save keyfile: " keyfile_dir

    # Validate keyfile directory
    if [[ ! "$keyfile_dir" =~ ^[a-zA-Z0-9_./-]+$ ]]; then
        echo -e "${RED}Error: Invalid characters in directory path${NC}"
        keyfile_dir="$MYPATH"
        echo -e "${YELLOW}Falling back to: $keyfile_dir${NC}"
    fi

    if [[ ! -d "$keyfile_dir" ]]; then
        sudo mkdir -p "$keyfile_dir" || { echo -e "${RED}Failed to create directory.${NC}"; keyfile_dir="$MYPATH"; }
        # Create with secure permissions (optional)
        #sudo chmod 700 "$keyfile_dir"
    fi

    read -p "Enter keyfile name (e.g., ${CON_NAME}.key): " keyfile_name

    # Validate keyfile name
    if [[ ! "$keyfile_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo -e "${RED}Error: Invalid characters in keyfile name. Using default.${NC}"
        keyfile_name="${CON_NAME}.keyfile"
    fi

    KEYFILE_PATH="$keyfile_dir/$keyfile_name"

    while true; do
        read -p "Keyfile size in bytes (recommended: 4096): " keyfile_size
        keyfile_size=${keyfile_size:-4096}

        # Upper bound validation
        if [[ "$keyfile_size" -gt 65536 ]]; then
            echo -e "${YELLOW}Warning: Keyfile size exceeds 64KB. Large keyfiles are unnecessary.${NC}"
            read -p "Continue with $keyfile_size bytes? [y/N]: " confirm_large
            if [[ "${confirm_large,,}" != "y" ]]; then
                continue
            fi
        fi

        if validate_positive_integer "$keyfile_size" "Keyfile size"; then
            break
        fi
    done

    echo -e "\n${CYAN}Generating random keyfile...${NC}"

    sudo dd if=/dev/urandom of="$KEYFILE_PATH" bs=1 count="$keyfile_size" 2>/dev/null

    # Verify keyfile was written correctly
    keyfile_size_actual=$(stat -c%s "$KEYFILE_PATH" 2>/dev/null)
    if [[ "$keyfile_size_actual" -ne "$keyfile_size" ]]; then
        echo -e "${RED}Error: Keyfile size mismatch. Expected: $keyfile_size, Got: $keyfile_size_actual${NC}"
        rm -f "$KEYFILE_PATH" 2>/dev/null
        exit 1
    fi

    # Create keyfile secure permissions (optional)
    #sudo chmod 600 "$KEYFILE_PATH"
    #sudo chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "$KEYFILE_PATH" 2>/dev/null || \
        #sudo chown root:root "$KEYFILE_PATH" 2>/dev/null || true

    echo -e "${GREEN}✓ Keyfile generated: $KEYFILE_PATH${NC}"
    echo -e "  Size: ${keyfile_size_actual} bytes"
    echo -e "  Permissions: $(stat -c%a "$KEYFILE_PATH")"

    USE_KEYFILE=true
fi

# STEP 6: Create LUKS container
create_con
echo -e "${GREEN}✓ '$CON_NAME.bin' created in $MYPATH${NC}"

# Atomic loop device attachment with verification
LOSP=$(sudo losetup -f --show --direct-io=on "$MYPATH/$CON_NAME.bin" 2>/dev/null)
if [[ $? -ne 0 ]] || [[ -z "$LOSP" ]]; then
    echo "${RED}Failed to get loop device.${NC}\n"
    exit 1
fi

# Verify loop device attachment
attached_verify3=$(sudo losetup -l "$LOSP" 2>/dev/null | awk 'NR==2 {print $6}')
if [[ "$attached_verify3" != "$MYPATH/$CON_NAME.bin" ]]; then
    echo -e "${RED}Error: Loop device verification failed!${NC}\n"
    sudo losetup -d "$LOSP" 2>/dev/null || true
    LOSP=""
    exit 1
fi

# STEP 7: Format LUKS container
echo -e "\n${BLUE}===============================================${NC}"
echo -e "${BLUE}Setting up LUKS encryption...${NC}"
echo -e "${BLUE}===============================================${NC}"

# Modified LUKS format based on keyfile choice
if [[ "$USE_KEYFILE" == true ]] && [[ "$keyfile_setup_choice" == "3" ]]; then
    # Keyfile only (no password)
    echo -e "${YELLOW}Creating LUKS container with keyfile only...${NC}"
    sudo cryptsetup luksFormat "$LOSP" --key-file="$KEYFILE_PATH"
elif [[ "$USE_KEYFILE" == true ]] && [[ "$keyfile_setup_choice" == "2" ]]; then
    # Password + keyfile
    echo -e "${YELLOW}Creating LUKS container with password...${NC}"
    sudo cryptsetup luksFormat "$LOSP"
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ LUKS container formatted with password${NC}"
        echo -e "${YELLOW}Adding keyfile...${NC}"
        sudo cryptsetup luksAddKey "$LOSP" "$KEYFILE_PATH"
    fi
else
    # Password only
    sudo cryptsetup luksFormat "$LOSP"
fi

if [[ $? -ne 0 ]]; then
    echo -e "${RED}Error: LUKS format failed.${NC}\n"
    sudo losetup -d "$LOSP" 2>/dev/null
    exit 1
fi

echo -e "\n${GREEN}✓ LUKS container formatted${NC}\n"

# STEP 8: Verify success by opening LUKS container
echo -e "Opening LUKS container..."

# Open with appropriate method
if [[ "$USE_KEYFILE" == true ]] && [[ "$keyfile_setup_choice" == "3" ]]; then
    sudo cryptsetup luksOpen "$LOSP" "$CON_ALIAS" --key-file="$KEYFILE_PATH"
else
    sudo cryptsetup luksOpen "$LOSP" "$CON_ALIAS"
fi

if [[ $? -ne 0 ]]; then
    echo -e "${RED}Error: Failed to open LUKS container.${NC}\n"
    sudo losetup -d "$LOSP" 2>/dev/null
    exit 1
fi

# STEP 9: Create ext4 filesystem
sudo mkfs.ext4 -F "/dev/mapper/$CON_ALIAS"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Error: Filesystem creation failed.${NC}\n"
    sudo cryptsetup luksClose "$CON_ALIAS" 2>/dev/null
    sudo losetup -d "$LOSP" 2>/dev/null
    exit 1
fi
echo -e "${GREEN}✓ Filesystem created${NC}\n"

#############################################################
# Auto-backup LUKS container header (uncomment if required) #
#############################################################
#echo -e "${YELLOW}Creating automatic header backup...${NC}"
#HEADER_BACKUP_DIR="$MYPATH/header_backup"
#sudo mkdir -p "$HEADER_BACKUP_DIR"
#HEADER_BACKUP_FILE="$HEADER_BACKUP_DIR/${CON_NAME}_header_$(date +%Y%m%d).img"
#sudo cryptsetup luksHeaderBackup "$LOSP" --header-backup-file "$HEADER_BACKUP_FILE" 2>/dev/null
#if [[ $? -eq 0 ]]; then
    #sudo chmod 600 "$HEADER_BACKUP_FILE"
    #echo -e "${GREEN}✓ Header backed up to: $HEADER_BACKUP_FILE${NC}\n"
#fi

##################################
# Prompt to mount LUKS container #
##################################
read -p "Do you want to mount the LUKS container? [y/n] " RESP5

if [[ "${RESP5,,}" = "y" ]]; then
    read -p "Type the mount path (full path): " MOUNT_PATH
    if [[ -d "$MOUNT_PATH" ]]; then
        sudo mount "/dev/mapper/$CON_ALIAS" "$MOUNT_PATH"
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}Error: Failed to mount container.${NC}\n"
            sudo cryptsetup luksClose "$CON_ALIAS" 2>/dev/null
            sudo losetup -d "$LOSP" 2>/dev/null
            cleanup
            exit 1
        fi
        echo -e "${GREEN}✓ LUKS container mounted to${NC} $MOUNT_PATH\n"
    else
        echo -e "${RED}Error:${NC} Cannot find the specified path '$MOUNT_PATH'."
        read -p "Would you like to create the directory? [y/n] " RESP6
        if [[ "${RESP6,,}" = "y" ]]; then
            sudo mkdir -p "$MOUNT_PATH"
            sudo mount "/dev/mapper/$CON_ALIAS" "$MOUNT_PATH"
            if [[ $? -ne 0 ]]; then
                echo -e "${RED}Error: Failed to mount container.${NC}\n"
                sudo cryptsetup luksClose "$CON_ALIAS" 2>/dev/null
                sudo losetup -d "$LOSP" 2>/dev/null
                sudo rmdir "$MOUNT_PATH" 2>/dev/null
                cleanup
                exit 1
            fi
            echo -e "${GREEN}✓ LUKS container mounted to${NC} $MOUNT_PATH\n"
        else
            echo -e "${BLUE}\nLUKS container won't be mounted.${NC}\n"
            manual_mount_ins
            cleanup
            exit 0
        fi
    fi
else
    # Final cleanup
    manual_mount_ins
    cleanup
    exit 0
fi

# Set mount directory permissions
sudo chown -R "$USERNAME":"$USERNAME" "$MOUNT_PATH"
echo -e "${GREEN}✓ Write permissions for${NC} '$USERNAME' ${GREEN}enabled on${NC} $MOUNT_PATH${NC}\n"

SKIP_CLEANUP=1

###################
# Success summary #
###################
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ LUKS container successfully created and mounted!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "  Container file: ${CYAN}$MYPATH/$CON_NAME.bin${NC}"
echo -e "  Mount point:    ${CYAN}$MOUNT_PATH${NC}"
echo -e "  Mapper name:    ${CYAN}$CON_ALIAS${NC}"
echo -e "  Size:           ${CYAN}$CON_SIZE1 MB${NC}"
if [[ "$USE_KEYFILE" == true ]]; then
    echo -e "  Keyfile:        ${CYAN}$KEYFILE_PATH${NC}"
fi
echo -e "  Header backup:  ${CYAN}$HEADER_BACKUP_FILE${NC}"
echo -e "\n${YELLOW}To unmount and close:${NC}"
echo -e "  sudo umount $MOUNT_PATH"
echo -e "  sudo cryptsetup luksClose $CON_ALIAS"
echo -e "  sudo losetup -d $LOSP"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}\n"

##############
# SCRIPT END #
##############
