{
  inputs = {
    nixpkgs.url  = "github:NixOS/nixpkgs/nixos-25.05";
    jetpack.url  = "github:anduril/jetpack-nixos/master";
    jetpack.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, jetpack, ... }: {
    # Build the “orin” system using JetPack modules
    nixosConfigurations.orin = nixpkgs.lib.nixosSystem {
      # You can embed extra configuration directly here, or keep it in
      # configuration.nix as shown below.
      modules = [
        ./configuration.nix
        jetpack.nixosModules.default
        ({ pkgs, ... }: {
          # Tell NixOS where the root and boot partitions live.
          # The labels “NIXROOT_A” and “NIXBOOT_A” are set by the
          # installation script; you can also use /dev/nvme0n1p3 and p1.
          fileSystems."/" = {
            device  = "/dev/disk/by-label/NIXROOT_A";
            fsType  = "btrfs";
            options = [ "subvol=@"
                        "compress=zstd"
                        "ssd"
                        "discard=async"
                      ];
          };
          fileSystems."/boot" = {
            device = "/dev/disk/by-label/NIXBOOT_A";
            fsType = "vfat";
          };

          # Use systemd‑boot on UEFI.  Grub isn’t needed on Jetson.
          boot.loader.systemd-boot.enable = true;
          boot.loader.efi.canTouchEfiVariables = true;

          networking.hostName = "orin";
          # (Optional) Set a time zone and locale, user accounts, etc.
        })
      ];
    };
  };
}
