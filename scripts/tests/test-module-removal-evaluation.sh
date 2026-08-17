#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

# Deriving variants from the module tree makes adding a module automatically
# add its independent-removal evaluation. App-owned secrets and guarded units
# are asserted by the matrix from the central module catalog.
variants=(core-only)
for module_dir in modules/*/; do
  # builtins.readDir reports symlinks as "symlink", not "directory".
  module_path="${module_dir%/}"
  [[ -d "$module_path" && ! -L "$module_path" ]] || continue
  module_name="$module_path"
  module_name="${module_name##*/}"
  case "$module_name" in
    Core_Modules | Integrations | homepage | power-management)
      continue
      ;;
  esac
  variants+=("without-${module_name}")
done

batch_size=4
for ((offset = 0; offset < ${#variants[@]}; offset += batch_size)); do
  batch=("${variants[@]:offset:batch_size}")
  batch_csv="$(IFS=,; echo "${batch[*]}")"
  expected_keys="$(jq -cn '$ARGS.positional | sort' --args "${batch[@]}")"
  echo "Evaluating optional-module variants: $batch_csv"
  matrix_json="$(
    NIXHOMESERVER_MODULE_VARIANTS="$batch_csv" \
      nix eval --impure --json --file scripts/tests/module-removal-matrix.nix
  )"

  jq -e --argjson expected_keys "$expected_keys" '
    keys == $expected_keys
    and all(
      to_entries[];
      (.value.drvPath | startswith("/nix/store/"))
      and .value.valid
      and .value.removedOwnedSecretsAbsent
      and .value.guardedServicesValid
      and .value.removedGuardedServicesAbsent
      and (.value.registry == (
        (.value.selected + ["homepage"])
        | unique
        | map({ key: ., value: true })
        | from_entries
      ))
      and (.value.caddyHostCount >= 3)
      and (.value.oauthClientCount >= 3)
      and (
        .value.mediaAutomationSurface as $media
        | if ($media.mediaApps | length) > 0 then
            $media.mediaLayoutPresent
            and $media.mediaGroupPresent
            and $media.selectedServicesUseLayout
            and $media.layoutHasRequiredVideoRoots
            and $media.layoutHasQbittorrentRoot
          else
            ($media.mediaLayoutPresent | not)
            and ($media.mediaGroupPresent | not)
          end
      )
      and (
        if (.value.selected | index("jellyfin")) == null then
          (.value.mediaAutomationSurface.referencesJellyfinLayout | not)
        else
          true
        end
      )
    )
    and ((."core-only"? // { selected: [], registry: { homepage: true } })
      | .selected == [] and .registry == { homepage: true })
  ' <<<"$matrix_json" >/dev/null || {
    echo "❌ Optional-module removal matrix failed structural validation."
    jq . <<<"$matrix_json"
    exit 1
  }

  if [[ " $batch_csv " == *"without-offline-music"* ]]; then
    jq -e '."without-offline-music".offlineMediaSurface == {
      syncthingEnabled: false,
      gatewayRegistered: false,
      homepageEnvironmentPresent: false,
      disabledCleanupPresent: true,
      dedicatedAccessGroupPresent: false,
      dedicatedGatewayScopePresent: false,
      dedicatedHomepageScopePresent: false
    }' <<<"$matrix_json" >/dev/null || {
      echo "❌ Removing offline-music left active surfaces enabled or omitted the safe persistent-config cleanup."
      jq '."without-offline-music".offlineMediaSurface' <<<"$matrix_json"
      exit 1
    }
  fi

done

prowlarr_only_json="$(
  NIXHOMESERVER_MODULE_VARIANTS=prowlarr-only \
    nix eval --impure --json --file scripts/tests/module-removal-matrix.nix
)"

jq -e '."prowlarr-only" as $variant
  | $variant.valid
  and ($variant.selected == ["prowlarr"])
  and ($variant.registry == { homepage: true, prowlarr: true })
  and ($variant.mediaAutomationSurface.mediaLayoutPresent == false)
  and ($variant.mediaAutomationSurface.mediaGroupPresent == false)
' <<<"$prowlarr_only_json" >/dev/null || {
  echo "❌ Prowlarr-only configuration retained invalid media-layout dependencies."
  jq . <<<"$prowlarr_only_json"
  exit 1
}

echo "✅ All optional modules can be removed independently without evaluation failure."
