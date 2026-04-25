{ lib, pkgs, rustLib }:

{
  kanidm-admin = import ./kanidm-admin/default.nix {
    inherit lib pkgs rustLib;
  };
  mail-archive-ui = import ./mail-archive-ui/default.nix {
    inherit lib pkgs rustLib;
  };
}
