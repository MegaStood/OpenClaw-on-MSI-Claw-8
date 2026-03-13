# Troubleshooting

Common issues and fixes for Nobara on the MSI Claw 8 AI+.

## Installation Issues

### Nobara installer can't see the NVMe SSD
Go to BIOS → Advanced → look for VMD (Volume Management Device). Disable it. Reboot into installer.

### USB won't boot on the Claw
- Verify Ventoy was installed with GPT mode (`-g` flag). MBR will not work.
- Ensure Secure Boot is disabled in BIOS.
- Check boot order: BIOS → Boot → Fixed Boot Order Priorities → USB Hard Disk must be above Hard Disk for installation.
- Use LB+RB at power on for boot menu, not RB+RT (that's BIOS).

### Black screen after selecting Nobara in Ventoy
At GRUB menu, press `e`, find the `linuxefi` line, add `nomodeset` at the end, press Ctrl+X.

### BitLocker recovery screen after disabling Secure Boot
Enter your 48-digit recovery key. If you don't have it, re-enable Secure Boot in BIOS, boot Windows, and retrieve it: `manage-bde -protectors -get C:` (admin CMD).

## Boot Issues

### GRUB doesn't appear / boots straight to Windows
Enter BIOS (RB+RT) → Boot → **UEFI Hard Disk Drive BBS Priorities** → set Boot Option #1 to **Fedora (your M.2 disk name)**. This tells the BIOS which bootloader to use on the internal drive. Also check Fixed Boot Order Priorities has Hard Disk as #1.

### First boot takes 10+ minutes with black screen
Normal for first boot. The Steam logo may appear twice. Wait patiently. If it hasn't booted after 15 minutes, force shutdown (hold power 10s) and try again.

### Boot asks to choose between Windows, bootx64.efi, or xorboot
Select **bootx64.efi** — that's GRUB.

## Hardware Issues

### No sound
Check BIOS → Advanced for any "Linux Audio Compatibility" option — if it exists, set to **Linux**. (Note: this option exists on the Claw A1M but may not be present on the Claw 8 AI+ BIOS.)

If no BIOS option exists or it's already set:
```bash
sudo dnf install pipewire-alsa pipewire-pulseaudio
systemctl --user restart pipewire
```

### Joystick/controller not working
Ensure HHD is installed and InputPlumber is masked:
```bash
# Check HHD is installed
ls ~/.local/bin/hhd

# Check InputPlumber is masked
systemctl status inputplumber.service  # Should show "masked"

# Check HHD is running
systemctl status hhd_local@youruser.service
```

If HHD isn't installed, run the post-install script or install manually:
```bash
sudo systemctl mask inputplumber.service
curl -L https://github.com/hhd-dev/hhd/raw/master/install.sh | bash
sudo reboot
```

### WiFi dies after sleep
The post-install script installs two fixes. If WiFi still drops:

Check which fix is active:
```bash
systemctl status fix-wifi-sleep.service   # Method A: D3Cold
systemctl status wifi-resume.service      # Method B: module reload
```

Check WiFi driver logs:
```bash
journalctl -b | grep iwlwifi
```

Manual workaround after a failed wake:
```bash
sudo modprobe -r iwlmvm iwlwifi && sudo modprobe iwlwifi
```

If nothing works, disable both and try just the module reload:
```bash
sudo systemctl disable fix-wifi-sleep.service
sudo systemctl enable wifi-resume.service
sudo reboot
```

### Sleep/wake hangs (device won't wake up)
This is a known kernel issue on Lunar Lake. Mitigations:
- Keep kernel updated (`sudo nobara-sync cli`)
- Avoid hibernate (the script disables it)
- Use suspend for short breaks, full shutdown for switching to Windows

### Screen is rotated
The Claw 8 AI+ has a native landscape display, so this shouldn't happen. If it does:
```bash
xrandr --output eDP-1 --rotate normal
```

## GPU Issues

### Ollama says "CPU-only mode" / doesn't detect GPU
Expected — Ollama only auto-detects NVIDIA (CUDA) and AMD (ROCm). Enable Vulkan manually:
```bash
sudo systemctl edit ollama
# Add:
# [Service]
# Environment="OLLAMA_VULKAN=1"
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

### Vulkan inference is slower than CPU
Known issue on some Intel iGPUs. Revert to CPU:
```bash
sudo systemctl revert ollama
sudo systemctl daemon-reload
sudo systemctl restart ollama
```

### Check which GPU driver is active
```bash
lspci -k | grep -EA3 'VGA|3D|Display'
# Look for "Kernel driver in use: xe" (preferred) or "i915"
```

### Switch from i915 to xe driver
```bash
# Find your GPU device ID
lspci -nnd ::03xx  # Note the hex ID after 8086:

# Apply (replace XXXX with your ID, e.g., 64a0)
sudo grubby --update-kernel=ALL --args='i915.force_probe=!XXXX xe.force_probe=XXXX'
sudo reboot
```

### Revert from xe to i915
From GRUB menu: press `e`, delete the `i915.force_probe` and `xe.force_probe` parts, press Ctrl+X. Then permanently:
```bash
sudo grubby --update-kernel=ALL --remove-args='i915.force_probe=!XXXX xe.force_probe=XXXX'
```

## Software Issues

### System update fails
Always use Nobara's own updater, not raw `dnf`:
```bash
sudo nobara-sync cli
```

### Post-install script re-downloads HHD every time
The HHD check uses the file path `/home/youruser/.local/bin/hhd`. If your username is different from what the script expects, it won't find HHD. Check:
```bash
ls ~/.local/bin/hhd
```

### Proton-GE download is extremely slow
Cancel and retry later. It's not required for the base system — only needed for Windows game compatibility through Steam. Install from the Nobara Welcome App when convenient.

## Reverting to Windows-Only

If you decide you no longer need the dual boot setup:

1. Enter BIOS → re-enable Secure Boot (if BitLocker was kept on)
2. Boot Windows
3. Open Disk Management → delete Linux partitions (boot + Nobara)
4. Expand C: back to full size
5. GRUB disappears automatically
