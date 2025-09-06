{ pkgs, lib, ... }: {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "status" ''
      echo "Known bad generation"
    '')
  ];

  # # Exit the initrd scripts early -> kernel panics "Attempted to kill init!"
  boot.initrd.postMountCommands = lib.mkAfter ''
    set -e
    trap '${pkgs.busybox}/bin/reboot -f' ERR
    false
  '';
  # (Optional) reboot quickly after panic
  boot.kernelParams = lib.mkAfter [
    "panic=5"
    "panic_on_oops=1"    # treat kernel oops as panic
    "rd.emergency=reboot"  # If initrd drops to emergency for any reason, reboot instead of waiting
  ];
}
