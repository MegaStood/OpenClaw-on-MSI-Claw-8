#!/bin/bash
# ============================================================
# Create Nobara Steam-Handheld Bootable USB (Ventoy + ISO)
# For MSI Claw 8 AI+ (Lunar Lake) — UEFI/GPT only
#
# Usage: sudo bash create-nobara-usb.sh
# ============================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

NOBARA_DL_PAGE="https://nobaraproject.org/download.html"
VENTOY_RELEASES="https://github.com/ventoy/Ventoy/releases/latest"
WORK_DIR="/tmp/nobara-usb-creator"

# ============================================================
# Pre-flight checks
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run with sudo: sudo bash create-nobara-usb.sh${NC}"
    exit 1
fi

REAL_USER=${SUDO_USER:-$USER}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Nobara Steam-Handheld USB Creator${NC}"
echo -e "${GREEN} For MSI Claw 8 AI+ (Lunar Lake)${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ============================================================
# Resolve latest Steam-Handheld ISO URL from download page
# ============================================================
echo -e "${YELLOW}Detecting latest Nobara Steam-Handheld ISO...${NC}"
ISO_URL=$(curl -sL "$NOBARA_DL_PAGE" | grep -oP 'https://nobara-images\.nobaraproject\.org/Nobara-[0-9]+-Steam-Handheld-[0-9-]+\.iso' | head -1)

if [ -z "$ISO_URL" ]; then
    echo -e "${RED}  Could not find Steam-Handheld ISO URL on $NOBARA_DL_PAGE${NC}"
    echo "  Check the page manually and update the script."
    exit 1
fi

ISO_NAME=$(basename "$ISO_URL")
echo -e "${GREEN}  Found: $ISO_NAME${NC}"
echo ""

# ============================================================
# Step 1: Detect USB devices
# ============================================================
echo -e "${YELLOW}[1/4] Detecting USB devices...${NC}"

# Find USB block devices (exclude internal drives)
mapfile -t USB_DEVS < <(lsblk -dnpo NAME,TRAN,SIZE,MODEL | grep 'usb' | awk '{print $1}')

