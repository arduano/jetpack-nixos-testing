{
  inputs = {
    nixpkgs.url  = "github:NixOS/nixpkgs/nixos-25.05";
    jetpack.url  = "github:anduril/jetpack-nixos/master";
    jetpack.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, jetpack, ... }:
  let
    # Common JetPack/NixOS module
    baseModules = [
      jetpack.nixosModules.default
      ./configuration.nix
    ];
    mkSystem = { hostname, rootLabel, bootLabel }:
      nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = baseModules ++ [
          ({ pkgs, ... }: {
            # root and boot specific to the slot
            fileSystems."/" = {
              device = "/dev/disk/by-label/${rootLabel}";
              fsType = "btrfs";
              options = [ "subvol=@" "ssd" "compress=zstd" "discard=async" ];
            };
            fileSystems."/boot" = {
              device = "/dev/disk/by-label/${bootLabel}";
              fsType  = "vfat";
            };

            boot.kernelParams = [
              "root=LABEL=${rootLabel}"
              "rootflags=subvol=@,compress=zstd,ssd,discard=async"
            ];
            boot.loader.efi.efiSysMountPoint = "/boot";

            boot.loader.systemd-boot.enable = true;
            boot.loader.efi.canTouchEfiVariables = true;
            networking.hostName = hostname;
          })
        ];
      };
  in
  {
    nixosConfigurations.orin-a = mkSystem {
      hostname = "orin-a";
      rootLabel = "NIXROOT_A";
      bootLabel = "NIXBOOT_A";
    };
    nixosConfigurations.orin-b = mkSystem {
      hostname = "orin-b";
      rootLabel = "NIXROOT_B";
      bootLabel = "NIXBOOT_B";
    };
  };
}