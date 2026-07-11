#!/bin/bash

# Version variable
VRS=v4.1

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
NC='\033[0m' # No Color

# Constants
TMP_MAPPER_NAME="luks_tmp_resize"
TMP_MOUNT="/tmp/luks_mnt"
LUKS_HEADER_SIZE=18  # MB for LUKS2 header overhead
SAFETY_BUFFER=${SAFETY_BUFFER:-256}        # Conservative safety margin in MB
DATA_GROWTH_BUFFER=${DATA_GROWTH_BUFFER:-512}  # Expected data growth in MB
PERCENTAGE_BUFFER=20                        # Percentage buffer for filesystem operations


# Global array for container files
CONT_FILES=()

# Initialize global variables to prevent unbound variable errors
LOSP=""
loop_dev=""
MOUNT_PATH=""
CON_ALIAS=""
CONT_TARGET1=""
TOTAL_REAL_SIZE=0
FS_SIZE_MB=0
SKIP_CLEANUP=""
DISPLAY_KEYSLOTS_COUNT=0

#######################################################################
# Function to cleanup open or mounted containers on error/forced exit #
#######################################################################
cleanup() {
    local exit_code=$?

    if [[ -n "$SKIP_CLEANUP" ]]; then
        exit $exit_code
    fi

    sudo umount "$MOUNT_PATH" 2>/dev/null || true
    sudo umount "$TMP_MOUNT" 2>/dev/null || true
    sudo cryptsetup luksClose "$CON_ALIAS" 2>/dev/null || true
    sudo cryptsetup luksClose "$TMP_MAPPER_NAME" 2>/dev/null || true

    if [[ -n "$LOSP" ]]; then
        sudo losetup -d "$LOSP" 2>/dev/null || true
    fi
    if [[ -n "$loop_dev" ]]; then
        sudo losetup -d "$loop_dev" 2>/dev/null || true
    fi

    if [[ -d "$TMP_MOUNT" ]]; then
        sudo rm -rf "$TMP_MOUNT" 2>/dev/null || true
    fi

    exit $exit_code
}

trap cleanup EXIT

##########################################
# Function to check available disk space #
##########################################
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