if [ ${#USB_DEVS[@]} -eq 0 ]; then
    echo -e "${RED}  No USB devices found. Plug in a USB stick and try again.${NC}"
    exit 1
fi

echo ""
echo "  Available USB devices:"
echo "  ─────────────────────────────────────────────────────"
for i in "${!USB_DEVS[@]}"; do
    DEV="${USB_DEVS[$i]}"
    INFO=$(lsblk -dno SIZE,MODEL "$DEV" 2>/dev/null)
    echo -e "  ${CYAN}$((i+1)))${NC} $DEV  [$INFO]"
done
echo ""

if [ ${#USB_DEVS[@]} -eq 1 ]; then
    USB_DEV="${USB_DEVS[0]}"
    echo -e "  Auto-selected: ${CYAN}$USB_DEV${NC}"
else
    read -p "  Select USB device (1-${#USB_DEVS[@]}): " USB_CHOICE
    if ! [[ "$USB_CHOICE" =~ ^[0-9]+$ ]] || [ "$USB_CHOICE" -lt 1 ] || [ "$USB_CHOICE" -gt ${#USB_DEVS[@]} ]; then
        echo -e "${RED}  Invalid selection.${NC}"
        exit 1
    fi
    USB_DEV="${USB_DEVS[$((USB_CHOICE-1))]}"
fi

USB_SIZE=$(lsblk -dno SIZE "$USB_DEV")
USB_MODEL=$(lsblk -dno MODEL "$USB_DEV")

echo ""
echo "  Selected: $USB_DEV ($USB_MODEL, $USB_SIZE)"
echo "  Ventoy will ask for confirmation before writing to the disk."

# ============================================================
# Step 2/3: Check Ventoy — install only if needed
# ============================================================
echo ""
echo -e "${YELLOW}[2/4] Checking Ventoy on $USB_DEV...${NC}"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

VENTOY_PART="${USB_DEV}1"

# Check if Ventoy is already installed by looking for its second (EFI) partition
VENTOY_INSTALLED=0
if [ -b "${USB_DEV}2" ]; then
    PART2_FSTYPE=$(blkid -s TYPE -o value "${USB_DEV}2" 2>/dev/null || true)
    if [ "$PART2_FSTYPE" = "vfat" ] && [ -b "$VENTOY_PART" ]; then
        # Ventoy creates a small FAT EFI partition as sda2 — if it exists, Ventoy is installed
        VENTOY_INSTALLED=1
    fi
fi

if [ "$VENTOY_INSTALLED" = "1" ]; then
    echo -e "${GREEN}  Ventoy already installed on $USB_DEV. Skipping install.${NC}"
else
    echo "  Ventoy not detected. Installing..."

    # Unmount partitions and release device before Ventoy writes to raw disk
    echo "  Unmounting USB partitions..."
    fuser -km "$USB_DEV"* 2>/dev/null || true
    sleep 1

    for part in $(lsblk -lnpo NAME "$USB_DEV" | tail -n +2); do
        MPOINT=$(lsblk -lno MOUNTPOINT "$part" 2>/dev/null || true)
        if [ -n "$MPOINT" ]; then
            echo "  Unmounting $part ($MPOINT)..."
            umount "$part" 2>/dev/null || umount -l "$part" 2>/dev/null || true
        fi
    done

    # Prevent desktop auto-remounting during Ventoy install
    systemctl stop udisks2.service 2>/dev/null || true
    UDISKS_STOPPED=1

    # Resolve latest Ventoy version and download
    VENTOY_TAG=$(curl -sI "$VENTOY_RELEASES" | grep -i location | grep -oP 'v[\d.]+' | head -1)
    if [ -z "$VENTOY_TAG" ]; then
        echo -e "${RED}  Could not detect latest Ventoy version.${NC}"
        exit 1
    fi
    # Tag is "v1.1.10" but filename uses "1.1.10" (no v prefix)
    VENTOY_VER="${VENTOY_TAG#v}"
    VENTOY_TAR="ventoy-${VENTOY_VER}-linux.tar.gz"
    VENTOY_DL="https://github.com/ventoy/Ventoy/releases/download/${VENTOY_TAG}/${VENTOY_TAR}"

    echo "  Latest Ventoy: $VENTOY_VER"
    if [ -f "$VENTOY_TAR" ]; then
        echo "  Using cached $VENTOY_TAR"
    else
        echo "  Downloading $VENTOY_TAR ..."
        wget -q --show-progress "$VENTOY_DL"
    fi

    # Extract
    echo "  Extracting..."
    tar -xzf "$VENTOY_TAR"
    cd ventoy-*/

    # Install Ventoy in GPT mode (-i = initial install, -g = GPT)
    echo "  Installing Ventoy to $USB_DEV (GPT mode)..."
    bash Ventoy2Disk.sh -i -g "$USB_DEV"

    if [ $? -ne 0 ]; then
        echo -e "${RED}  Ventoy installation failed. Check errors above.${NC}"
        exit 1
    fi

    echo -e "${GREEN}  Ventoy installed successfully.${NC}"

    # Wait for partition to appear
    echo "  Waiting for Ventoy partition to appear..."
    sleep 2
    partprobe "$USB_DEV" 2>/dev/null || true
    sleep 2

    # Re-read partition table if partitions haven't appeared
    for i in 1 2 3 4 5; do
        if [ -b "$VENTOY_PART" ]; then
            break
        fi
        echo "  Waiting for $VENTOY_PART... (attempt $i/5)"
        blockdev --rereadpt "$USB_DEV" 2>/dev/null || true
        udevadm settle --timeout=5 2>/dev/null || true
        sleep 2
    done

    if [ ! -b "$VENTOY_PART" ]; then
        echo -e "${RED}  Ventoy partition $VENTOY_PART not found after 5 attempts.${NC}"
        echo "  Try: sudo partprobe $USB_DEV && lsblk $USB_DEV"
        exit 1
    fi
fi

# Restart udisks2 if we stopped it
if [ "${UDISKS_STOPPED:-0}" = "1" ]; then
    systemctl start udisks2.service 2>/dev/null || true
fi

# Mount the Ventoy partition (use existing mount point if already mounted)
EXISTING_MOUNT=$(lsblk -lno MOUNTPOINT "$VENTOY_PART" 2>/dev/null || true)
if [ -n "$EXISTING_MOUNT" ]; then
    MOUNT_DIR="$EXISTING_MOUNT"
    echo -e "${GREEN}  Already mounted at $MOUNT_DIR${NC}"
else
    MOUNT_DIR="/mnt/ventoy-usb"
    mkdir -p "$MOUNT_DIR"
    mount "$VENTOY_PART" "$MOUNT_DIR"
    echo -e "${GREEN}  Mounted $VENTOY_PART at $MOUNT_DIR${NC}"
fi

# ============================================================
# Step 4: Download the Nobara Steam-Handheld ISO
# ============================================================
echo ""
echo -e "${YELLOW}[3/4] Preparing Nobara Steam-Handheld ISO...${NC}"

# Check available space on USB
USB_FREE_KB=$(df --output=avail "$MOUNT_DIR" | tail -1)
USB_FREE_GB=$((USB_FREE_KB / 1024 / 1024))
echo "  Available space on USB: ${USB_FREE_GB}GB"

if [ "$USB_FREE_GB" -lt 6 ]; then
    echo -e "${RED}  Warning: Less than 6GB free. The ISO may not fit.${NC}"
    read -p "  Continue anyway? (y/n): " CONTINUE
    if [ "$CONTINUE" != "y" ] && [ "$CONTINUE" != "Y" ]; then
        umount "$MOUNT_DIR"
        exit 0
    fi
fi

# Check if ISO already exists on USB
ISO_USB_PATH="$MOUNT_DIR/$ISO_NAME"
if [ -f "$ISO_USB_PATH" ]; then
    echo -e "${GREEN}  ISO already exists on USB. Skipping.${NC}"
else
    # Search common locations for existing ISO before downloading
    ISO_FOUND=""
    REAL_HOME=$(eval echo ~"$REAL_USER")
    SEARCH_DIRS=("$WORK_DIR" "$REAL_HOME/Downloads" "$REAL_HOME" "/tmp" "/shared")
    echo "  Searching for existing $ISO_NAME ..."
    for dir in "${SEARCH_DIRS[@]}"; do
        MATCH=$(find "$dir" -maxdepth 2 -name "Nobara-*-Steam-Handheld-*.iso" -type f 2>/dev/null | head -1)
        if [ -n "$MATCH" ]; then
            ISO_FOUND="$MATCH"
            break
        fi
    done

    if [ -n "$ISO_FOUND" ]; then
        ISO_SIZE_FOUND=$(du -h "$ISO_FOUND" | cut -f1)
        echo -e "${GREEN}  Found existing ISO: $ISO_FOUND ($ISO_SIZE_FOUND)${NC}"
        echo "  Copying to USB..."
        rsync -ah --progress --no-owner --no-group --no-perms "$ISO_FOUND" "$MOUNT_DIR/$ISO_NAME"
    else
        echo "  No existing ISO found. Downloading..."
        echo "  URL: $ISO_URL"
        echo "  This is a large file (~5-8GB). Please be patient."
        echo ""

        # Download to work dir (resume support if interrupted)
        ISO_DL_PATH="$WORK_DIR/$ISO_NAME"
        wget -c --show-progress -O "$ISO_DL_PATH" "$ISO_URL"

        if [ $? -ne 0 ]; then
            echo -e "${RED}  Download failed. Check your internet connection.${NC}"
            umount "$MOUNT_DIR"
            exit 1
        fi

        # Copy to USB with progress
        echo ""
        echo "  Copying ISO to USB..."
        rsync -ah --progress --no-owner --no-group --no-perms "$ISO_DL_PATH" "$MOUNT_DIR/"
    fi
fi

echo -e "${GREEN}  ISO ready on USB.${NC}"

# ============================================================
# Step 5: Sync and finalize
# ============================================================
echo ""
echo -e "${YELLOW}[4/4] Syncing data to USB (do NOT unplug!)...${NC}"
echo "  This may take a few minutes for large files..."
sync

# Verify the ISO on USB
ISO_SIZE=$(du -h "$ISO_USB_PATH" | cut -f1)
echo -e "${GREEN}  ISO on USB: $ISO_NAME ($ISO_SIZE)${NC}"

# Only unmount if we mounted it ourselves (not if desktop auto-mounted)
if [ "$MOUNT_DIR" = "/mnt/ventoy-usb" ]; then
    umount "$MOUNT_DIR" 2>/dev/null || true
    rmdir "$MOUNT_DIR" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} USB Install Media Ready!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Device:  $USB_DEV ($USB_MODEL, $USB_SIZE)"
echo "  Ventoy:  GPT mode (UEFI compatible)"
echo "  ISO:     $ISO_NAME ($ISO_SIZE)"
echo ""
echo -e "${CYAN}  Next steps:${NC}"
echo "  1. Safely eject the USB stick"
echo "  2. Plug into MSI Claw 8 via USB-C hub"
echo "  3. Power on while holding LB+RB for boot menu"
echo "  4. Select the USB stick"
echo "  5. Ventoy will show the Nobara ISO — select it"
echo "  6. Choose 'Boot in normal mode'"
echo ""
echo -e "${YELLOW}  If USB doesn't appear in boot menu:${NC}"
echo "  Enter BIOS (RB+RT on power-on) → Boot →"
echo "  Fixed Boot Order → set USB Hard Disk as #1"
echo ""
echo -e "${GREEN}  You can safely unplug the USB now.${NC}"

# Cleanup work dir (keep cached files for re-runs)
# rm -rf "$WORK_DIR"
