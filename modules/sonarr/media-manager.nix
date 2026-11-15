{ config, lib, pkgs, vars, ... }:

# Lets Media Manager ask Sonarr to rescan after it replaces a video, such as a
# conversion that changes the file extension.
let
  arrRefresh = import ../Core_Modules/media-manager/arr-refresh.nix { inherit config lib pkgs vars; };
in
{
  config = lib.mkIf config.repo.sonarr.enable (arrRefresh {
    id = "sonarr";
    label = "Sonarr";
    port = vars.networking.ports.sonarr;
    configXml = "/var/lib/sonarr/.config/NzbDrone/config.xml";
    command = "RescanSeries";
  });
}
