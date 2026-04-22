{ lib, pkgs, ... }:

let
  kanidmUserTuiData = pkgs.runCommandLocal "kanidm-user-tui-data" { } ''
    mkdir -p "$out/scripts"
    cp ${../../../scripts/kanidm-create-user.sh} "$out/scripts/kanidm-create-user.sh"
    chmod 0555 "$out/scripts/kanidm-create-user.sh"
    cp ${../../../vars.nix} "$out/vars.nix"
    chmod 0444 "$out/vars.nix"
  '';

  kanidmUserTui = pkgs.writeShellApplication {
    name = "kanidm-user-tui";
    runtimeInputs = [ pkgs.kanidm_1_9 pkgs.dialog pkgs.jq pkgs.newt pkgs.nix ];
    text = ''
      export KANIDM_TUI_REPO_ROOT=${lib.escapeShellArg (toString kanidmUserTuiData)}
      exec ${lib.escapeShellArg "${toString kanidmUserTuiData}/scripts/kanidm-create-user.sh"} "$@"
    '';
  };
in
{
  environment.systemPackages = [
    pkgs.kanidm_1_9
    kanidmUserTui
  ];
}
