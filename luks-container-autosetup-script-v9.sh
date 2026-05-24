#!/bin/bash

# v9
# Changelog: Improved check for required packages

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

# Reset
NC='\033[0m' # No Color

# Function to cleanup open or mounted containers on error/forced exit
# (reads variable at the end of the script)
cleanup() {
    # Skip cleanup if variable has a value
    if [[ -n "$SKIP_CLEANUP" ]]; then
        return 0
    # Activate cleanup if NOT in a successful state (variable empty)
    elif [[ -z "$SKIP_CLEANUP" ]]; then
        sudo umount "$MOUNT_PATH" 2>/dev/null || true
        sudo cryptsetup luksClose "$CON_ALIAS" 2>/dev/null || true
        [[ -n "$LOSP" ]] && sudo losetup -d "$LOSP" 2>/dev/null || true
        echo -e "\n${BLUE}Script halted...cleanup completed.${NC}\n"
    fi
}

trap cleanup EXIT

# Function to check available disk space
check_disk_space() {
    local target_dir="$1"
    local required_mb="$2"

    # Get available space in MB (using df with block size 1M)
    local available_mb=$(df --output=avail -B 1M "$target_dir" | tail -n 1)
    # Add 10% buffer for filesystem overhead (LUKS header, ext4 journal, etc.)
    local buffer_mb=$((required_mb / 10))
    local total_required_mb=$((required_mb + buffer_mb))

    echo -e "\n${CYAN}Checking disk space...${NC}"
    echo -e "  Required: ${required_mb} MB"
    echo -e "  Buffer (10%): ${buffer_mb} MB"
    echo -e "  Total needed: ${total_required_mb} MB"
    echo -e "  Available: ${available_mb} MB"

    if (( available_mb < total_required_mb )); then
        echo -e "${RED}Error: Insufficient disk space!${NC}"
        echo -e "  Need: ${total_required_mb} MB"
        echo -e "  Available: ${available_mb} MB"
        echo -e "  Shortage: $((total_required_mb - available_mb)) MB"
        return 1
    else
        echo -e "${GREEN}✓ Sufficient disk space available${NC}\n"
        return 0
    fi
}

# Obtaining the original user's username & home directory using environment variables
USERNAME=${SUDO_USER:-$USER}
HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)

echo -e "\n${YELLOW}═════════════════════════════════════════════════════════${NC}\n"
echo -e "${YELLOW}  Simple bash script to create & mount LUKS containers${NC}"
echo -e "\nEncrypted block devices (partitions) are not supported,"
echo -e "only LUKS file containers / images with .bin extension."
echo -e "\nScript can work with multiple LUKS file containers.\n"
echo -e "${YELLOW}═════════════════════════════════════════════════════════${NC}\n"

# Check for required packages on system
echo -e "${BLUE}Checking if required packages are installed...${NC}\n"
if ! command -v cryptsetup || ! command -v bc &> /dev/null; then
    sudo apt install cryptsetup bc e2fsprogs -y 2>/dev/null
    echo -e "\n${GREEN}✓ Installed. Ready to proceed.${NC}\n"
fi

