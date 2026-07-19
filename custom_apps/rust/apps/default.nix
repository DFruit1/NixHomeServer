{ lib, pkgs, rustLib }:

{
  kanidm-canary-bootstrap = import ./kanidm-canary-bootstrap/default.nix {
    inherit rustLib;
  };
  mail-archive-ui = import ./mail-archive-ui/default.nix {
    inherit lib pkgs rustLib;
  };
  # kanidm-admin is archived in _archive/ and intentionally not packaged in the active app set.
  # Use native `kanidm` CLI commands for identity operations while the archived flow is removed.
}
