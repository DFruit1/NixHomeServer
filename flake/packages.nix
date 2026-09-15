{ lib, pkgs, crane, pkgsUnstable ? pkgs }:

let
  rustLib = import ../custom_apps/rust/lib { inherit lib pkgs crane pkgsUnstable; };
  rustApps = import ../custom_apps/rust/apps { inherit lib pkgs rustLib; };
  rustPackages = lib.mapAttrs (_: app: app.package) rustApps;
  nodeApps = import ../custom_apps/node/apps { inherit lib pkgs; };
  tauriApps = {
    youtube-downloader-tauri = pkgs.callPackage ../custom_apps/node/apps/youtube-downloader/tauri.nix {
      clientPackage = nodeApps.youtube-downloader;
    };
  };
in
{
  inherit rustLib rustApps nodeApps tauriApps;

  appPackages = rustPackages // nodeApps;
}