####################################
# Find existing container function #
####################################
find_con () {
    local exs_path
    local file

    echo
    read -p "Specify LUKS container directory (full path): " exs_path

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

###############################################################
# Function to safely mount and verify container before resize #
###############################################################
verify_and_mount_container() {
    local container_path="$1"
    local unmount_flag="$2"
    local fs_size block_size fs_size_mb total_real_size

    if ! findmnt "/dev/mapper/${TMP_MAPPER_NAME}" &>/dev/null; then
        loop_dev=$(sudo losetup -f --show "$container_path")
        if [[ $? -ne 0 ]] || [[ -z "$loop_dev" ]]; then
            echo -e "${RED}Error: Failed to get loop device${NC}\n"
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

    total_real_size=$(du --apparent-size -smc "$TMP_MOUNT" 2>/dev/null | grep total | awk '{print $1}')

    if [[ -z "$total_real_size" ]] || [[ "$total_real_size" -eq 0 ]]; then
        total_real_size=$(du -smc "$TMP_MOUNT" 2>/dev/null | grep total | awk '{print $1}')
    fi

    if findmnt "/dev/mapper/${TMP_MAPPER_NAME}" &>/dev/null; then
        sudo umount "$TMP_MOUNT" 2>/dev/null || sudo umount -l "$TMP_MOUNT" 2>/dev/null
        sudo rm -rf "$TMP_MOUNT" 2>/dev/null
    fi

    echo -e "\n${GREEN}✓ Container verified.${NC}\n"
    echo -e "  Current filesystem size: ${CYAN}${fs_size_mb} MB${NC}"
    echo -e "  Current data size (files): ${YELLOW}${total_real_size} MB${NC}"
    #echo -e "  ─────────────────────────────────────────────"

    if [[ -z $unmount_flag ]]; then
        sudo cryptsetup luksClose "$TMP_MAPPER_NAME" 2>/dev/null
        sudo losetup -d "$loop_dev" 2>/dev/null
    fi

    TOTAL_REAL_SIZE=$total_real_size
    FS_SIZE_MB=$fs_size_mb

    return 0
}


##########################################################
# Calculate minimum safe container size for shrinking    #
##########################################################
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

    # Define buffer constants (can be moved to script global scope)
    #local SAFETY_BUFFER=${SAFETY_BUFFER:-512}        # Conservative safety margin in MB
    #local DATA_GROWTH_BUFFER=${DATA_GROWTH_BUFFER:-1024}  # Expected data growth in MB
    #local PERCENTAGE_BUFFER=20                        # Percentage buffer for filesystem operations

    # Calculate different minimum sizes using consistent methodology
    local percent_padding=$(( (fs_size_mb * PERCENTAGE_BUFFER) / 100 ))

    # 1. Conservative: filesystem-based calculation (safest)
    local min_conservative=$(( data_size_mb + SAFETY_BUFFER + DATA_GROWTH_BUFFER + percent_padding ))

    # 2. Moderate: percentage-based calculation
    local min_moderate=$(( data_size_mb + percent_padding + SAFETY_BUFFER ))

    # 3. Aggressive: minimal padding (riskiest)
    local min_aggressive=$(( data_size_mb + SAFETY_BUFFER ))

    # Ensure no minimum exceeds the current filesystem size
    local absolute_min
    local safety_level=""
    local warning_flag=""

    if [[ $min_conservative -le $fs_size_mb ]]; then
        # Can use conservative estimate
        absolute_min=$min_conservative
        safety_level="CONSERVATIVE"
    elif [[ $min_moderate -le $fs_size_mb ]]; then
        # Fall back to moderate estimate
        absolute_min=$min_moderate
        safety_level="MODERATE"
    elif [[ $min_aggressive -le $fs_size_mb ]]; then
        # Minimum viable size with warning
        absolute_min=$min_aggressive
        safety_level="MINIMAL"
        warning_flag="LOW_SAFETY"
    else
        # Current data exceeds shrinkable minimum
        absolute_min=$fs_size_mb
        safety_level="CRITICAL"
        warning_flag="CANNOT_SHRINK"
    fi

    # Add LUKS header overhead to absolute minimum for final container size
    local final_container_min=$(( absolute_min + LUKS_HEADER_SIZE ))

    # Store result in a global variable (bash return limited to 0-255)
    CALC_MIN_SIZE=$absolute_min
    CALC_MIN_CONTAINER=$final_container_min
    CALC_SAFETY_LEVEL=$safety_level

    # Display analysis
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Size Analysis for Shrink Operation${NC}"
    echo -e "${BLUE}===============================================${NC}"
    echo -e "  Current container size:    ${CALC_CONT_SIZE_MB} MB"
    echo -e "  Filesystem size:           ${fs_size_mb} MB"
    echo -e "  Data content:              ${YELLOW}${data_size_mb} MB${NC}"
    echo -e "  ─────────────────────────────────────────────"
    echo -e "  ${GRAY}LUKS header overhead:      ${LUKS_HEADER_SIZE} MB${NC}"
    echo -e "  ${GRAY}Safety buffer:             ${SAFETY_BUFFER} MB${NC}"
    echo -e "  ${GRAY}Data growth buffer:        ${DATA_GROWTH_BUFFER} MB${NC}"
    echo -e "  ${GRAY}Filesystem padding:        ${PERCENTAGE_BUFFER}% (${percent_padding} MB)${NC}"
    echo -e "  ─────────────────────────────────────────────"

    # Display tiered options
    echo -e "  Conservative minimum:      ${GREEN}${min_conservative} MB${NC}"
    echo -e "  Moderate minimum:          ${YELLOW}${min_moderate} MB${NC}"
    echo -e "  Aggressive minimum:        ${RED}${min_aggressive} MB${NC}"
    echo -e "  ─────────────────────────────────────────────"

    case $safety_level in
        "CONSERVATIVE")
            #echo -e "  Selected target:           ${GREEN}${absolute_min} MB${NC}"
            echo -e "  Container minimum:         ${GRAY}${final_container_min} MB${NC}"
            echo -e "  Safety margin:             ${GREEN}ADEQUATE${NC}"
            ;;
        "MODERATE")
            #echo -e "  Selected target:           ${YELLOW}${absolute_min} MB${NC}"
            echo -e "  Container minimum:         ${GRAY}${final_container_min} MB${NC}"
            echo -e "  Safety margin:             ${YELLOW}REDUCED${NC}"
            ;;
        "MINIMAL")
            #echo -e "  Selected target:           ${RED}${absolute_min} MB${NC}"
            echo -e "  Container minimum:         ${GRAY}${final_container_min} MB${NC}"
            echo -e "  Safety margin:             ${RED}MINIMAL - HIGH RISK${NC}"
            ;;
        "CRITICAL")
            #echo -e "  Selected target:           ${RED}${absolute_min} MB${NC}"
            echo -e "  Container minimum:         ${GRAY}${final_container_min} MB${NC}"
            echo -e "  \n${RED}WARNING: Cannot safely shrink below current size${NC}"
            ;;
    esac

    #echo -e "\n${BLUE}Options:${NC}"
    #echo -e "  1. Use ${GREEN}conservative${NC} target for maximum safety"
    #if [[ "$safety_level" != "CRITICAL" ]]; then
        #echo -e "  2. Use ${YELLOW}moderate${NC} target with reduced safety margin"
        #echo -e "  3. Use ${RED}aggressive${NC} target (not recommended)"
    #fi

    echo -e "\n${YELLOW}Important:${NC}"
    echo -e "• Shrinking carries inherent risk of data loss."
    echo -e "• ${BOLD}ALWAYS create a backup before proceeding.${NC}"
    echo -e "• Filesystem fragmentation may require more space."

    if [[ "$warning_flag" == "CANNOT_SHRINK" ]]; then
        echo -e "${BLUE}===============================================${NC}"
        echo -e "${RED}⛔ CRITICAL: Current data usage prevents safe shrinking${NC}"
        echo -e "Consider removing unnecessary files or increasing container size"
    elif [[ "$warning_flag" == "LOW_SAFETY" ]]; then
        echo -e "${BLUE}===============================================${NC}"
        echo -e "${RED}⚠️ DANGER: Minimum safety margins - corruption risk is HIGH${NC}"
    fi

    echo -e "${BLUE}===============================================${NC}"

    # Optional confirmation pause
    if [[ "${AUTO_CONFIRM:-0}" != "1" ]]; then
        echo -e "\n${YELLOW}Press Enter to continue or Ctrl+C to abort...${NC}"
        read -r
    fi

    return 0
}


