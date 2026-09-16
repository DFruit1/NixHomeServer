#!/usr/bin/env bash
# Build the debug Android APK reproducibly.
#
# Run directly from a checkout; the script re-execs itself inside the pinned
# Nix dev shell when the Android toolchain is not already present.
set -euo pipefail

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
app_dir="$(dirname "$script_path")"

if [[ -z "${AAPT2:-}" ]]; then
  repo_root="$(git -C "$app_dir" rev-parse --show-toplevel)"
  exec nix develop "$repo_root#devShells.$(uname -m)-linux.youtube-downloader-tauri" \
    --command bash "$script_path" "$@"
fi

cd "$app_dir"

pnpm install --frozen-lockfile

if [[ ! -d src-tauri/gen/android ]]; then
  cargo tauri android init --ci --skip-targets-install
fi

# AGP's Maven aapt2 cannot exec on NixOS; point it at the Nix build-tools copy
# for the duration of the build, then restore the tracked file.
gradle_properties="src-tauri/gen/android/gradle.properties"
backup="$(mktemp)"
cp "$gradle_properties" "$backup"
trap 'cp "$backup" "$gradle_properties"; rm -f "$backup"' EXIT
printf '\nandroid.aapt2FromMavenOverride=%s\n' "$AAPT2" >>"$gradle_properties"

cargo tauri android build --debug --apk --target aarch64

apk="src-tauri/gen/android/app/build/outputs/apk/universal/debug/app-universal-debug.apk"
echo "APK: $app_dir/$apk"
