#!/usr/bin/env bash
#
# jetson-nixos-dualboot.sh – Prepare an NVIDIA Jetson Orin NX NVMe for
# a redundant NixOS installation with A/B boot and root partitions.
#
# This script partitions /dev/nvme0n1 into two UEFI boot partitions and two
# root partitions and installs the NixOS flake located at
# "github:arduano/jetpack‑nixos‑testing" for the machine named "orin".  Each
# root partition is formatted as a btrfs filesystem in DUP mode for both
# metadata and data.
#
# Assumptions:
#  • You have already flashed a UEFI firmware to the Jetson using the
#    jetpack‑nixos flashing script (see jetpack‑nixos README for details).
#    The README explains how to put the device into recovery mode, build
#    the flashing script with nix and run it to install UEFI【681624690796305†L31-L59】.
#  • You have built a jetpack‑nixos installation ISO and booted the Jetson into
#    the live NixOS environment as described in the README【681624690796305†L64-L75】.
#  • The NVMe device at /dev/nvme0n1 will be completely erased.
#  • The configuration repository github:arduano/jetpack‑nixos‑testing defines a
#    NixOS configuration called "orin".
#
# WARNING: Running this script will destroy all data on /dev/nvme0n1.
#
set -euo pipefail

DISK="/dev/nvme0n1"
HOSTNAME="orin"
FLAKE="github:arduano/jetpack-nixos-testing#${HOSTNAME}"

# Sizes for the boot partitions; adjust as needed. 512MiB is sufficient for
# systemd‑boot and multiple kernel generations.
BOOT_SIZE_MiB=512

# Ensure we have the required commands available.
for cmd in sgdisk mkfs.fat mkfs.btrfs partprobe lsblk mount umount rsync git nixos-install; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: required command $cmd not found" >&2
        exit 1
    }
done

# Confirm the user really wants to wipe the disk.
echo "This will partition and erase $DISK. Continue? [y/N]" >&2
read -r reply
case "$reply" in
    [Yy]*) ;;
    *) echo "Aborted." >&2; exit 1;;
esac

# Unmount any existing mount points on the device.
for p in $(lsblk -ln -o NAME "$DISK" | tail -n +2); do
    part="/dev/$p"
    mountpoint=$(lsblk -n -o MOUNTPOINT "$part" || true)
    if [ -n "$mountpoint" ]; then
        echo "Unmounting $part from $mountpoint"
        sudo umount -Rf "$mountpoint" || true
    fi
done

# Wipe existing partition table.
echo "Wiping existing partition table on $DISK…"
sudo sgdisk --zap-all "$DISK"
sudo sgdisk --clear "$DISK"

# Compute the disk size and determine root partition sizes.
total_bytes=$(blockdev --getsize64 "$DISK")
boot_bytes=$((BOOT_SIZE_MiB * 1024 * 1024))
# Reserve two boot partitions and a 1 GiB buffer for GPT metadata.
reserved_bytes=$((2 * boot_bytes + 1024 * 1024 * 1024))
available_bytes=$((total_bytes - reserved_bytes))
root_bytes=$((available_bytes / 2))
# Convert to MiB for sgdisk: 1 sector = 512 bytes, but sgdisk understands GiB.
root_size_MiB=$((root_bytes / 1024 / 1024))

# Create partitions:
#  1: EFI System Partition A (ESP‑A)
#  2: EFI System Partition B (ESP‑B)
#  3: Root partition A
#  4: Root partition B
# Use sgdisk to create each partition with correct type codes.
# EF00 = EFI System Partition, 8300 = Linux filesystem.

sudo sgdisk -n1:1MiB:+${BOOT_SIZE_MiB}MiB   -t1:EF00 -c1:"EFI_A" "$DISK"
sudo sgdisk -n2:0:+${BOOT_SIZE_MiB}MiB   -t2:EF00 -c2:"EFI_B" "$DISK"
sudo sgdisk -n3:0:+${root_size_MiB}MiB -t3:8300 -c3:"ROOT_A" "$DISK"
sudo sgdisk -n4:0:0          -t4:8300 -c4:"ROOT_B" "$DISK"

# Inform the kernel of partition changes.
sudo partprobe "$DISK"

# Format boot partitions as FAT32.
echo "Formatting boot partitions…"
sudo mkfs.fat -F32 -n "NIXBOOT_A" "${DISK}p1"
sudo mkfs.fat -F32 -n "NIXBOOT_B" "${DISK}p2"

# Format root partitions as btrfs with DUP mode.
echo "Formatting root partitions…"
for idx in 3 4; do
    label="NIXROOT_$( [ $idx -eq 3 ] && echo A || echo B )"
    sudo mkfs.btrfs -f -L "$label" -m dup -d dup "${DISK}p${idx}"
done

# Mount root A and perform the installation.
ROOT_A="${DISK}p3"
ROOT_B="${DISK}p4"
BOOT_A="${DISK}p1"
BOOT_B="${DISK}p2"

# Create mount points.
sudo mkdir -p /mnt
sudo mount "$ROOT_A" /mnt
sudo mkdir -p /mnt/boot
sudo mount "$BOOT_A" /mnt/boot

