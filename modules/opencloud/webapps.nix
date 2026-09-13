{ lib, pkgs, ... }:

# Optional client-side file viewers and editors for OpenCloud Web.
#
# OpenCloud discovers every directory below WEB_ASSET_APPS_PATH that contains a
# manifest.json. The docs describe installing these apps imperatively into the
# data pool ($OC_DATA_DIR/web/assets/apps); pinning the release bundles in the
# Nix store instead keeps the set reproducible and removes it from the mutable
# data tree. Office co-editing is covered separately by Collabora
# (modules/opencloud/collabora.nix).
let
  appBundles = {
    # Official OpenCloud web-extension apps.
    draw-io = pkgs.fetchurl {
      name = "opencloud-web-app-draw-io-2.2.0.zip";
      url = "https://github.com/opencloud-eu/web-extensions/releases/download/draw-io-v2.2.0/draw-io-2.2.0.zip";
      hash = "sha256-ScOqMqpRfyqQ8km1Rws43Bi30AaEHEQvZDNdZgtVHQw=";
    };
    unzip = pkgs.fetchurl {
      name = "opencloud-web-app-unzip-2.1.0.zip";
      url = "https://github.com/opencloud-eu/web-extensions/releases/download/unzip-v2.1.0/unzip-2.1.0.zip";
      hash = "sha256-C8h2vmGHCaSioAzwEFKH1KFCgsFgCvh3jqqHz6vW27Y=";
    };
    json-viewer = pkgs.fetchurl {
      name = "opencloud-web-app-json-viewer-2.1.0.zip";
      url = "https://github.com/opencloud-eu/web-extensions/releases/download/json-viewer-v2.1.0/json-viewer-2.1.0.zip";
      hash = "sha256-Ha7hy9VQ+flJC7gVh2d82o14u1ETTDuCmgxLtgG7l78=";
    };
    # Community app (listed in opencloud-eu/awesome-apps, not in the App Store):
    # a three.js viewer for .3mf/.stl/.obj/.ply/.gltf/.glb project assets.
    three-d-viewer = pkgs.fetchurl {
      name = "opencloud-web-app-3dviewer.zip";
      url = "https://github.com/LetsDrinkSomeTea/opencloud-3dviewer/releases/download/v1.1.0-20260723-124242/3dviewer.zip";
      hash = "sha256-Uop9qOwBRdeDAZhXst5r98HQzRIQpbQ3xaN/cLO2i7w=";
    };
  };

  webApps = pkgs.runCommand "opencloud-web-apps" { nativeBuildInputs = [ pkgs.unzip ]; } ''
    set -euo pipefail
    mkdir -p "$out"
    for bundle in ${lib.concatStringsSep " " (lib.attrValues appBundles)}; do
      unzip -q "$bundle" -d "$out"
    done
    for app in draw-io unzip json-viewer 3dviewer; do
      if [ ! -f "$out/$app/manifest.json" ]; then
        echo "missing manifest.json for OpenCloud web app '$app'" >&2
        exit 1
      fi
    done
  '';
in
{
  services.opencloud.environment.WEB_ASSET_APPS_PATH = toString webApps;
}
