{ lib, config, pkgs, ... }:
let
  cfg = config.ab.slot;
in {
  options.ab.slot = {
    hostname = lib.mkOption { type = lib.types.str; };
    rootLabel = lib.mkOption { type = lib.types.str; };
    bootLabel = lib.mkOption { type = lib.types.str; };
    otherHostname = lib.mkOption { type = lib.types.str; };
    otherRootLabel = lib.mkOption { type = lib.types.str; };
    otherBootLabel = lib.mkOption { type = lib.types.str; };
    flakeRef = lib.mkOption { type = lib.types.str; default = "github:arduano/jetpack-nixos-testing"; };
    mountOtherReadWrite = lib.mkOption { type = lib.types.bool; default = true; };
  };

  config = {
    networking.hostName = cfg.hostname;

    fileSystems."/" = {
      device = "/dev/disk/by-label/${cfg.rootLabel}";
      fsType = "btrfs";
      options = [ "subvol=@" "ssd" "compress=zstd" "discard=async" ];
    };

    fileSystems."/boot" = {
      device = "/dev/disk/by-label/${cfg.bootLabel}";
      fsType = "vfat";
    };

    # Always mount the opposite slot at /mnt/other
    fileSystems."/mnt/other" = {
      device = "/dev/disk/by-label/${cfg.otherRootLabel}";
      fsType = "btrfs";
      options =
        [ "subvol=@" "ssd" "compress=zstd" "discard=async" ]
        ++ lib.optionals (!cfg.mountOtherReadWrite) [ "ro" ];
      neededForBoot = false;
    };

    fileSystems."/mnt/other/boot" = {
      device = "/dev/disk/by-label/${cfg.otherBootLabel}";
      fsType = "vfat";
      neededForBoot = false;
    };

    # Make root explicit (works for both classic + UKI)
    boot.kernelParams = [
      "root=LABEL=${cfg.rootLabel}"
      "rootflags=subvol=@,compress=zstd,ssd,discard=async"
    ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.loader.efi.efiSysMountPoint = "/boot";

    # Turn the newest generation into a trial (2 tries) using absolute tool paths
    boot.loader.systemd-boot.extraInstallCommands =
      let cu = "${pkgs.coreutils}/bin";
      in ''
        set -eu
        E=/boot/loader/entries
        # find newest nixos-generation-*.conf (numeric sort)
        latest="$(${cu}/printf '%s\n' "$E"/nixos-generation-*.conf \
                | ${cu}/sort -V | ${cu}/tail -n1 || true)"
        if [ -n "''${latest:-}" ] && [ -e "$latest" ]; then
          trial="''${latest%.conf}+2-0.conf"
          if [ ! -e "$trial" ]; then
            ${cu}/mv "$latest" "$trial"
          fi
        fi
      '';

    # Only bless boot as "successful" if no failed units
    systemd.services.systemd-boot-check-no-failures.enable = true;
    systemd.services.systemd-boot-check-no-failures.wantedBy = [ "boot-complete.target" ];
  };
}
