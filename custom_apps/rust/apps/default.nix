{ lib, pkgs, rustLib }:

let
  craneLib = rustLib.craneLib;
  workspaceManifest = builtins.fromTOML (builtins.readFile ../../Cargo.toml);
  workspaceVersion = workspaceManifest.workspace.package.version;

  workspaceSrcRoot = ../..;
  mkWorkspaceSource = import ../lib/mk-workspace-source.nix { inherit lib pkgs craneLib; };
  workspaceSource = name: checks: mkWorkspaceSource {
    inherit name cargoLock workspaceManifests;
    workspaceRoot = workspaceSrcRoot;
    excludePrefixes = if checks then [ ] else [ "tests" ] ++ lib.optional (name == "mail-archive-ui") "src/tests.rs";
    extraSourcePrefixes = lib.optional (name == "search") "src/ui.html";
  };
  # mkvmaker is the one workspace member outside rust/apps/, so it names its
  # member path explicitly.
  mkvmakerWorkspaceSource = checks: mkWorkspaceSource {
    name = "mkvmaker";
    memberPath = "mkvmaker";
    inherit cargoLock workspaceManifests;
    workspaceRoot = workspaceSrcRoot;
    excludePrefixes = if checks then [ ] else [ "tests" ];
    extraSourcePrefixes = [ ];
  };
  # The shared dependency build must depend only on dependency manifests, not
  # on the workspace source. Otherwise any edit to an app .rs file invalidates
  # the single buildDepsOnly derivation and recompiles every dependency.
  #
  # Membership is derived from the workspace declaration in custom_apps/Cargo.toml
  # so it can never drift from what Cargo resolves, and so manifests belonging to
  # unrelated projects (the Tauri apps under node/apps/*/src-tauri carry their own
  # Cargo.lock) are excluded: editing one of those must not invalidate this
  # derivation. rustfmt.toml rides along so the workspace-wide style_edition pin
  # reaches the cargoFmt checks.
  manifests = import ../lib/workspace-manifests.nix { inherit lib; } { workspaceRoot = workspaceSrcRoot; };
  workspaceManifests = manifests.source;
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
{
  ai-gate = import ./ai-gate/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "ai-gate" false;
    workspaceCheckSrc = workspaceSource "ai-gate" true;
  };
  browsertrix-downloader = import ./browsertrix-downloader/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "browsertrix-downloader" false;
    workspaceCheckSrc = workspaceSource "browsertrix-downloader" true;
  };
  kanidm-canary-bootstrap = import ./kanidm-canary-bootstrap/default.nix {
    inherit rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "kanidm-canary-bootstrap" false;
    workspaceCheckSrc = workspaceSource "kanidm-canary-bootstrap" true;
  };
  mail-archive-ui = import ./mail-archive-ui/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "mail-archive-ui" false;
    workspaceCheckSrc = workspaceSource "mail-archive-ui" true;
  };
  filesync-api = import ./filesync-api/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "filesync-api" false;
    workspaceCheckSrc = workspaceSource "filesync-api" true;
  };
  ipfs-alias = import ./ipfs-alias/default.nix {
    inherit rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "ipfs-alias" false;
    workspaceCheckSrc = workspaceSource "ipfs-alias" true;
  };
  media-manager = import ./media-manager/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "media-manager" false;
    workspaceCheckSrc = workspaceSource "media-manager" true;
  };
  opencloud-share-gate = import ./opencloud-share-gate/default.nix {
    inherit rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "opencloud-share-gate" false;
    workspaceCheckSrc = workspaceSource "opencloud-share-gate" true;
  };
  search = import ./search/default.nix {
    inherit pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "search" false;
    workspaceCheckSrc = workspaceSource "search" true;
  };
  mkvmaker = import ../../mkvmaker/default.nix {
    inherit lib pkgs rustLib workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = mkvmakerWorkspaceSource false;
    workspaceCheckSrc = mkvmakerWorkspaceSource true;
  };
  # kanidm-admin is archived in _archive/ and intentionally not packaged in the active app set.
  # Use native `kanidm` CLI commands for identity operations while the archived flow is removed.
}