#######################################
# Unmount & detach on error function  #
#######################################
error_detach () {
    sudo umount "$TMP_MOUNT" 2>/dev/null || sudo umount -l "$TMP_MOUNT" 2>/dev/null
    sudo cryptsetup luksClose "$TMP_MAPPER_NAME" 2>/dev/null
    [[ -n "$loop_dev" ]] && sudo losetup -d "$loop_dev" 2>/dev/null
    [[ -n "$LOSP" ]] && sudo losetup -d "$LOSP" 2>/dev/null
    [[ -d "$TMP_MOUNT" ]] && sudo rm -rf "$TMP_MOUNT" 2>/dev/null

    # Reset global variables to prevent stale references
    loop_dev=""
    LOSP=""
}

##########################################
# Instructions for manual mount function #
##########################################
manual_mount_ins() {
echo -e "\n══════════════════════════════════════════════════════"
echo -e "${YELLOW}To open, mount, & set write permissions on dir:${NC}"
echo -e "  sudo losetup -f --show </path/to/container.bin>"
echo -e "  sudo cryptsetup luksOpen <loop-device> <alias> ${CYAN}--key-file <keyfile>${NC}"
echo -e "  sudo mount /dev/mapper/<loop-device> <mount-dir>"
echo -e "  sudo chown -R <username>:<username> <mount-dir>"
echo -e "\n${YELLOW}To unmount, close, & detach:${NC}"
echo -e "  sudo umount <mount-dir>"
echo -e "  sudo cryptsetup luksClose <alias>"
echo -e "  sudo losetup -d <loop-device>"
echo -e "══════════════════════════════════════════════════════\n"
}

####################################################
# Function to display keyslot information          #
####################################################
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

        # Parse the LUKS2 structure
        local in_keyslots=0
        local current_slot=""

        while IFS= read -r line; do
            # Exact match for "Keyslots:" (the section header, not "Keyslots area:")
            if [[ "$line" =~ ^Keyslots:$ ]]; then
                in_keyslots=1
                continue
            fi

            # Exit keyslots section on Tokens: or Digests: sections
            # Note: We do NOT exit on "Data segments:" because it appears BEFORE Keyslots
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

