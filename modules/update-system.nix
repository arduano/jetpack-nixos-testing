{ lib, pkgs, config, ... }:
let
  cfg = config.ab.slot;
in {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "update-systems" ''
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
    '')
  ];

  environment.systemPackages = [
    (pkgs.writeShellScriptBin "update-system" ''
      set -euo pipefail

      sudo nixos-rebuild switch \
        --flake ${cfg.flakeRef}#${cfg.hostname} \
        --refresh
    '')
  ];
}
