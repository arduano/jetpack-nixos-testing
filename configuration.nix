{
  # Enable the JetPack integration.  See jetpack‑nixos README for details:contentReference[oaicite:1]{index=1}.
  hardware.nvidia-jetpack.enable = true;
  hardware.nvidia-jetpack.som = "orin-nx";         # adjust for your SOM
  hardware.nvidia-jetpack.carrierBoard = "devkit"; # adjust if using a different carrier

  # Enable the vendor graphics stack (required for CUDA and multimedia):contentReference[oaicite:2]{index=2}.
  hardware.graphics.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "nixos";
    createHome = true;
  };
}
