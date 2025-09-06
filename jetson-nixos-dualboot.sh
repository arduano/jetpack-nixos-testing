#!/usr/bin/env bash
#
# jetson-nixos-dualboot.sh – Prepare an NVIDIA Jetson Orin NX NVMe for
# a redundant NixOS installation with A/B boot and root partitions.
#
# This script partitions /dev/nvme0n1 into two UEFI boot partitions and two
# root partitions and installs two distinct NixOS configurations (one per
# slot) from a flake.  Each root partition is formatted as a btrfs
# filesystem in DUP mode for both metadata and data.
#
# Assumptions:
#  • You have already flashed a UEFI firmware to the Jetson using the
#    jetpack‑nixos flashing script.  The README explains how to put the
#    device into recovery mode, build the flashing script with nix and run
#    it to install UEFI【681624690796305†L31-L59】.
#  • You have built a jetpack‑nixos installation ISO and booted the Jetson
#    into the live NixOS environment as described in the README【681624690796305†L64-L75】.
#  • The NVMe device at /dev/nvme0n1 will be completely erased.
#  • Your flake defines two nixosConfigurations with different hostnames
#    (e.g. `orin-a` and `orin-b`) that you wish to install on slot A and
#    slot B respectively.
#
# WARNING: Running this script will destroy all data on /dev/nvme0n1.

set -euo pipefail

# NVMe device to partition and install onto.
DISK="/dev/nvme0n1"

# Define separate hostnames / flake targets for the two slots.  Update
# these to match the outputs in your flake.  For example, if your
# `flake.nix` defines `nixosConfigurations.orin-a` and `nixosConfigurations.orin-b`,
# then set HOSTNAME_A=orin-a and HOSTNAME_B=orin-b.  These hostnames are
# embedded into the system during installation.
HOSTNAME_A="orin-a"
HOSTNAME_B="orin-b"
FLAKE_A="github:arduano/jetpack-nixos-testing#${HOSTNAME_A}"
FLAKE_B="github:arduano/jetpack-nixos-testing#${HOSTNAME_B}"

# Size of each EFI System Partition in MiB.  512 MiB is plenty for
# systemd-boot and multiple kernel generations.
BOOT_SIZE_MiB=512

# Ensure we have the required commands available.
for cmd in sgdisk mkfs.fat mkfs.btrfs partprobe lsblk mount umount nixos-install; do
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

# Unmount any existing mount points on the device to avoid busy errors.
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

# Compute the disk size and determine root partition sizes.  We
# reserve two boot partitions and a 1 GiB buffer and split the remaining
# space between the two roots.
total_bytes=$(blockdev --getsize64 "$DISK")
boot_bytes=$((BOOT_SIZE_MiB * 1024 * 1024))
reserved_bytes=$((2 * boot_bytes + 1024 * 1024 * 1024))
available_bytes=$((total_bytes - reserved_bytes))
root_bytes=$((available_bytes / 2))
root_size_MiB=$((root_bytes / 1024 / 1024))

# Create GPT partitions:
#   1: EFI System Partition A
#   2: EFI System Partition B
#   3: Root partition A
#   4: Root partition B
sudo sgdisk -n1:1MiB:+${BOOT_SIZE_MiB}MiB   -t1:EF00 -c1:"EFI_A" "$DISK"
sudo sgdisk -n2:0:+${BOOT_SIZE_MiB}MiB   -t2:EF00 -c2:"EFI_B" "$DISK"
sudo sgdisk -n3:0:+${root_size_MiB}MiB -t3:8300 -c3:"ROOT_A" "$DISK"
sudo sgdisk -n4:0:0               -t4:8300 -c4:"ROOT_B" "$DISK"

# Tell the kernel about the new table.
sudo partprobe "$DISK"

# Format ESPs as FAT32.
echo "Formatting boot partitions…"
sudo mkfs.fat -F32 -n "NIXBOOT_A" "${DISK}p1"
sudo mkfs.fat -F32 -n "NIXBOOT_B" "${DISK}p2"

# Format root partitions as btrfs (DUP mode for data and metadata).
echo "Formatting root partitions…"
for idx in 3 4; do
    label="NIXROOT_$( [ $idx -eq 3 ] && echo A || echo B )"
    sudo mkfs.btrfs -f -L "$label" -m dup -d dup "${DISK}p${idx}"
done

### Dual-slot installation

ROOT_A="${DISK}p3"
ROOT_B="${DISK}p4"
BOOT_A="${DISK}p1"
BOOT_B="${DISK}p2"

# Install slot A

echo "Installing slot A (${HOSTNAME_A})…"
sudo mkdir -p /mnt
sudo mount "$ROOT_A" /mnt
sudo btrfs subvolume create /mnt/@
sudo umount /mnt
sudo mount -o subvol=@ "$ROOT_A" /mnt
sudo mkdir -p /mnt/boot
sudo mount "$BOOT_A" /mnt/boot
sudo nixos-install --root /mnt --flake "$FLAKE_A" --no-root-passwd
sudo umount -R /mnt

# Install slot B

echo "Installing slot B (${HOSTNAME_B})…"
sudo mkdir -p /mnt2
sudo mount "$ROOT_B" /mnt2
sudo btrfs subvolume create /mnt2/@
sudo umount /mnt2
sudo mount -o subvol=@ "$ROOT_B" /mnt2
sudo mkdir -p /mnt2/boot
sudo mount "$BOOT_B" /mnt2/boot
sudo nixos-install --root /mnt2 --flake "$FLAKE_B" --no-root-passwd
sudo umount -R /mnt2

sync

echo "\nCompleted installation.  There are now two independent boot and root slots on $DISK."
echo "Slot A (ESP A + ROOT A) uses hostname ${HOSTNAME_A}, and slot B (ESP B + ROOT B) uses hostname ${HOSTNAME_B}."
echo "Each boot loader only knows about its own root.  Configure the UEFI boot order with efibootmgr so that the slot A"
echo "entry is tried first; if it fails, firmware should fall back to slot B.  Use systemd‑boot’s menu to select previous"
echo "generations within a slot when needed.\n"

echo "You can optionally register both ESPs with UEFI using efibootmgr.  For example:\n"
echo "  sudo efibootmgr -c -d $DISK -p 1 -L \"NixOS (${HOSTNAME_A})\" -l '\\\\EFI\\\\systemd\\\\systemd-bootaa64.efi'\n"
echo "  sudo efibootmgr -c -d $DISK -p 2 -L \"NixOS (${HOSTNAME_B})\" -l '\\\\EFI\\\\systemd\\\\systemd-bootaa64.efi'\n"
echo "and then adjust the BootOrder so that the A entry is first."
