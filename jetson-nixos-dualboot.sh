#!/usr/bin/env bash
#
# jetson-nixos-dualboot.sh – Prepare an NVIDIA Jetson Orin NX with two
# separate disks for redundant NixOS installs: System A on /dev/nvme0n1
# and System B on /dev/sdb. Each disk gets its own ESP and ROOT.
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

# --- inputs -------------------------------------------------------------
need sgdisk; need mkfs.fat; need mkfs.btrfs; need partprobe; need lsblk; need mount; need umount; need nixos-install

# Target disks
DISK_A="/dev/nvme0n1"
DISK_B="/dev/sdb"

HOSTNAME_A="orin-a"
HOSTNAME_B="orin-b"
FLAKE_A="github:arduano/jetpack-nixos-testing#${HOSTNAME_A}"
FLAKE_B="github:arduano/jetpack-nixos-testing#${HOSTNAME_B}"

BOOT_SIZE_MiB=512

log "This will partition and erase $DISK_A (A) and $DISK_B (B). Continue? [y/N]"
read -r reply
case "$reply" in [Yy]*) ;; *) log "Aborted."; exit 1;; esac

# Unmount anything on the target disks
for d in "$DISK_A" "$DISK_B"; do
  for p in $(lsblk -ln -o NAME "$d" | tail -n +2); do
    mp=$(lsblk -n -o MOUNTPOINT "/dev/$p" || true)
    [ -n "$mp" ] && { log "Unmounting /dev/$p from $mp"; sudo umount -Rf "$mp" || true; }
  done
done

# Partition disk A
log "Partitioning $DISK_A (A)…"
sudo sgdisk --zap-all "$DISK_A"
sudo sgdisk --clear "$DISK_A"
sudo sgdisk -n1:1MiB:+${BOOT_SIZE_MiB}MiB -t1:EF00 -c1:"EFI_A"  "$DISK_A"
sudo sgdisk -n2:0:0                       -t2:8300 -c2:"ROOT_A" "$DISK_A"
sudo partprobe "$DISK_A"

# Partition disk B
log "Partitioning $DISK_B (B)…"
sudo sgdisk --zap-all "$DISK_B"
sudo sgdisk --clear "$DISK_B"
sudo sgdisk -n1:1MiB:+${BOOT_SIZE_MiB}MiB -t1:EF00 -c1:"EFI_B"  "$DISK_B"
sudo sgdisk -n2:0:0                       -t2:8300 -c2:"ROOT_B" "$DISK_B"
sudo partprobe "$DISK_B"

# Filesystems
log "Formatting ESPs…"
sudo mkfs.fat -F32 -n "NIXBOOT_A" "${DISK_A}p1"
sudo mkfs.fat -F32 -n "NIXBOOT_B" "${DISK_B}1"

log "Formatting btrfs roots (DUP)…"
sudo mkfs.btrfs -f -L "NIXROOT_A" -m dup -d dup "${DISK_A}p2"
sudo mkfs.btrfs -f -L "NIXROOT_B" -m dup -d dup "${DISK_B}2"

ROOT_A="/dev/disk/by-label/NIXROOT_A"; ROOT_B="/dev/disk/by-label/NIXROOT_B"
BOOT_A="/dev/disk/by-label/NIXBOOT_A"; BOOT_B="/dev/disk/by-label/NIXBOOT_B"

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

# Ensure nix cache is clear
nix-collect-garbage

# Install both slots (explicitly install bootloader)
log "Installing slot A ($HOSTNAME_A)…"
sudo nixos-install --root /mntA --flake "$FLAKE_A" --no-root-passwd

log "Installing slot B ($HOSTNAME_B)…"
sudo nixos-install --root /mntB --flake "$FLAKE_B" --no-root-passwd

# Unmount
log "Unmounting…"
sudo umount -R /mntB || true
sudo umount -R /mntA || true
sync
log "\nCompleted installations."
log "A on $DISK_A: ESP p1 (NIXBOOT_A) + Root p2 (NIXROOT_A) – ${HOSTNAME_A}"
log "B on $DISK_B: ESP p1 (NIXBOOT_B) + Root p2 (NIXROOT_B) – ${HOSTNAME_B}"
