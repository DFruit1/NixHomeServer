{ lib, pkgs, rustLib }:

let
  craneLib = rustLib.craneLib;
  workspaceManifest = builtins.fromTOML (builtins.readFile ../../Cargo.toml);
  workspaceVersion = workspaceManifest.workspace.package.version;

  workspaceSrcRoot = ../..;
  mkWorkspaceSource = import ../lib/mk-workspace-source.nix { inherit lib pkgs craneLib; };
  workspaceSource = name: mkWorkspaceSource {
    inherit name cargoLock workspaceManifests;
    workspaceRoot = workspaceSrcRoot;
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
{
  ai-gate = import ./ai-gate/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "ai-gate";
  };
  browsertrix-downloader = import ./browsertrix-downloader/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "browsertrix-downloader";
  };
  kanidm-canary-bootstrap = import ./kanidm-canary-bootstrap/default.nix {
    inherit rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "kanidm-canary-bootstrap";
  };
  mail-archive-ui = import ./mail-archive-ui/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "mail-archive-ui";
  };
  media-manager = import ./media-manager/default.nix {
    inherit lib pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "media-manager";
  };
  search = import ./search/default.nix {
    inherit pkgs rustLib;
    inherit workspaceVersion sharedCargoArtifacts cargoLock;
    workspaceSrc = workspaceSource "search";
  };
  mkvmaker = import ../../mkvmaker/default.nix {
    inherit lib pkgs rustLib;
  };
  # kanidm-admin is archived in _archive/ and intentionally not packaged in the active app set.
  # Use native `kanidm` CLI commands for identity operations while the archived flow is removed.
}
