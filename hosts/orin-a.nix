{ pkgs, lib, ... }: {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "status" ''
      echo "Known good generation"
    '')
  ];

  # # Exit the initrd scripts early -> kernel panics "Attempted to kill init!"
  # boot.initrd.postMountCommands = lib.mkAfter ''
  #   echo "Intentional test failure: exiting initrd" >&2
  #   exit 1
  # '';
  # # (Optional) reboot quickly after panic
  # boot.kernelParams = lib.mkAfter [ "panic=5" ];
}