####################################################
# Backup LUKS header function                      #
####################################################
backup_luks_header() {
    local container_path="$1"
    local backup_path

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Header Backup${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "${YELLOW}⚠️ IMPORTANT:${NC} The LUKS header contains encryption keys."
    echo -e "If the header is damaged, all data is lost. ${YELLOW}Keep backups safe!${NC}\n"

    read -p "Enter backup directory (full path): " backup_path

    if [[ ! -d "$backup_path" ]]; then
        echo -e "${YELLOW}Directory doesn't exist. Creating...${NC}"
        sudo mkdir -p "$backup_path" || { echo -e "${RED}Failed to create directory.${NC}\n"; return 1; }
    fi

    local backup_file="$backup_path/$(basename "$container_path")_header_$(date +%Y%m%d_%H%M%S).img"

    echo -e "\n${CYAN}Backing up LUKS header to:${NC} $backup_file"
    sudo cryptsetup luksHeaderBackup "$container_path" --header-backup-file "$backup_file"

    if [[ $? -eq 0 ]]; then
        echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}✓ LUKS header backed up successfully!${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "  Backup file: ${CYAN}$backup_file${NC}"
        echo -e "  Size: $(sudo stat -c%s "$backup_file" | numfmt --to=iec) bytes"
        echo -e "\n${YELLOW}Restore command:${NC}"
        echo -e "  sudo cryptsetup luksHeaderRestore $container_path --header-backup-file $backup_file"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    else
        echo -e "${RED}✗ Header backup failed!${NC}"
        return 1
    fi
    echo
}

####################################################
# Validate numeric input function                  #
####################################################
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

####################################################
# Add keyfile to LUKS container                    #
####################################################
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
        if [[ ! -d "$keyfile_dir" ]]; then
            sudo mkdir -p "$keyfile_dir" || { echo -e "${RED}Failed to create directory.${NC}\n"; return 1; }
        fi

        read -p "Enter keyfile name (e.g. my_key.key): " keyfile_name
        keyfile_path="$keyfile_dir/$keyfile_name"

        while true; do
            read -p "Keyfile size in bytes (recommended: 4096): " keyfile_size
            keyfile_size=${keyfile_size:-4096}

            if validate_positive_integer "$keyfile_size" "Keyfile size"; then
                break
            fi
        done

        echo -e "\n${CYAN}Generating random keyfile...${NC}"
        sudo dd if=/dev/urandom of="$keyfile_path" bs=1 count="$keyfile_size" 2>/dev/null
        sudo chmod 600 "$keyfile_path"
        echo -e "${GREEN}✓ Keyfile generated: $keyfile_path${NC}"
    else
        read -p "Enter path to existing keyfile: " keyfile_path
        if [[ ! -f "$keyfile_path" ]]; then
            echo -e "${RED}Error: Keyfile not found.${NC}\n"
            return 1
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

####################################################
# Change LUKS password function                    #
####################################################
change_password() {
    local container_path="$1"

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Change LUKS Container Password${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "${YELLOW}Current keyslots:${NC}"
    display_keyslots "$container_path"

    echo -e "\n${CYAN}Options:${NC}"
    echo -e "  ${BLUE}1)${NC} ${CYAN}Add new password to a new keyslot${NC}"
    echo -e "  ${BLUE}2)${NC} ${CYAN}Change existing password (requires current password)${NC}"
    echo -e "  ${BLUE}3)${NC} ${CYAN}Back to main menu${NC}"
    echo
    read -p "Enter choice [1-3]: " pwd_choice

    case "$pwd_choice" in
        1)
            echo -e "\n${CYAN}Adding new password to a new keyslot...${NC}"
            echo -e "${YELLOW}Enter current passphrase when prompted, then new passphrase.${NC}"
            sudo cryptsetup luksAddKey "$container_path"

            if [[ $? -eq 0 ]]; then
                echo -e "\n${GREEN}✓ New password added successfully!${NC}"
                echo -e "\n${YELLOW}Updated keyslots:${NC}"
                display_keyslots "$container_path"
                echo -e "\n${YELLOW}Tip: You can now optionally remove the old keyslot with option 7 (Remove Keyslot).${NC}"
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

####################################################
# Remove keyslot function                          #
####################################################
remove_keyslot() {
    local container_path="$1"

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}Remove Keyslot from LUKS Container${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "${YELLOW}Current keyslots:${NC}"
    display_keyslots "$container_path"
    local enabled_count=$DISPLAY_KEYSLOTS_COUNT

    # Get LUKS dump for validation
    local luks_dump
    luks_dump=$(sudo cryptsetup luksDump "$container_path" 2>/dev/null)
    local luks_version
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
    echo -e "container!"
    echo -e "${RED}Never remove the last remaining key slot.${NC} Doing so"
    echo -e "makes the encrypted data permanently inaccessible!"
    echo
    echo -e "${YELLOW}To auto detect which slot a passphrase unlocks:${NC}"
    echo -e "  sudo cryptsetup open --test-passphrase --verbose \\"
    echo -e "  \"$container_path\""
    echo -e "\nOutput will indicate: 'Key slot X unlocked'"
    echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}\n"

    # Get list of enabled slot numbers for validation
    local enabled_slot_numbers=()
    if [[ "$luks_version" == "2" ]]; then
        # Parse LUKS2 structure for enabled slots
        local in_keyslots=0
        local current_slot=""
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
        local is_enabled=false
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
        read -p "Type 'yes' to confirm: " confirm
        if [[ "$confirm" != "yes" ]]; then
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


####################################################
# Show container info function                     #
####################################################
show_container_info() {
    local container_path="$1"

    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Container Information${NC}"
    echo -e "${BLUE}===============================================${NC}\n"

    echo -e "  Container: ${CYAN}$container_path${NC}"

    # Get file size
    local file_size
    file_size=$(sudo stat -c%s "$container_path" 2>/dev/null)
    if [[ -n "$file_size" ]]; then
        echo -e "  File size: ${CYAN}$(numfmt --to=iec "$file_size")${NC} ($file_size bytes)"
    fi

    # Get LUKS header info
    local luks_dump
    luks_dump=$(sudo cryptsetup luksDump "$container_path" 2>/dev/null)

    if [[ -z "$luks_dump" ]]; then
        echo -e "\n${RED}Error: Could not read LUKS header${NC}\n"
        return 1
    fi

    # Extract LUKS information
    local luks_version luks_type cipher cipher_mode hash uuid label

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

    local found_slot=0

    # For LUKS2, parse the "Keyslots:" section
    if echo "$luks_dump" | grep -q "^Keyslots:"; then
        local in_keyslot=0
        local current_slot=""
        local has_key=0
        local slot_priority=""
        local slot_processed=0

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

    echo -e "${BLUE}===============================================${NC}"
}


# Obtaining the original user's username & home directory using environment variables
USERNAME=${SUDO_USER:-$USER}
HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)

# Welcome banner
echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}\n"
echo -e "${YELLOW}    Create & mount LUKS containers script $VRS${NC}"
echo -e "\nEncrypted block devices (partitions) are not supported,"
echo -e "only LUKS file containers / images with .bin extension."
echo -e "\n • Multiple LUKS file containers mountable."
echo -e " • Expand or shrink existing images."
echo -e " • Keyslot management."
echo -e " • Header backup support."
echo -e " • Keyfile support."
echo -e " • Display detailed container info.\n"

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
    echo -e "  ${BLUE}5)${NC} ${CYAN}Add keyfile to container${NC}"
    echo -e "  ${BLUE}6)${NC} ${CYAN}Add/Change container password${NC}"
    echo -e "  ${BLUE}7)${NC} ${CYAN}Remove keyslot${NC}"
    echo -e "  ${BLUE}8)${NC} ${CYAN}Show container information${NC}"
    echo -e "  ${BLUE}9)${NC} ${BLUE}Exit${NC}\n"

    read -p "Enter choice [1-9]: " TASK_NUM

    # Handle new menu options (4-8) that need container selection
    if [[ "$TASK_NUM" =~ ^[4-8]$ ]]; then
        find_con

        case "$TASK_NUM" in
            4)
                backup_luks_header "$CONT_TARGET1"
                echo -e "\n${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            5)
                add_keyfile "$CONT_TARGET1"
                echo -e "\n${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            6)
                change_password "$CONT_TARGET1"
                echo -e "\n${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            7)
                remove_keyslot "$CONT_TARGET1"
                echo -e "\n${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
            8)
                show_container_info "$CONT_TARGET1"
                echo -e "\n${BLUE}Press Enter to return to main menu...${NC}"
                read
                continue
                ;;
        esac
    fi

    if [[ "$TASK_NUM" == "9" ]]; then
        echo -e "\n${BLUE}Script will exit.${NC}\n"
        exit 0
    elif [[ "$TASK_NUM" == "1" ]]; then
        break
    elif [[ "$TASK_NUM" == "2" ]] || [[ "$TASK_NUM" == "3" ]]; then
        find_con

        echo -e "\nOpening LUKS container for analysis..."
        verify_and_mount_container "$CONT_TARGET1"

        CALC_CONT_SIZE_BYTES=$(sudo wc -c < "$CONT_TARGET1")
        CALC_CONT_SIZE_MB=$((CALC_CONT_SIZE_BYTES / 1024 / 1024))
        echo -e "  Current LUKS container size: ${CYAN}${CALC_CONT_SIZE_MB} MB${NC}\n"

        if [[ "$TASK_NUM" == "2" ]]; then
            while true; do
                read -p "Specify the new expanded LUKS container size (in MB):  " TOTAL_CONT_SIZE

                if [[ ! "$TOTAL_CONT_SIZE" =~ ^[0-9]+$ ]]; then
                    echo -e "\n${RED}Error:${NC} Invalid size. Numerical values only.\n"
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

            CALC2=$(echo "scale=2; $TOTAL_CONT_SIZE / 1024" | bc)
            echo -e "New LUKS container size will be ${CYAN}$TOTAL_CONT_SIZE MB${NC} (approx ${CALC2} GB)."
            read -p "Is this correct? [y/n] " RESP1

            if [[ "${RESP1,,}" == "y" ]]; then
                echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}CAUTION:${NC} Risk of data corruption if LUKS container"
                echo -e "is interrupted or fails while resizing.${YELLOW} Please make a backup${NC}"
                echo -e "${YELLOW}of LUKS container before proceeding!${NC}"
                echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}"
                sleep 1

                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Expanding container file...${NC}"
                echo -e "${BLUE}===============================================${NC}"

                NEW_CONT_SIZE=$((TOTAL_CONT_SIZE - CALC_CONT_SIZE_MB))
                FILE_SIZE_BEFORE=$(sudo stat -c%s "$CONT_TARGET1" 2>/dev/null)
                FILE_SIZE_BEFORE_MB=$((FILE_SIZE_BEFORE / 1024 / 1024))

                echo -e "Current file size: ${CYAN}${FILE_SIZE_BEFORE_MB} MB${NC}"
                echo -e "Need to add: ${CYAN}${NEW_CONT_SIZE} MB${NC}"
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

                # FINAL VERIFICATION
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

                # STEP 2: Get fresh loop device
                #echo -e "\n${BLUE}===============================================${NC}"
                #echo -e "${BLUE}Step 2: Getting fresh loop device...${NC}"
                #echo -e "${BLUE}===============================================${NC}"

                loop_dev=$(sudo losetup -f --show "$CONT_TARGET1" 2>/dev/null)
                if [[ $? -ne 0 ]] || [[ -z "$loop_dev" ]]; then
                    echo -e "\n${RED}Error:${NC} Failed to get loop device\n"
                    exit 1
                fi
                #echo -e "Loop device: ${CYAN}$loop_dev${NC}"

                LOOP_SIZE=$(sudo blockdev --getsize64 "$loop_dev" 2>/dev/null)
                LOOP_SIZE_MB=$((LOOP_SIZE / 1024 / 1024))
                #echo -e "Loop device size: ${CYAN}${LOOP_SIZE_MB} MB${NC}"

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
                        loop_dev=$(sudo losetup -f --show "$CONT_TARGET1" 2>/dev/null)
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
                #echo -e "LUKS device size before resize: ${CYAN}${LUKS_SIZE_MB_BEFORE} MB${NC}"

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
                #echo -e "LUKS device size after resize: ${CYAN}${LUKS_SIZE_MB_AFTER} MB${NC}"

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

                # Cleanup
                echo -e "\nClosing container..."
                error_detach

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
            # Shrink logic with minimum size calculation
            calculate_min_safe_size "$FS_SIZE_MB" "$TOTAL_REAL_SIZE"

            while true; do
                echo -e "\n${YELLOW}${UNDERLINE}Note:${NC} This operation requires shrinking the LUKS"
                echo -e "container filesystem first and then fitting the"
                echo -e "container around the new smaller size.\n"
                read -p "Specify the new truncated filesystem size (in MB):  " TOTAL_CONT_SIZE

                if [[ ! "$TOTAL_CONT_SIZE" =~ ^[0-9]+$ ]]; then
                    echo -e "\n${RED}Error:${NC} Invalid size. Numerical values only."
                elif [[ "$TOTAL_CONT_SIZE" -ge "$CALC_CONT_SIZE_MB" ]]; then
                    echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}"
                    echo -e "${YELLOW}⚠️ Warning:${NC} Specified size is the same or greater than"
                    echo -e "existing LUKS container. Select a smaller size to continue."
                    echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}"
                else
                    break
                fi
            done

            CALC2=$(echo "scale=2; $TOTAL_CONT_SIZE / 1024" | bc)
            echo -e "New LUKS container filesystem will be ${CYAN}$TOTAL_CONT_SIZE MB${NC} (approx ${CALC2} GB)."
            read -p "Is this correct? [y/n] " RESP2

            if [[ "${RESP2,,}" == "y" ]]; then
                #echo -e "\n${BLUE}===============================================${NC}"
                #echo -e "${BLUE}Step 1: Getting loop device...${NC}"
                #echo -e "${BLUE}===============================================${NC}"
                loop_dev=$(sudo losetup -f --show "$CONT_TARGET1" 2>/dev/null)
                if [[ $? -ne 0 ]] || [[ -z "$loop_dev" ]]; then
                    echo -e "\n${RED}Error:${NC} Failed to get loop device\n"
                    error_detach
                    exit 1
                fi
                #echo -e "Loop device: ${CYAN}$loop_dev${NC}"

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

                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Shrinking filesystem to ${TOTAL_CONT_SIZE}MB...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                TARGET_FS_SIZE="${TOTAL_CONT_SIZE}M"
                sudo resize2fs -p "/dev/mapper/${TMP_MAPPER_NAME}" "$TARGET_FS_SIZE"
                resize_result=$?

                if [[ $resize_result -ne 0 ]]; then
                    echo -e "${YELLOW}Trying minimum size shrink...${NC}"
                    sudo resize2fs -M "/dev/mapper/${TMP_MAPPER_NAME}"
                    if [[ $? -ne 0 ]]; then
                        echo -e "\n${RED}Error:${NC} Failed to shrink filesystem!\n"
                        error_detach
                        exit 1
                    fi
                    sudo resize2fs -p "/dev/mapper/${TMP_MAPPER_NAME}" "$TARGET_FS_SIZE"
                    if [[ $? -ne 0 ]]; then
                        echo -e "${RED}✗ Error: Failed to resize filesystem! Either target size is too small or container is corrupted.${NC}\n"
                        error_detach
                        exit 1
                    fi
                fi
                echo -e "${GREEN}✓ Filesystem shrunk.${NC}"

                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Getting new filesystem size...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                NEW_FS_SIZE=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block count" | awk '{print $3}')
                NEW_FS_BLOCK_SIZE=$(sudo dumpe2fs -h "/dev/mapper/${TMP_MAPPER_NAME}" 2>/dev/null | grep "Block size" | awk '{print $3}')
                NEW_FS_SIZE_MB=$((NEW_FS_SIZE * NEW_FS_BLOCK_SIZE / 1024 / 1024))
                echo -e "Filesystem size: ${CYAN}${NEW_FS_SIZE_MB} MB${NC}"

                NEW_CONT_SIZE_MB=$((NEW_FS_SIZE_MB + LUKS_HEADER_SIZE + 2))
                echo -e "${YELLOW}New container size: ${NEW_CONT_SIZE_MB} MB${NC}"

                # Use bc for large number calculation to prevent overflow
                NEW_SIZE_SECTORS=$(echo "$NEW_CONT_SIZE_MB * 1024 * 1024 / 512" | bc)

                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Shrinking LUKS device...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                sudo cryptsetup resize --size "${NEW_SIZE_SECTORS}" "/dev/mapper/${TMP_MAPPER_NAME}"
                if [[ $? -ne 0 ]]; then
                    echo -e "\n${RED}Error:${NC} Failed to resize LUKS device!\n"
                    error_detach
                    exit 1
                fi
                echo -e "${GREEN}✓ LUKS device resized.${NC}"

                #echo -e "\n${BLUE}===============================================${NC}"
                #echo -e "${BLUE}Step 8: Closing container...${NC}"
                #echo -e "${BLUE}===============================================${NC}"
                sudo cryptsetup luksClose "$TMP_MAPPER_NAME" 2>/dev/null || sudo cryptsetup luksClose "$TMP_MAPPER_NAME" --force 2>/dev/null || true
                sudo losetup -d "$loop_dev" 2>/dev/null

                #echo -e "\n${BLUE}===============================================${NC}"
                #echo -e "${BLUE}Truncating file to${NC} ${CYAN}${NEW_CONT_SIZE_MB}M${NC} ${BLUE}...${NC}"
                #echo -e "${BLUE}===============================================${NC}"
                sudo truncate -s "${NEW_CONT_SIZE_MB}M" "$CONT_TARGET1"
                if [[ $? -ne 0 ]]; then
                    echo -e "\n${RED}✗ Error: Failed to truncate file!${NC}\n"
                    error_detach
                    exit 1
                fi
                echo -e "${GREEN}✓ File truncated.${NC}"

                echo -e "\n${BLUE}===============================================${NC}"
                echo -e "${BLUE}Final verification...${NC}"
                echo -e "${BLUE}===============================================${NC}"
                verify_and_mount_container "$CONT_TARGET1" "1"

                if [[ $? -eq 0 ]]; then
                    echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
                    echo -e "${GREEN}✓ Container successfully shrunk!${NC}"
                    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
                    CALC_CONT_SIZE_BYTES=$(sudo wc -c < "$CONT_TARGET1")
                    CALC_CONT_SIZE_MB=$((CALC_CONT_SIZE_BYTES / 1024 / 1024))
                    echo -e "Final container size: ${GREEN}${CALC_CONT_SIZE_MB} MB${NC}"
                    echo -e "Final filesystem size: ${GREEN}${NEW_FS_SIZE_MB} MB${NC}"
                    #echo -e "${GREEN}══════════════════════════════════════════════════════${NC}\n"
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
        echo -e "${RED}✗ Invalid selection.${NC} Please choose a number from the list [1-9].\n"
    fi
