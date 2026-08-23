{ lib, pkgs, rustLib }:

let
  craneLib = rustLib.craneLib;
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

  # --- Shared Cargo workspace -------------------------------------------------
  # The three rust/apps members share a single source tree and prebuilt
  # dependency artifacts, so common crates (tokio/axum/serde/rusqlite/…)
  # compile only once instead of once per crate. mkvmaker keeps its own
  # standalone build (it has a separate flake and edition 2024).
  workspaceSrcRoot = ../..;
  mkvmakerPrefix = toString (workspaceSrcRoot + "/mkvmaker");
  workspaceFilter = path: type:
    let
      pathStr = toString path;
    in
    (! lib.hasPrefix mkvmakerPrefix pathStr)
    && (! lib.hasSuffix "Cargo.lock" pathStr)
    && craneLib.filterCargoSources path type;
  workspaceSrc = lib.cleanSourceWith {
    src = workspaceSrcRoot;
    name = "nixhomeserver-rust-workspace-src";
    filter = workspaceFilter;
  };
  cargoLock = ../../Cargo.lock;
  sharedCargoArtifacts = craneLib.buildDepsOnly {
    src = workspaceSrc;
    inherit cargoLock;
    cargoExtraArgs = "--locked";
    pname = "nixhomeserver-rust-workspace-deps";
    version = "0.1.0";
    strictDeps = true;
  };
in
assert builtins.readFile (mailFrontend + "/pnpm-lock.yaml")
  == builtins.readFile (mediaFrontend + "/pnpm-lock.yaml");
assert comparableManifest mailManifest == comparableManifest mediaManifest;
{
  kanidm-canary-bootstrap = import ./kanidm-canary-bootstrap/default.nix {
    inherit rustLib;
    inherit workspaceSrc sharedCargoArtifacts cargoLock;
  };
  mail-archive-ui = import ./mail-archive-ui/default.nix {
    inherit lib pkgs rustLib sharedFrontendDeps;
    inherit workspaceSrc sharedCargoArtifacts cargoLock;
  };
  media-manager = import ./media-manager/default.nix {
    inherit lib pkgs rustLib sharedFrontendDeps;
    inherit workspaceSrc sharedCargoArtifacts cargoLock;
  };
  mkvmaker = import ../../mkvmaker/default.nix {
    inherit lib pkgs rustLib;
  };
  # kanidm-admin is archived in _archive/ and intentionally not packaged in the active app set.
  # Use native `kanidm` CLI commands for identity operations while the archived flow is removed.
}
