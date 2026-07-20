#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

validation_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    paths = import ./lib/storage-validation.nix { inherit lib; };
  in {
    acceptsMountComponent = paths.validPathComponent "_Shared";
    acceptsInternalComponent = paths.validPathComponent ".internal-sync";
    rejectsDotComponent = !paths.validPathComponent ".";
    rejectsDotDotComponent = !paths.validPathComponent "..";
    rejectsComponentSlash = !paths.validPathComponent "_Shared/escape";
    rejectsComponentWhitespace = !paths.validPathComponent "_Shared view";
    acceptsNestedRelative = paths.validRelativePath "_Videos/_YouTube";
    acceptsInternalRelative = paths.validRelativePath "_Emails/.internal-sync";
    rejectsRelativeTraversal = !paths.validRelativePath "_Videos/../../etc";
    rejectsAbsoluteAsRelative = !paths.validRelativePath "/etc";
    rejectsEmptyRelativeComponent = !paths.validRelativePath "_Videos//Other";
    rejectsRelativeControlCharacter = !paths.validRelativePath "_Videos\nOther";
    acceptsNormalizedAbsolute = paths.validAbsolutePath "/srv/files-sftp/chroots";
    rejectsRootAbsolute = !paths.validAbsolutePath "/";
    rejectsAbsoluteTraversal = !paths.validAbsolutePath "/srv/files-sftp/../etc";
    rejectsRepeatedAbsoluteSlash = !paths.validAbsolutePath "/srv//chroots";
    rejectsAbsoluteWhitespace = !paths.validAbsolutePath "/srv/files sftp/chroots";
  }
')"

jq -e 'all(.[]; . == true)' <<<"$validation_json" >/dev/null || {
  echo "❌ Storage path validator accepted an unsafe value or rejected a repository path." >&2
  jq . <<<"$validation_json" >&2
  exit 1
}

assertion_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
    packages = import ./flake/packages.nix {
      inherit lib pkgs;
      crane = f.inputs.crane;
    };
    messagesFor = vars:
      let
        system = import ./flake/system.nix {
          inputs = f.inputs;
          inherit lib vars pkgs;
          system = base.hostPlatform;
          appPackages = packages.appPackages;
        };
        host = system.nixosConfigurations.${vars.hostname};
      in map (entry: entry.message) (builtins.filter (entry: !entry.assertion) host.config.assertions);
    baseMessages = messagesFor base;
    onlyNewFailures = vars: lib.subtractLists baseMessages (messagesFor vars);
    baseSystem = import ./flake/system.nix {
      inputs = f.inputs;
      vars = base;
      inherit lib pkgs;
      system = base.hostPlatform;
      appPackages = packages.appPackages;
    };
    invalidInternalHost = baseSystem.nixosConfigurations.${base.hostname}.extendModules {
      modules = [{
        repo.storage.userRoots.recursiveReadonlyGrants = [{
          group = "syncthing";
          relativePaths = [ "../../etc" ];
        }];
      }];
    };
  in {
    sharedMount = onlyNewFailures (base // {
      fileAccess = base.fileAccess // { sharedMountName = "../escape"; };
    });
    usbMount = onlyNewFailures (base // {
      fileAccess = base.fileAccess // { usbMountName = "USB view"; };
    });
    backupMount = onlyNewFailures (base // {
      backupAccess = base.backupAccess // { storageMountName = "../../persist"; };
    });
    sftpRoot = onlyNewFailures (base // {
      fileAccess = base.fileAccess // { sftpChrootBase = "/etc"; };
    });
    offlineFolder = onlyNewFailures (base // {
      offlineMedia = base.offlineMedia // { musicFolderName = "../../etc"; };
    });
    offlineState = onlyNewFailures (base // {
      offlineMedia = base.offlineMedia // { stateDir = "/persist/appdata/../etc"; };
    });
    internalRelative = lib.subtractLists baseMessages (
      map (entry: entry.message)
        (builtins.filter (entry: !entry.assertion) invalidInternalHost.config.assertions)
    );
  }
')"

jq -e '
  (.sharedMount | any(contains("fileAccess.sharedMountName must be one safe path component")))
  and (.usbMount | any(contains("fileAccess.usbMountName must be one safe path component")))
  and (.backupMount | any(contains("backupAccess.storageMountName must be one safe path component")))
  and (.sftpRoot | any(contains("fileAccess.sftpChrootBase must be a normalized absolute path below /srv")))
  and (.offlineFolder | any(contains("offlineMedia folder relativePath values must be normalized safe relative paths")))
  and (.offlineState | any(contains("offlineMedia.stateDir must be a normalized absolute child of /persist/appdata")))
  and (.internalRelative | any(contains("repo.storage.userRoots relative paths must be normalized safe relative paths")))
' <<<"$assertion_json" >/dev/null || {
  echo "❌ Unsafe storage paths did not produce every actionable full-system assertion." >&2
  jq . <<<"$assertion_json" >&2
  exit 1
}

echo "✅ Root-run storage and offline-media path validation tests passed."