# Set container name and alias
read -p "Create a name for your LUKS container: " CON_NAME
if [[ ! "$CON_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}Error:${NC} Container name contains invalid characters. Use only letters, numbers, hyphens, and underscores."
    exit 1
fi
echo -e "\n${CYAN}$CON_NAME.bin${NC} set.\n"
echo -e "Create an alias to identify the working LUKS container. Avoid names with empty spaces. Use hyphens or underscores for multiple words"
read -p "(eg. company-records or cloud_archive): " CON_ALIAS
while [[ -z "$CON_ALIAS" ]]; do
    echo -e "${RED}Error:${NC} No alias set. Type a simple name."
    read -p "Create alias: " CON_ALIAS
done
if [[ ! "$CON_ALIAS" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo -e "${RED}Error:${NC} Alias contains invalid characters. Use only letters, numbers, hyphens, and underscores."
    exit 1
fi
echo -e "\n${CYAN}$CON_ALIAS${NC} alias set for $CON_NAME.bin\n"

# Set container path
read -p "Type the LUKS container storage path (use full path): " SOURCED
read -p "Is $SOURCED correct? [y/n] " RESP1
echo
if [[ "${RESP1,,}" != "y" ]]; then
    echo -e "${BLUE}Script will exit.${NC}\n"
    exit 0
fi

# Validation checks
if [[ ! -d "$SOURCED" ]]; then
    echo -e "${RED}Error:${NC} Directory '$SOURCED' does not exist. Script will exit.\n"
    exit 1
elif [[ -f "$SOURCED/$CON_NAME.bin" ]]; then
    echo -e "${RED}Warning:${NC} Existing LUKS container already found. Either delete or rename '$CON_NAME' to continue. Script will exit.\n"
    exit 1
elif sudo cryptsetup status "$CON_ALIAS" &>/dev/null; then
	echo -e "${RED}Warning:${NC} LUKS container alias '$CON_ALIAS' already exists & is in use. Either use a different name or unmount existing container."
	exit 1
else
    MYPATH=${SOURCED}
fi

# Set LUKS container size
echo
read -p "Type in the size of the LUKS container in MB (100 MB min size): " CON_SIZE1
if ! [[ "$CON_SIZE1" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error:${NC} Numerical values only. Script will exit.\n"
    exit 1
fi
if (( CON_SIZE1 < 100 )); then
    echo -e "${RED}Error:${NC} Minimum size is 100 MB. Script will exit.\n"
    exit 1
fi
if ! check_disk_space "$MYPATH" "$CON_SIZE1"; then
    echo -e "${RED}Script will exit due to insufficient disk space.${NC}\n"
    exit 1
fi
read -p "Is $CON_SIZE1 MB correct? [y/n] " RESP2
if [[ "${RESP2,,}" != "y" ]]; then
    echo -e "${BLUE}\nLUKS container won't be created. Script will exit.${NC}\n"
    exit 0
else
    echo -e "\n${YELLOW}Note:${NC} LUKS container file size uses base-10 numbers. Final container size will be smaller when measured in GB (eg. 1 GB = 1024 MB).\n"
	# Show size in GB if large enough (can uncomment out if unecessary)
    if (( CON_SIZE1 >= 1024 )); then
        CALC=$(echo "scale=2; $CON_SIZE1 / 1024" | bc)
        echo -e "  ${CYAN}Info:${NC} $CON_SIZE1 MB ≈ ${CALC} GB\n"
    fi
fi

# Function to create LUKS container
create_con() {
    echo -e "${BLUE}Creating LUKS container file...${NC}"
    sudo dd if=/dev/urandom of="$MYPATH/$CON_NAME.bin" bs=1M count="$CON_SIZE1" status=progress
}

# Execute create container function
create_con
echo -e "${GREEN}✓ $CON_NAME.bin created in: $MYPATH${NC}"
sleep 2

LOSP=$(sudo losetup -f --show "$MYPATH/$CON_NAME.bin" 2>/dev/null)

if [[ $? -ne 0 ]] || [[ -z "$LOSP" ]]; then
    echo "Failed to get loop device"
    exit 1
fi

# Open & create ext4 filesystem in LUKS container (modify filesystem if required)
echo -e "Setting up LUKS encryption..."
sudo cryptsetup luksFormat "$LOSP"
echo -e "${GREEN}✓ LUKS container formatted${NC}"
sleep 2
echo -e "Opening LUKS container..."
sudo cryptsetup luksOpen "$LOSP" "$CON_ALIAS"
echo -e "${GREEN}✓ Container opened as${NC} /dev/mapper/$CON_ALIAS"
echo -e "Creating ext4 filesystem..."
sudo mkfs.ext4 -F "/dev/mapper/$CON_ALIAS"
echo -e "${GREEN}✓ Filesystem created${NC}"

# Instructions for manual mount function
manual_mount_ins() {
echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}To open, mount, & set write permissions on dir:${NC}"
echo -e "  sudo losetup -f --show </path/to/container.bin>"
echo -e "  sudo cryptsetup luksOpen <loop-num> <container-alias>"
echo -e "  sudo mount /dev/mapper/<loop-num> <mount-dir>"
echo -e "  sudo chown -R <username>:<username> <mount-dir>"
echo -e "\n${YELLOW}To unmount, close, & detatch:${NC}"
echo -e "  sudo umount <mount-dir>"
echo -e "  sudo cryptsetup luksClose <container-alias>"
echo -e "  sudo losetup -d <loop-num>"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}\n"
}


# Mount LUKS container
read -p "Do you want to mount the LUKS container? [y/n] " RESP3
if [[ "${RESP3,,}" = "y" ]]; then
    read -p "Where do you want to mount the LUKS container? Type the mount path (use full path): " MOUNT_PATH
    if [[ -d "$MOUNT_PATH" ]]; then
        sudo mount "/dev/mapper/$CON_ALIAS" "$MOUNT_PATH"
        echo -e "${GREEN}✓ LUKS container mounted to${NC} $MOUNT_PATH"
    elif [[ ! -d "$MOUNT_PATH" ]]; then
        echo -e "${RED}Error:${NC} Cannot find the specified path $MOUNT_PATH."
        read -p "Would you like to create the directory? [y/n] " RESP4
        if [[ "${RESP4,,}" = "y" ]]; then
            sudo mkdir -p "$MOUNT_PATH"
            sudo mount "/dev/mapper/$CON_ALIAS" "$MOUNT_PATH"
            echo -e "${GREEN}✓ LUKS container mounted to${NC} $MOUNT_PATH"
        else
            echo -e "${BLUE}\nLUKS container won't be mounted.${NC} Mount manually & set proper dir ownership."
            manual_mount_ins
            exit 0
        fi
    fi
else
    echo -e "\n${BLUE}Container created but not mounted.${NC} Mount manually & set proper dir ownership."
    manual_mount_ins
    exit 0
fi

# Set proper ownership on mount dir
sudo chown -R "$USERNAME":"$USERNAME" "$MOUNT_PATH"
echo -e "${GREEN}✓ Write permission for${NC} $USERNAME ${GREEN}enabled on${NC} $MOUNT_PATH${NC}"

# Flag to prevent cleanup on normal exit (only activates cleanup function if empty)
SKIP_CLEANUP=1

# Display summary with unmount instructions
echo -e "\n${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ LUKS container successfully created and mounted!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "  Container file: ${CYAN}$MYPATH/$CON_NAME.bin${NC}"
echo -e "  Mount point:    ${CYAN}$MOUNT_PATH${NC}"
echo -e "  Mapper name:    ${CYAN}$CON_ALIAS${NC}"
echo -e "  Size:           ${CYAN}$CON_SIZE1 MB${NC}"
echo -e "\n${YELLOW}To unmount and close:${NC}"
echo -e "  sudo umount $MOUNT_PATH"
echo -e "  sudo cryptsetup luksClose $CON_ALIAS"
echo -e "  sudo losetup -d $LOSP"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}\n"
