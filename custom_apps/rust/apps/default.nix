{ lib, pkgs, rustLib }:

let
  mailFrontend = ./mail-archive-ui/frontend;
  mediaFrontend = ./media-manager/frontend;
  mailManifest = builtins.fromJSON (builtins.readFile (mailFrontend + "/package.json"));
  mediaManifest = builtins.fromJSON (builtins.readFile (mediaFrontend + "/package.json"));
  comparableManifest = manifest: removeAttrs manifest [ "name" ];
  sharedFrontendDependencySrc = lib.cleanSourceWith {
    src = mailFrontend;
    name = "nixhomeserver-qwik-frontend-dependency-src";
    filter = path: _type:
      let
        rel = lib.removePrefix "${toString mailFrontend}/" (toString path);
      in
      rel == "" || builtins.elem rel [ "package.json" "pnpm-lock.yaml" ];
  };
  sharedFrontendDeps = pkgs.fetchPnpmDeps {
    pname = "nixhomeserver-qwik-frontends";
    version = "0.1.0";
    src = sharedFrontendDependencySrc;
    fetcherVersion = 3;
    hash = "sha256-GU8O2kA3o+SmAA5BRF/ws7jQqG+Tg7OX41bSw6ownZk=";
  };
in
assert builtins.readFile (mailFrontend + "/pnpm-lock.yaml")
  == builtins.readFile (mediaFrontend + "/pnpm-lock.yaml");
assert comparableManifest mailManifest == comparableManifest mediaManifest;
{
  kanidm-canary-bootstrap = import ./kanidm-canary-bootstrap/default.nix {
    inherit rustLib;
  };
  mail-archive-ui = import ./mail-archive-ui/default.nix {
    inherit lib pkgs rustLib sharedFrontendDeps;
  };
  media-manager = import ./media-manager/default.nix {
    inherit lib pkgs rustLib sharedFrontendDeps;
  };
  mkvmaker = import ../../mkvmaker/default.nix {
    inherit lib pkgs rustLib;
  };
  # kanidm-admin is archived in _archive/ and intentionally not packaged in the active app set.
  # Use native `kanidm` CLI commands for identity operations while the archived flow is removed.
}
