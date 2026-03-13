# Installation Guide

Step-by-step dual boot installation of Nobara Steam-Handheld on the MSI Claw 8 AI+ alongside Windows 11.

## What You Need

- USB-C hub (Claw only has Thunderbolt 4 USB-C ports)
- USB keyboard and mouse
- USB stick (at least 8GB)
- [Ventoy](https://ventoy.net) for bootable USB creation
- [Nobara Steam-Handheld ISO](https://nobaraproject.org/download.html) (the AMD/Intel version, NOT NVIDIA)
- A backup of anything important on the Claw

## Phase 1: Prepare on Windows

### 1.1 Update BIOS

Download the latest BIOS from [MSI Support](https://www.msi.com/Handheld/Claw-8-AI-Plus-A2VMX/support). Follow MSI's instructions.

### 1.2 Handle BitLocker

**Check if BitLocker is active:** Settings → Privacy & Security → Device Encryption.

If enabled (it is by default), you have two choices:

**Option A (Recommended): Decrypt first**
1. Turn off Device Encryption in Settings
2. Wait 30-60 minutes for full decryption
3. Then proceed to disable Secure Boot

**Option B: Keep BitLocker**
1. Open admin Command Prompt: `manage-bde -protectors -get C:`
2. Write down the 48-digit recovery key on paper
3. Accept typing it every time you boot Windows after Secure Boot is disabled

### 1.3 Disable Fast Startup

Control Panel → Power Options → "Choose what the power buttons do" → Uncheck "Turn on fast startup". This prevents disk corruption between OSes.

### 1.4 Shrink the Windows Partition

Open Disk Management (Win+X → Disk Management). Right-click C: → Shrink Volume → enter at least 150000 MB (~150GB). More is better if storing LLM models.

If Windows won't shrink enough:
```cmd
defrag C: /O
powercfg /h off
```

## Phase 2: Create Bootable USB

### Using Ventoy (Recommended)

On a Linux machine:
```bash
wget https://github.com/ventoy/Ventoy/releases/latest/download/ventoy-*-linux.tar.gz
tar -xzf ventoy-*-linux.tar.gz
cd ventoy-*

# Find your USB device
lsblk

# Install with GPT mode (MBR will NOT work on the Claw)
sudo bash Ventoy2Disk.sh -i -g /dev/sdX
```

**Important:** Ventoy must use **GPT** (`-g` flag). MBR will not boot on the Claw's UEFI firmware.

Copy the Nobara ISO:
```bash
rsync -ah --progress ~/Downloads/Nobara-Steam-Handheld-*.iso /media/youruser/Ventoy/
sync  # Wait for this to complete before unplugging!
```

The `sync` command forces cached writes to the USB. On a typical USB stick, this may take several minutes for a ~5-8GB ISO. Don't unplug until your prompt returns.

## Phase 3: BIOS Configuration

### Enter BIOS
Press **RB + RT** (right bumper + right trigger) while powering on. Connect USB-C hub with keyboard.

### Required Changes

**Disable Secure Boot:**
Security → Secure Boot → Secure Boot Support → **Disabled**

**Set Boot Order for USB Installation:**
Boot → Fixed Boot Order Priorities → set:
- Boot Option #1: **USB Hard Disk** (this is where Ventoy will be)
- Boot Option #2: **Hard Disk** (Windows Boot Manager / Fedora after install)

Without this, the Claw may skip the USB and boot straight to the internal drive.

**Check for Linux Audio Compatibility (may not exist):**
Navigate to Advanced and look for "Linux Audio Compatibility." If it exists, set it to **Linux**. The Claw A1M has this option, but the Claw 8 AI+ BIOS may not include it. If you don't see it, don't worry — sound should work without it on Lunar Lake.

**Check VMD (Volume Management Device):**
If the Nobara installer later cannot see your NVMe SSD, come back to Advanced and look for VMD — disable it if found.

### What NOT to Change

Unlike the A1M guide, do **not** change:
- Core counts or P/E core ratios
- SpeedStep/SpeedShift settings
- Modern Standby settings
- Overclocking Lock

Leave everything else at defaults. Optimize only after the system is stable.

Save with **F10** and exit.

## Phase 4: Install Nobara

### Boot from USB
Plug in USB via hub. Power on while holding **LB + RB** (left bumper + right bumper) for boot menu. Select USB stick.

If the USB doesn't appear in the boot menu, enter BIOS (RB+RT) → Boot → Fixed Boot Order Priorities and set USB Hard Disk as Boot Option #1 above Hard Disk. Save and reboot.

Ventoy shows a menu — select the Nobara ISO, then "Boot in normal mode."

### If Boot Fails
At GRUB menu, press `e`, find the `linuxefi` line, add `nomodeset` at the end, press Ctrl+X. This forces basic graphics mode.

### KDE Wallet Prompt
When connecting to WiFi, KDE asks to create a wallet. Choose **classic blowfish**, set a password or leave blank for auto-unlock.

### Partitioning

Select **"Replace a partition"** with **btrfs** selected. The installer will:
- Use the free space you created
- Auto-create a 2GB ext4 `/boot` partition
- Create a btrfs root partition from the remaining space
- Share the existing EFI partition (300MB) with Windows

Confirm that:
- The Windows (BitLocker) partition is **untouched**
- The EFI partition at `/dev/nvme0n1p1` is listed for use but **not formatted**

Click Install. Wait 10-20 minutes.

### After Installation

Reboot. Remove USB. GRUB should appear with Nobara and Windows Boot Manager.

If it boots straight to Windows, enter BIOS (RB+RT) and set two things:

1. **Boot → UEFI Hard Disk Drive BBS Priorities:**
   - Boot Option #1: **Fedora (your M.2 disk name, e.g., Micron_2500...)** — this is GRUB
   - Boot Option #2: **Windows Boot Manager**

2. **Boot → Fixed Boot Order Priorities:**
   - Boot Option #1: **Hard Disk** (now contains Fedora/GRUB)
   - Boot Option #2: **USB Hard Disk** (no longer needed first)

The BBS Priorities setting tells the BIOS which bootloader to use on the internal drive. Without setting Fedora first here, the BIOS will skip GRUB and boot Windows directly.

## Phase 5: Post-Install Configuration

### First Boot
First boot may take several minutes with a black screen and Steam logo. Be patient.

Nobara boots into **Steam Gaming Mode** by default. This is correct — it's the SteamOS-like handheld interface.

### Switch to Desktop Mode
The joystick won't work until HHD is installed. Use the **touchscreen** to tap Menu (bottom left) → Power → Switch to Desktop.

### Run the Post-Install Script

Transfer the script via USB, SCP, or SSH:
```bash
# Enable SSH first (from Desktop Mode terminal)
sudo systemctl enable --now sshd

# From your other machine
scp claw8-post-install.sh youruser@CLAW_IP:~/
ssh youruser@CLAW_IP

# Run it
chmod +x claw8-post-install.sh
sudo bash claw8-post-install.sh
```

The script handles: system update, GPU driver check, controller setup (HHD), WiFi sleep fix, hibernate disable, and optional AI tools (Ollama/OpenClaw).

### Reboot and Verify

After the script completes, reboot and test:

- [ ] Joystick works in Desktop Mode and Gaming Mode
- [ ] Sound plays through speakers
- [ ] WiFi stays connected after sleep/wake
- [ ] Touchscreen responds
- [ ] Steam launches and games run
- [ ] Back buttons programmable via Steam Input
- [ ] Windows still accessible via GRUB

## Phase 6: Optional — Enable Vulkan GPU Acceleration for Ollama

Ollama defaults to CPU-only on Intel Arc. To try Vulkan:

```bash
sudo systemctl edit ollama
```

Add:
```ini
[Service]
Environment="OLLAMA_VULKAN=1"
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl restart ollama
ollama ps  # Should show Vulkan backend
```

If inference is slower or produces garbage, revert:
```bash
sudo systemctl revert ollama
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

## Phase 7: Optional — OpenClaw Setup

```bash
ollama launch openclaw
```

Ollama 0.17+ handles OpenClaw installation automatically. Select a model when prompted.

For remote server (vLLM on another machine):
Edit `~/.openclaw/openclaw.json` — see the [README](../README.md#openclaw--remote-server-setup) for the config template.

## Reverting to Windows-Only

If you decide you no longer need the dual boot setup and want to reclaim the disk space for Windows:

1. Enter BIOS → re-enable Secure Boot (if BitLocker was kept on)
2. Boot Windows
3. Delete Linux partitions (boot + Nobara) in Disk Management
4. Expand C: back to full size
5. GRUB will disappear once the Linux boot partition is gone

No Windows recovery USB needed — the BIOS falls through to Windows Boot Manager automatically when Fedora/GRUB is gone.
