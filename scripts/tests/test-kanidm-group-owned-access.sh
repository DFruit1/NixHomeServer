#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

if rg -n \
  'backupAccess\.(adminUsers|storageUsers)|fileAccess\.usbUsers|vars\.(kanidmBackupUsers|fileAccessUsbUsers)' \
  lib modules custom_apps/node/apps/homepage; then
  echo "❌ Removed vars-owned access membership still appears in production code or Homepage fixtures." >&2
  exit 1
fi

host="$(test_default_host)"
access_json="$(
  NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
      let
        f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
        cfg = f.nixosConfigurations.${builtins.getEnv "NIXHOMESERVER_TEST_HOST"}.config;
        groups = cfg.services.kanidm.provision.groups;
        names = [
          "files-personal-users"
          "files-sftp-users"
          "files-shared-users"
          "delete_shared_files"
          "usb-access"
          "backup-admin"
          "backup-storage-users"
        ];
      in {
        accessGroups = builtins.listToAttrs (map
          (name: {
            inherit name;
            value = {
              members = groups.${name}.members;
              overwriteMembers = groups.${name}.overwriteMembers;
            };
          })
          names);
      }
  '
)"

jq -e '
  all(.accessGroups[]; (.members == []) and (.overwriteMembers == false))
' <<<"$access_json" >/dev/null || {
  echo "❌ File or backup access is not fully owned by Kanidm group membership." >&2
  jq . <<<"$access_json" >&2
  exit 1
}

echo "✅ File and backup authorization membership is Kanidm-group-owned."
