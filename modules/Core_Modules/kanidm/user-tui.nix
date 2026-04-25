{ pkgs, self, ... }:

{
  environment.systemPackages = [
    pkgs.kanidm_1_9
    self.packages.${pkgs.stdenv.hostPlatform.system}.kanidm-admin
  ];
}
