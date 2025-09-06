{ pkgs, lib, ... }: {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "status" ''
      echo "Known bad generation"
    '')
  ];

  # # Exit the initrd scripts early -> kernel panics "Attempted to kill init!"
  boot.initrd.postMountCommands = lib.mkAfter ''
    echo "Intentional test failure: exiting initrd" >&2
    exit 1
  '';
  # (Optional) reboot quickly after panic
  boot.kernelParams = lib.mkAfter [
    "panic=5"
    "panic_on_oops=1"    # treat kernel oops as panic
    "rd.emergency=reboot"  # If initrd drops to emergency for any reason, reboot instead of waiting
  ];
}
