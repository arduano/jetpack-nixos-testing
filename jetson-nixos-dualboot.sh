#!/usr/bin/env bash
#
# jetson-nixos-dualboot.sh – Prepare an NVIDIA Jetson Orin NX NVMe for
# a redundant NixOS installation with A/B boot and root partitions.
#
set -euo pipefail

# --- utils --------------------------------------------------------------
log() { echo -e "\033[36m$*\033[0m" >&2; }
fail(){ echo "ERROR: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"; }

check_entry_files() {
  # $1 = esp mount path
  local m="$1"
  # systemd-boot present
  [ -f "$m/EFI/systemd/systemd-bootaa64.efi" ] || fail "Missing $m/EFI/systemd/systemd-bootaa64.efi"
  # entries present
  shopt -s nullglob
  local entries=( "$m"/loader/entries/*.conf )
  shopt -u nullglob
  [ ${#entries[@]} -gt 0 ] || fail "No loader entries in $m/loader/entries/"
  # each entry must have linux + initrd pointing to files on this ESP
  for e in "${entries[@]}"; do
    local kpath ipath
    kpath="$(awk '$1=="linux"{print $2; exit}' "$e")"
    ipath="$(awk '$1=="initrd"{print $2; exit}' "$e")"
    [ -n "$kpath" ] || fail "$(basename "$e"): missing 'linux' line"
    [ -n "$ipath" ] || fail "$(basename "$e"): missing 'initrd' line"
    kpath="${kpath#\\}"; kpath="${kpath//\\//}"
    ipath="${ipath#\\}"; ipath="${ipath//\\//}"
    [ -f "$m/$kpath" ] || fail "$(basename "$e"): kernel not found on ESP: $kpath"
    [ -f "$m/$ipath" ] || fail "$(basename "$e"): initrd not found on ESP: $ipath"
  done
}

cleanup_nvram_for_disk() {
  # remove any systemd-boot entries for ESP1/ESP2
  command -v efibootmgr >/dev/null || return 0
  efibootmgr -v \
    | awk '/systemd-bootaa64\.efi/ && /HD\((1|2),/ {print $1}' \
    | sed 's/^Boot\([0-9A-Fa-f]\{4\}\)\*.*/\1/' \
    | while read -r id; do [ -n "$id" ] && sudo efibootmgr -b "$id" -B || true; done
}

boot_id_by_label() {
  local label="$1"
  efibootmgr -v | grep -F "$label" \
    | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*.*/\1/p' | head -n1
}

boot_id_by_part() {
  local part="$1" # 1 or 2
  efibootmgr -v | awk '/\\EFI\\BOOT\\BOOTAA64\.EFI/ && /HD\('"$part"',/ {print $1}' \
    | sed 's/^Boot\([0-9A-Fa-f]\{4\}\)\*.*/\1/' | head -n1
}

create_nvram_entries() {
  local disk="$1" labelA="$2" labelB="$3"
  command -v efibootmgr >/dev/null || { log "no efibootmgr"; return 0; }

  # Use the fallback path (works with Jetson firmware)
  sudo efibootmgr -c -d "$disk" -p 1 -L "$labelA" -l 'EFI\BOOT\BOOTAA64.EFI'
  sudo efibootmgr -c -d "$disk" -p 2 -L "$labelB" -l 'EFI\BOOT\BOOTAA64.EFI'

  # Resolve IDs by label, then by partition if needed
  local ida idb
  ida="$(boot_id_by_label "$labelA")"; [ -z "$ida" ] && ida="$(boot_id_by_part 1)"
  idb="$(boot_id_by_label "$labelB")"; [ -z "$idb" ] && idb="$(boot_id_by_part 2)"

  if [ -n "$ida" ] && [ -n "$idb" ]; then
    sudo efibootmgr -o "$ida,$idb"
    log "Set BootOrder: $ida (A) then $idb (B)"
  else
    log "WARN: Could not determine Boot#### IDs; set manually with: sudo efibootmgr -o <A>,<B>"
  fi
}

# --- inputs -------------------------------------------------------------
need sgdisk; need mkfs.fat; need mkfs.btrfs; need partprobe; need lsblk; need mount; need umount; need nixos-install

DISK="/dev/nvme0n1"

HOSTNAME_A="orin-a"
HOSTNAME_B="orin-b"
FLAKE_A="github:arduano/jetpack-nixos-testing#${HOSTNAME_A}"
FLAKE_B="github:arduano/jetpack-nixos-testing#${HOSTNAME_B}"

BOOT_SIZE_MiB=512

log "This will partition and erase $DISK. Continue? [y/N]"
read -r reply
case "$reply" in [Yy]*) ;; *) log "Aborted."; exit 1;; esac

# Unmount anything on the disk
for p in $(lsblk -ln -o NAME "$DISK" | tail -n +2); do
  mp=$(lsblk -n -o MOUNTPOINT "/dev/$p" || true)
  [ -n "$mp" ] && { log "Unmounting /dev/$p from $mp"; sudo umount -Rf "$mp" || true; }
done

# Partitioning
log "Partitioning $DISK…"
sudo sgdisk --zap-all "$DISK"
sudo sgdisk --clear "$DISK"