# Create btrfs subvolume for the root to allow sending/snapshotting later.
# This is optional but recommended.  We create @ as the root subvolume.
sudo btrfs subvolume create /mnt/@
# Unmount and remount the subvolume as the root.
sudo umount /mnt/boot
sudo umount /mnt
sudo mount -o subvol=@ "$ROOT_A" /mnt
sudo mkdir -p /mnt/boot
sudo mount "$BOOT_A" /mnt/boot

# Install NixOS using the flake.  We disable creating a root password and
# instruct NixOS to install systemd‑boot to the mounted ESP.  The flake
# provided by the user must include hardware.nvidia‑jetpack settings
# recommended by jetpack‑nixos README【681624690796305†L96-L112】.

echo "Running nixos‑install on root A…"
sudo nixos-install --flake "$FLAKE" --no-root-passwd

# Copy the boot files from ESP‑A to ESP‑B and adjust the root parameter.
echo "Copying systemd‑boot installation to second ESP…"
sudo mkdir -p /mnt2
sudo mount "$BOOT_B" /mnt2
# Copy contents of /mnt/boot to /mnt2
sudo rsync -a --delete /mnt/boot/ /mnt2/

# Update the loader entries in ESP‑B to point at the second root partition.
# Systemd‑boot stores entries in loader/entries/*.conf.  Replace the
# root=LABEL=NIXROOT_A (or specific PARTUUID) with root=LABEL=NIXROOT_B.
for entry in /mnt2/loader/entries/*.conf; do
    sudo sed -i 's/\(root=\S*\)NIXROOT_A/\1NIXROOT_B/g' "$entry"
    # Additionally replace explicit device names if present (e.g. p3 → p4).
    sudo sed -i 's/nvme0n1p3/nvme0n1p4/g' "$entry"
done

# Set loader default entry names for clarity.
echo "default  nixos-generation" | sudo tee /mnt/boot/loader/loader.conf >/dev/null
sudo cp /mnt/boot/loader/loader.conf /mnt2/loader/loader.conf

# Optional: create a custom loader entry file for the B root in the A boot
# partition, so you can manually select it from the boot menu if needed.
DEFAULT_ENTRY=$(basename /mnt/boot/loader/entries/*.conf)
ENTRY_B="${DEFAULT_ENTRY/nvme0n1p3/nvme0n1p4}"
sudo cp "/mnt/boot/loader/entries/$DEFAULT_ENTRY" "/mnt/boot/loader/entries/${ENTRY_B}"
sudo sed -i 's/NIXROOT_A/NIXROOT_B/g' "/mnt/boot/loader/entries/${ENTRY_B}"
sudo sed -i 's/nvme0n1p3/nvme0n1p4/g' "/mnt/boot/loader/entries/${ENTRY_B}"

# Sync root A into root B.  We mount root B on /mnt2 and use rsync to copy
# the filesystem.  Exclude /boot, /dev, /proc, /sys, /run, and /nix/store if
# desired.  Leaving /nix/store will duplicate the store and provide a
# completely self‑contained fallback system.
echo "Copying root filesystem to second partition… this may take a while."
sudo mount "$ROOT_B" /mnt2
sudo btrfs subvolume create /mnt2/@
sudo mount -o subvol=@ "$ROOT_B" /mnt2
sudo mkdir -p /mnt2/boot
sudo mount "$BOOT_B" /mnt2/boot
sudo rsync -aAXHv --delete \
    --exclude="/boot" \
    --exclude="/dev/*" \
    --exclude="/proc/*" \
    --exclude="/sys/*" \
    --exclude="/run/*" \
    /mnt/ /mnt2/

# Ensure fstab/mount units in the new root reference the correct partitions.
# Because NixOS uses systemd‑mount units derived from the install, we
# explicitly rewrite /mnt2/etc/fstab entries that mention ROOT_A or nvme0n1p3.
# (fstab is unused by NixOS but may be helpful for rescue.)
if [ -f /mnt2/etc/fstab ]; then
    sudo sed -i 's/NIXROOT_A/NIXROOT_B/g' /mnt2/etc/fstab
    sudo sed -i 's/nvme0n1p3/nvme0n1p4/g' /mnt2/etc/fstab
fi

# Unmount temporary mounts.
echo "Cleaning up…"
sudo umount -R /mnt2 || true
sudo umount -R /mnt || true

# Re‑enable sync operations to flush caches.
sync

echo "\nCompleted installation.  There are now two boot partitions and two"
echo "root partitions on $DISK.  ESP‑A boots into ROOT_A by default.  If"
echo "ESP‑A becomes unbootable or the kernel on ROOT_A fails, the UEFI"
echo "firmware should proceed to the next boot entry (ESP‑B) which uses"
echo "ROOT_B.  You can also manually select the entry labelled NixOS B from"
echo "the systemd‑boot menu.\n"

# Suggest adding both boot entries to UEFI using efibootmgr.
echo "You can optionally register both ESPs with UEFI using efibootmgr.  For"
echo "example:\n"
echo "  sudo efibootmgr -c -d $DISK -p 1 -L \"NixOS A\" -l '\\EFI\\systemd\\systemd-bootaa64.efi'\n"
echo "  sudo efibootmgr -c -d $DISK -p 2 -L \"NixOS B\" -l '\\EFI\\systemd\\systemd-bootaa64.efi'\n"
echo "and then adjust the BootOrder so that the ESP‑A entry is first."

