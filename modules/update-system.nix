{ lib, pkgs, config, ... }:
let
  cfg = config.ab.slot;
in {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "update-system" ''
      set -euo pipefail

      echo "[1/2] Rebuilding CURRENT slot (${cfg.hostname}) from ${cfg.flakeRef} …"
      sudo nixos-rebuild switch \
        --flake ${cfg.flakeRef}#${cfg.hostname} \
        --refresh

      echo "[1/2] Installing OTHER slot (${cfg.otherHostname}) into /mnt/other…"
      sudo nixos-install \
        --root /mnt/other \
        --flake ${cfg.flakeRef}#${cfg.otherHostname} \
        --no-root-passwd

      # Ensure fallback path exists on the other ESP
      if [ -f /mnt/other/boot/EFI/systemd/systemd-bootaa64.efi ]; then
        sudo install -D \
          /mnt/other/boot/EFI/systemd/systemd-bootaa64.efi \
          /mnt/other/boot/EFI/BOOT/BOOTAA64.EFI
      fi
    '')
  ];
}
