{ config, lib, pkgs, vars, ... }:

# Lets Media Manager ask Radarr to rescan after it replaces a video, such as a
# conversion that changes the file extension.
let
  arrRefresh = import ../Core_Modules/media-manager/arr-refresh.nix { inherit config lib pkgs vars; };
in
{
  config = lib.mkIf config.repo.radarr.enable (arrRefresh {
    id = "radarr";
    label = "Radarr";
    port = vars.networking.ports.radarr;
    configXml = "/var/lib/radarr/.config/Radarr/config.xml";
    command = "RescanMovie";
  });
}
