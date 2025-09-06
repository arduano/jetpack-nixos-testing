{ pkgs, ... }: {
  environment.systemPackages = [
    (pkgs.writeShellScriptBin "status" ''
      echo "Known good generation"
    '')
  ];
}