total_bytes=$(blockdev --getsize64 "$DISK")
boot_bytes=$((BOOT_SIZE_MiB * 1024 * 1024))
reserved_bytes=$((2 * boot_bytes + 1024 * 1024 * 1024))
available_bytes=$((total_bytes - reserved_bytes))
root_bytes=$((available_bytes / 2))
root_size_MiB=$((root_bytes / 1024 / 1024))

sudo sgdisk -n1:1MiB:+${BOOT_SIZE_MiB}MiB -t1:EF00 -c1:"EFI_A"  "$DISK"
sudo sgdisk -n2:0:+${BOOT_SIZE_MiB}MiB   -t2:EF00 -c2:"EFI_B"  "$DISK"
sudo sgdisk -n3:0:+${root_size_MiB}MiB   -t3:8300 -c3:"ROOT_A" "$DISK"
sudo sgdisk -n4:0:0                       -t4:8300 -c4:"ROOT_B" "$DISK"
sudo partprobe "$DISK"

# Filesystems
log "Formatting ESPs…"
sudo mkfs.fat -F32 -n "NIXBOOT_A" "${DISK}p1"
sudo mkfs.fat -F32 -n "NIXBOOT_B" "${DISK}p2"

log "Formatting btrfs roots (DUP)…"
sudo mkfs.btrfs -f -L "NIXROOT_A" -m dup -d dup "${DISK}p3"
sudo mkfs.btrfs -f -L "NIXROOT_B" -m dup -d dup "${DISK}p4"

ROOT_A="${DISK}p3"; ROOT_B="${DISK}p4"
BOOT_A="${DISK}p1"; BOOT_B="${DISK}p2"

# Mount both slots
log "Mounting roots/boots…"
sudo mkdir -p /mntA /mntB
sudo mount "$ROOT_A" /mntA
sudo btrfs subvolume create /mntA/@ || true
sudo umount /mntA
sudo mount -o subvol=@ "$ROOT_A" /mntA
sudo mkdir -p /mntA/boot
sudo mount "$BOOT_A" /mntA/boot

sudo mount "$ROOT_B" /mntB
sudo btrfs subvolume create /mntB/@ || true
sudo umount /mntB
sudo mount -o subvol=@ "$ROOT_B" /mntB
sudo mkdir -p /mntB/boot
sudo mount "$BOOT_B" /mntB/boot

# Optional pre-seed (safe to skip/fail)
if command -v nix >/dev/null 2>&1; then
  log "Optional: pre-seeding Nix store (A)…"
  nix copy --from ssh://arduano@192.168.1.51 \
    /nix/store/qjlndsfq60h2jrcbz68mwp591rr36f6j-nixos-system-orin-25.05.20250903.0e6684e \
    --store /mntA --no-check-sigs || true

  log "Optional: pre-seeding Nix store (B)…"
  nix copy --from /mntA \
    /nix/store/qjlndsfq60h2jrcbz68mwp591rr36f6j-nixos-system-orin-25.05.20250903.0e6684e \
    --store /mntB --no-check-sigs || true
fi

# Install both slots (explicitly install bootloader)
log "Installing slot A ($HOSTNAME_A)…"
sudo nixos-install --root /mntA --flake "$FLAKE_A" --no-root-passwd

log "Installing slot B ($HOSTNAME_B)…"
sudo nixos-install --root /mntB --flake "$FLAKE_B" --no-root-passwd

# Ensure fallback loader paths exist on both ESPs
log "Placing fallback BOOTAA64.EFI on both ESPs…"
sudo install -D /mntA/boot/EFI/systemd/systemd-bootaa64.efi /mntA/boot/EFI/BOOT/BOOTAA64.EFI
sudo install -D /mntB/boot/EFI/systemd/systemd-bootaa64.efi /mntB/boot/EFI/BOOT/BOOTAA64.EFI

# Verify entries (accept default NixOS style: linux+initrd present)
log "Verifying loader entries (ESP-A)…"
check_entry_files /mntA/boot
log "Verifying loader entries (ESP-B)…"
check_entry_files /mntB/boot

# Clean up any old systemd-boot NVRAM entries and create fresh ones
log "Cleaning up old UEFI entries for this disk…"
cleanup_nvram_for_disk "$DISK" || true

log "Creating UEFI entries for A/B and setting BootOrder…"
create_nvram_entries "$DISK" "NixOS (${HOSTNAME_A})" "NixOS (${HOSTNAME_B})" || true

# Show final NVRAM state
if command -v efibootmgr >/dev/null 2>&1; then
  log "Final efibootmgr -v:"
  efibootmgr -v || true
else
  log "efibootmgr not found; skipped showing NVRAM state."
fi

# Unmount
log "Unmounting…"
sudo umount -R /mntB || true
sudo umount -R /mntA || true
sync

log "\nCompleted installation on $DISK"
log "Slot A: ESP p1 (NIXBOOT_A) + Root p3 (NIXROOT_A) – hostname ${HOSTNAME_A}"
log "Slot B: ESP p2 (NIXBOOT_B) + Root p4 (NIXROOT_B) – hostname ${HOSTNAME_B}"
log "Firmware BootOrder set to A then B (if efibootmgr present)."
