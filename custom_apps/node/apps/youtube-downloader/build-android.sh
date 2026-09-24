#!/usr/bin/env bash
# Build the Android APK reproducibly.
#
# Produces a size-optimised release APK (roughly 15 MB versus ~165 MB for a
# debug build) and signs it with the local Android debug keystore so it can be
# sideloaded. Run directly from a checkout; the script re-execs itself inside
# the pinned Nix dev shell when the Android toolchain is not already present.
#
# Release flow: bump `version` and `versionDate` in package.json, deploy the
# server, run this script, then place the APK at
# /var/lib/youtube-downloader/app/youtube-downloader.apk.
set -euo pipefail

script_path="$(readlink -f "${BASH_SOURCE[0]}")"
app_dir="$(dirname "$script_path")"

if [[ -z "${AAPT2:-}" ]]; then
  repo_root="$(git -C "$app_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    repo_root="$(cd "$app_dir/../../../.." && pwd)"
  fi
  exec nix develop "$repo_root#devShells.$(uname -m)-linux.youtube-downloader-tauri" \
    --command bash "$script_path" "$@"
fi

cd "$app_dir"

pnpm install --frozen-lockfile

# package.json is the release source of truth; keep tauri.conf.json (the
# Android versionCode input) in lockstep so upgrades install cleanly.
node <<'EOF'
const fs = require('node:fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
const confPath = 'src-tauri/tauri.conf.json';
const conf = JSON.parse(fs.readFileSync(confPath, 'utf8'));
if (conf.version !== pkg.version) {
  console.log(`Syncing tauri.conf.json version: ${conf.version} -> ${pkg.version}`);
  conf.version = pkg.version;
  fs.writeFileSync(confPath, `${JSON.stringify(conf, null, 2)}\n`);
}
EOF

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

cargo tauri android build --apk --target aarch64

release_dir="src-tauri/gen/android/app/build/outputs/apk/universal/release"
unsigned_apk="$release_dir/app-universal-release-unsigned.apk"
aligned_apk="$release_dir/app-universal-release-aligned.apk"
signed_apk="$release_dir/app-universal-release.apk"

build_tools="${ANDROID_HOME}/build-tools/35.0.0"
export PATH="${JAVA_HOME}/bin:${PATH}"
"$build_tools/zipalign" -f -p 4 "$unsigned_apk" "$aligned_apk"
"$build_tools/apksigner" sign \
  --ks "${HOME}/.android/debug.keystore" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --ks-key-alias androiddebugkey \
  --out "$signed_apk" "$aligned_apk"

echo "APK: $app_dir/$signed_apk"
