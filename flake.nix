{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    jetpack.url = "github:anduril/jetpack-nixos/master"; # Add this line
    jetpack.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = inputs@{ self, nixpkgs, jetpack, ... } : { # Add jetpack
    nixosConfigurations.orin = nixpkgs.lib.nixosSystem {
      modules = [ ./configuration.nix jetpack.nixosModules.default ]; # Add jetpack.nixosModules.default
    };
  };
}