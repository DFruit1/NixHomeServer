#!/usr/bin/env bash
# Build, verify, sign, and publish an Android app. This is shell orchestration
# around Tauri, Android build tools, and the server's existing F-Droid units.
set -euo pipefail

if [[ "$#" -lt 1 || "$#" -gt 2 || ( "$#" == 2 && "$2" != "--build-only" ) ]]; then
  echo "Usage: $0 <filesync|youtube-downloader> [--build-only]" >&2
  exit 2
fi
app="$1"
build_only="${2:-}"
case "$app" in
  filesync) shell="filesync-tauri"; test_command="test" ;;
  youtube-downloader) shell="youtube-downloader-tauri"; test_command="check" ;;
  *) echo "Unsupported Android app: $app" >&2; exit 2 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_path="$repo_root/scripts/release-android-app.sh"
if [[ -z "${AAPT2:-}" ]]; then
  exec nix develop --fallback "$repo_root#$shell" --command bash "$script_path" "$@"
fi

app_dir="$repo_root/custom_apps/node/apps/$app"
cd "$app_dir"
pnpm install --frozen-lockfile
pnpm "$test_command"

package_version="$(node -p 'JSON.parse(require("node:fs").readFileSync("package.json", "utf8")).version')"
tauri_version="$(node -p 'JSON.parse(require("node:fs").readFileSync("src-tauri/tauri.conf.json", "utf8")).version')"
[[ "$package_version" == "$tauri_version" ]] || {
  echo "Update both package.json and tauri.conf.json to the same release version" >&2
  exit 1
}
[[ -f "$HOME/.android/debug.keystore" ]] || {
  echo "The existing Android signing key is unavailable at ~/.android/debug.keystore" >&2
  exit 1
}

if [[ ! -d src-tauri/gen/android ]]; then
  cargo tauri android init --ci --skip-targets-install
fi

# AGP's downloaded aapt2 cannot run on NixOS. Restore the tracked Gradle file
# even if the build fails or a later publication check rejects the APK.
gradle_properties="src-tauri/gen/android/gradle.properties"
backup="$(mktemp)"
cp "$gradle_properties" "$backup"
trap 'cp "$backup" "$gradle_properties"; rm -f "$backup"' EXIT
printf '\nandroid.aapt2FromMavenOverride=%s\n' "$AAPT2" >>"$gradle_properties"

cargo tauri android build --apk --target aarch64 --ci
cp "$backup" "$gradle_properties"
rm -f "$backup"
trap - EXIT

if [[ "$app" == filesync ]]; then
  pnpm test:android-release
fi

release_dir="src-tauri/gen/android/app/build/outputs/apk/universal/release"
unsigned_apk="$release_dir/app-universal-release-unsigned.apk"
aligned_apk="$release_dir/app-universal-release-aligned.apk"
signed_apk="$release_dir/app-universal-release.apk"
build_tools="${ANDROID_HOME:?Android SDK is missing}/build-tools/35.0.0"
"$build_tools/zipalign" -f -p 4 "$unsigned_apk" "$aligned_apk"
"$build_tools/apksigner" sign \
  --ks "$HOME/.android/debug.keystore" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --ks-key-alias androiddebugkey \
  --out "$signed_apk" "$aligned_apk"
"$build_tools/apksigner" verify "$signed_apk"

echo "APK: $app_dir/$signed_apk"
if [[ "$build_only" != "--build-only" ]]; then
  bash "$repo_root/scripts/publish-android-apk.sh" "$app" "$app_dir/$signed_apk"
fi
