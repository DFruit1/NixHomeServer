{ lib, pkgs, rustLib }:

let
  craneLib = rustLib.craneLib;
  mailFrontend = ./mail-archive-ui/frontend;
  mediaFrontend = ./media-manager/frontend;
  workspaceManifest = builtins.fromTOML (builtins.readFile ../../Cargo.toml);
  workspaceVersion = workspaceManifest.workspace.package.version;
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
  # The rust/apps members share a single source tree and prebuilt
  # dependency artifacts, so common crates (tokio/axum/serde/rusqlite/…)
  # compile only once instead of once per crate. mkvmaker keeps its own
  # standalone build (it has a separate flake and edition 2024).
  workspaceSrcRoot = ../..;
  mkvmakerPrefix = toString (workspaceSrcRoot + "/mkvmaker");
  workspaceFilter = path: type:
    let
      pathStr = toString path;
      rel = lib.removePrefix "${toString workspaceSrcRoot}/" pathStr;
      baseName = builtins.baseNameOf pathStr;
      # crane's filterCargoSources keeps every directory, so generated build
      # output (target/, node_modules/, dist/, coverage/) would otherwise be
      # walked on every evaluation and copied into the store source. Prune
      # those subtrees entirely; they never contain cargo inputs.
      generatedDir = lib.elem baseName [ "target" "node_modules" "dist" "coverage" ];
      topLevelNode = rel == "node" || lib.hasPrefix "node/" rel;
    in
    (! lib.hasPrefix mkvmakerPrefix pathStr)
    && (! lib.hasSuffix "Cargo.lock" pathStr)
    && (! generatedDir)
    && (! topLevelNode)
    && craneLib.filterCargoSources path type;
  workspaceSrc = lib.cleanSourceWith {
    src = workspaceSrcRoot;
    name = "nixhomeserver-rust-workspace-src";
    filter = workspaceFilter;
  };
  # The shared dependency build must depend only on dependency manifests, not
  # on the workspace source. Otherwise any edit to an app .rs file invalidates
  # the single buildDepsOnly derivation and recompiles every dependency.
  workspaceManifests = lib.fileset.toSource {
    root = workspaceSrcRoot;
    fileset = craneLib.fileset.cargoTomlAndLock workspaceSrcRoot;
  };
  cargoLock = ../../Cargo.lock;
  # buildDepsOnly checks every workspace member in one derivation, so it must
  # carry the union of the per-app build inputs (rusqlite links system sqlite).
  # crane fills in dummy crate sources, so only the manifests are required.
  sharedCargoArtifacts = craneLib.buildDepsOnly {
    src = workspaceManifests;
    inherit cargoLock;
    cargoExtraArgs = "--locked";
    pname = "nixhomeserver-rust-workspace-deps";
    version = workspaceVersion;
    strictDeps = true;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.sqlite ];
  };
in
assert builtins.readFile (mailFrontend + "/pnpm-lock.yaml")
  == builtins.readFile (mediaFrontend + "/pnpm-lock.yaml");
assert comparableManifest mailManifest == comparableManifest mediaManifest;
{
  browsertrix-downloader = import ./browsertrix-downloader/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceSrc workspaceVersion sharedCargoArtifacts cargoLock;
  };
  kanidm-canary-bootstrap = import ./kanidm-canary-bootstrap/default.nix {
    inherit rustLib;
    inherit workspaceSrc workspaceVersion sharedCargoArtifacts cargoLock;
  };
  mail-archive-ui = import ./mail-archive-ui/default.nix {
    inherit lib pkgs rustLib sharedFrontendDeps;
    inherit workspaceSrc workspaceVersion sharedCargoArtifacts cargoLock;
  };
  media-manager = import ./media-manager/default.nix {
    inherit lib pkgs rustLib sharedFrontendDeps;
    inherit workspaceSrc workspaceVersion sharedCargoArtifacts cargoLock;
  };
  mkvmaker = import ../../mkvmaker/default.nix {
    inherit lib pkgs rustLib;
  };
  # kanidm-admin is archived in _archive/ and intentionally not packaged in the active app set.
  # Use native `kanidm` CLI commands for identity operations while the archived flow is removed.
}
