{
  hardware.nvidia-jetpack.enable = true;
  hardware.nvidia-jetpack.som = "orin-nx"; # Other options include orin-agx, xavier-nx, and xavier-nx-emmc
  hardware.nvidia-jetpack.carrierBoard = "devkit";

  # Enable GPU support - needed even for CUDA and containers
  hardware.graphics.enable = true;
}