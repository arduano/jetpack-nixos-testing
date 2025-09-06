{
  inputs = {
    nixpkgs.url  = "github:NixOS/nixpkgs/nixos-25.05";
    jetpack.url  = "github:anduril/jetpack-nixos/master";
    jetpack.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, jetpack, ... }:
  let
    lib = nixpkgs.lib;

    mkSystem = { hostname, rootLabel, bootLabel, otherHostname, otherRootLabel, otherBootLabel }:
      nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules =
          [
            jetpack.nixosModules.default
            ./configuration.nix
            ./modules/ab-slot.nix
            ./modules/update-system.nix
          ]
          ++ lib.optional (builtins.pathExists (./hosts + "/${hostname}.nix")) (./hosts + "/${hostname}.nix")
          ++ [
            ({ ... }: {
              ab.slot = {
                inherit hostname rootLabel bootLabel otherHostname otherRootLabel otherBootLabel;
                flakeRef = "github:arduano/jetpack-nixos-testing";
              };
            })
          ];
      };
  in {
    nixosConfigurations.orin-a = mkSystem {
      hostname = "orin-a";
      rootLabel = "NIXROOT_A";
      bootLabel = "NIXBOOT_A";
      otherHostname = "orin-b";
      otherRootLabel = "NIXROOT_B";
      otherBootLabel = "NIXBOOT_B";
    };

    nixosConfigurations.orin-b = mkSystem {
      hostname = "orin-b";
      rootLabel = "NIXROOT_B";
      bootLabel = "NIXBOOT_B";
      otherHostname = "orin-a";
      otherRootLabel = "NIXROOT_A";
      otherBootLabel = "NIXBOOT_A";
    };
  }
}
