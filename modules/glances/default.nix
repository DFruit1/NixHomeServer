{ pkgs, ... }:

let
  glancesConfig = pkgs.writeText "glances.conf" ''
    [global]
    refresh=5
    check_update=false
    history_size=600
  '';
in
{
  imports = [ ./oauth2-proxy.nix ];

  services.glances = {
    enable = true;
    extraArgs = [
      "--webserver"
      "--disable-autodiscover"
      "-C"
      "${glancesConfig}"
    ];
  };
}