done

################################
# Set container name and alias #
################################
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

while true; do
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Container location${NC}"
    echo -e "${BLUE}===============================================${NC}"
    read -p "Type the LUKS container storage path (full path): " SOURCED
    read -p "Is '$SOURCED' correct? [y/n] " RESP3

    if [[ "${RESP3,,}" != "y" ]]; then
        echo -e "Try again or <Ctrl+C> to cancel...\n"
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

while true; do
    echo -e "\n${BLUE}===============================================${NC}"
    echo -e "${BLUE}LUKS Container target size${NC}"
    echo -e "${BLUE}===============================================${NC}"
    read -p "Type in the size of the LUKS container in MB: " CON_SIZE1

    if ! [[ "$CON_SIZE1" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error:${NC} Invalid input. Use numerical values only.\n"
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
            #echo -e "\n${YELLOW}Note:${NC} LUKS container file size uses base-10 numbers."
            if (( CON_SIZE1 >= 1024 )); then
                CALC=$(echo "scale=2; $CON_SIZE1 / 1024" | bc)
                echo -e "  ${BLUE}Estimated size:${NC} $CON_SIZE1 MB ≈ ${CALC} GB"
            fi
            break
        fi
    fi
done

# Ask about keyfile during creation
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
    if [[ ! -d "$keyfile_dir" ]]; then
        sudo mkdir -p "$keyfile_dir" || { echo -e "${RED}Failed to create directory.${NC}"; keyfile_dir="$MYPATH"; }
    fi

    read -p "Enter keyfile name (e.g., ${CON_NAME}.key): " keyfile_name
    KEYFILE_PATH="$keyfile_dir/$keyfile_name"

    while true; do
        read -p "Keyfile size in bytes (recommended: 4096): " keyfile_size
        keyfile_size=${keyfile_size:-4096}

        if validate_positive_integer "$keyfile_size" "Keyfile size"; then
            break
        fi
    done

    echo -e "\n${CYAN}Generating random keyfile...${NC}"
    sudo dd if=/dev/urandom of="$KEYFILE_PATH" bs=1 count="$keyfile_size" 2>/dev/null
    sudo chmod 600 "$KEYFILE_PATH"
    echo -e "${GREEN}✓ Keyfile generated: $KEYFILE_PATH${NC}"

    USE_KEYFILE=true
fi

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

create_con
echo -e "${GREEN}✓ '$CON_NAME.bin' created in $MYPATH${NC}"

LOSP=$(sudo losetup -f --show "$MYPATH/$CON_NAME.bin" 2>/dev/null)
if [[ $? -ne 0 ]] || [[ -z "$LOSP" ]]; then
    echo "${RED}Failed to get loop device.${NC}\n"
    exit 1
fi

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

#echo -e "\n${BLUE}===============================================${NC}"
#echo -e "${BLUE}Creating ext4 filesystem...${NC}"
#echo -e "${BLUE}===============================================${NC}"
sudo mkfs.ext4 -F "/dev/mapper/$CON_ALIAS"
if [[ $? -ne 0 ]]; then
    echo -e "${RED}Error: Filesystem creation failed.${NC}\n"
    sudo cryptsetup luksClose "$CON_ALIAS" 2>/dev/null
    sudo losetup -d "$LOSP" 2>/dev/null
    exit 1
fi
echo -e "${GREEN}✓ Filesystem created${NC}\n"

# Auto-backup header after creation (optional)
#echo -e "${YELLOW}Creating automatic header backup...${NC}"
#HEADER_BACKUP_DIR="$MYPATH/header_backup"
#sudo mkdir -p "$HEADER_BACKUP_DIR"
#HEADER_BACKUP_FILE="$HEADER_BACKUP_DIR/${CON_NAME}_header_$(date +%Y%m%d).img"
#sudo cryptsetup luksHeaderBackup "$LOSP" --header-backup-file "$HEADER_BACKUP_FILE" 2>/dev/null
#if [[ $? -eq 0 ]]; then
    #sudo chmod 600 "$HEADER_BACKUP_FILE"
    #echo -e "${GREEN}✓ Header backed up to: $HEADER_BACKUP_FILE${NC}\n"
#fi

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
    #echo -e "\n${BLUE}Container created but not mounted.${NC}"
    manual_mount_ins
    cleanup
    exit 0
fi

sudo chown -R "$USERNAME":"$USERNAME" "$MOUNT_PATH"
echo -e "${GREEN}✓ Write permissions for${NC} '$USERNAME' ${GREEN}enabled on${NC} $MOUNT_PATH${NC}\n"

SKIP_CLEANUP=1

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
