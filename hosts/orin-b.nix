{ pkgs, ... }: {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "status" ''
      echo "Known bad generation"
    '')
  ];

  boot.kernelModules = [ "this_module_does_not_exist" ];
}
