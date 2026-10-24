#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"

if [[ "${NIXHOMESERVER_SKIP_NESTED_BUILDS:-0}" != "1" ]]; then
  homepage_config="$(
    nix build --impure --no-link --print-out-paths --expr "
      let f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      in f.nixosConfigurations.${host}.config.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE
    "
  )"
  sftp_installer="$(
    nix build --impure --no-link --print-out-paths --expr "
      let f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      in f.nixosConfigurations.${host}.config.systemd.services.homepage.environment.HOMEPAGE_SFTP_KEY_INSTALL_COMMAND
    "
  )"

  jq -e '
  (.adminUsers | type == "array" and length == 1)
  and (.adminGroups | type == "array")
  and (.sftp.enabled == true)
  and (.sftp.host | type == "string" and length > 0)
  and (.sftp.port | type == "number" and . > 0 and . < 65536)
  and (.sftp.requiredAnyGroups | length > 0)
  and (.offlineMedia.requiredAnyGroups | length > 0)
  and ([.services[] | select(.id != "passwords") | (.requiredAnyGroups // []) | length > 0] | all)
' "$homepage_config" >/dev/null || {
    echo "Homepage evaluated access configuration regressed." >&2
    jq . "$homepage_config" >&2
    exit 1
  }

  for required_fragment in 'flock -x 9' 'registered-keys=' 'at most 10 SFTP device keys' 'ssh-keygen -l -f'; do
    if ! rg -Fq "$required_fragment" "$sftp_installer"; then
      echo "SFTP multi-device key safety regressed: missing $required_fragment" >&2
      exit 1
    fi
  done

  key_validation_line="$(rg -n -F 'ssh-keygen -l -f' "$sftp_installer" | head -n 1 | cut -d: -f1)"
  key_storage_line="$(rg -n -F 'install -d -m 0755' "$sftp_installer" | head -n 1 | cut -d: -f1)"
  if [[ -z "$key_validation_line" || -z "$key_storage_line" || "$key_validation_line" -ge "$key_storage_line" ]]; then
    echo "SFTP key structure must be verified before the authorized-keys directory or file is changed." >&2
    exit 1
  fi
  if invalid_key_output="$(
    printf '%s\n' 'ssh-ed25519 AAAA syntactically-plausible-but-corrupt' \
      | "$sftp_installer" homepage-validation-user 2>&1
  )"; then
    echo "SFTP installer accepted a structurally invalid public key." >&2
    exit 1
  fi
  if [[ "$invalid_key_output" != *"invalid or corrupted OpenSSH public key"* ]]; then
    echo "SFTP installer did not report structural public-key validation failure." >&2
    printf '%s\n' "$invalid_key_output" >&2
    exit 1
  fi

  removal_matrix="$(
    NIXHOMESERVER_MODULE_VARIANTS='without-files' \
      nix eval --impure --json --file scripts/tests/module-removal-matrix.nix
  )"
  text_derivation_payload() {
    nix derivation show "$1" | jq -er '
      (if has("derivations") then .derivations else . end)
      | to_entries
      | if length == 1 and (.[0].value.env.text | type) == "string" then
          .[0].value.env.text
        else
          error("expected exactly one Homepage writeText derivation")
        end
    '
  }
  without_files_drv="$(jq -er '."without-files".homepageConfigDrv' <<<"$removal_matrix")"
  without_files_homepage_config="$(text_derivation_payload "$without_files_drv")"
  if ! jq -e '
    (.sftp.enabled == true)
    and ([.services[] | select(.id == "files" and .enabled == true)] | length == 0)
  ' <<<"$without_files_homepage_config" >/dev/null; then
    echo "Removing optional Filestash disabled the Core SFTP self-service surface or left Files advertised." >&2
    exit 1
  fi
fi

require_fixed custom_apps/node/apps/homepage/src/server/http.ts 'assertFeatureAccess(user, config.homepage.sftp.requiredAllGroups, config.homepage.sftp.requiredAnyGroups)' \
  "SFTP key mutation must enforce the evaluated SFTP access groups."
require_fixed custom_apps/node/apps/homepage/src/server/http.ts 'assertFeatureAccess(user, config.homepage.offlineMedia?.requiredAllGroups, config.homepage.offlineMedia?.requiredAnyGroups)' \
  "Offline-media APIs must enforce the evaluated access groups."
echo "✅ Homepage access configuration and authorization regression tests passed."
