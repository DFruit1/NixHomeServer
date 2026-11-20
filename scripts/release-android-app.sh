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
# File Sync publishes every rebuild, so its display version must advance with the
# version code instead of staying at the last hand-edited value.
case "$app" in
  filesync) shell="filesync-tauri"; test_command="test"; bump_display_version=1 ;;
  youtube-downloader) shell="youtube-downloader-tauri"; test_command="check"; bump_display_version=0 ;;
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

# Every published build needs a higher Android version code, and File Sync also
# needs a higher display version than the live repository shows. Query the live
# repository before spending time building; publication still rechecks the code
# and signing key.
android_config=()
if [[ "$build_only" != "--build-only" ]]; then
  # shellcheck source=scripts/helpers/repo-common.sh
  source "$repo_root/scripts/helpers/repo-common.sh"
  init_repo_root
  ensure_default_nix_config
  domain="$(nix_flake_json 'vars.domain' | node -p 'JSON.parse(require("node:fs").readFileSync(0, "utf8"))')"
  release_metadata="$(node --input-type=module - "https://fdroid.$domain/fdroid/repo/index-v2.json" "$bump_display_version" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';

const parseVersion = (value) => {
  const parts = /^(\d+)\.(\d+)\.(\d+)$/.exec(value ?? '');
  return parts ? parts.slice(1).map(Number) : null;
};
const compareVersions = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2];
const incrementVersion = ([major, minor, patch]) => {
  if (patch < 999) return [major, minor, patch + 1];
  if (minor < 999) return [major, minor + 1, 0];
  return [major + 1, 0, 0];
};
const writeVersion = (path, version, pattern) => {
  const text = readFileSync(path, 'utf8');
  const updated = text.replace(pattern, (_match, prefix, suffix) => `${prefix}${version}${suffix}`);
  if (updated === text) throw new Error(`No release version found in ${path}`);
  writeFileSync(path, updated);
};

const [, , indexUrl, bumpDisplayVersion] = process.argv;
const packageJson = JSON.parse(readFileSync('package.json', 'utf8'));
const config = JSON.parse(readFileSync('src-tauri/tauri.conf.json', 'utf8'));
if (packageJson.version !== config.version) {
  throw new Error('package.json and src-tauri/tauri.conf.json must share one release version');
}
const sourceVersion = parseVersion(config.version);
if (!sourceVersion || sourceVersion[1] > 999 || sourceVersion[2] > 999) {
  throw new Error('Automatic Android releases require a numeric major.minor.patch version (minor/patch <= 999)');
}
const sourceCode = config.bundle?.android?.versionCode
  ?? (sourceVersion[0] * 1000000 + sourceVersion[1] * 1000 + sourceVersion[2]);

const response = await fetch(indexUrl, { signal: AbortSignal.timeout(20000) });
if (!response.ok) throw new Error(`Cannot read F-Droid index: HTTP ${response.status}`);
const index = await response.json();
if (!index.packages || typeof index.packages !== 'object') throw new Error('Invalid F-Droid index');
const published = Object.values(index.packages[config.identifier]?.versions ?? {});
const codes = published.map((entry) => entry.manifest.versionCode);
if (![sourceCode, ...codes].every((code) => Number.isSafeInteger(code) && code >= 1 && code <= 2100000000)) {
  throw new Error('Invalid Android version code in source or F-Droid index');
}
const nextCode = Math.max(sourceCode, Math.max(0, ...codes) + 1);
if (nextCode > 2100000000) throw new Error('Android version code limit reached');

let releaseVersion = config.version;
if (bumpDisplayVersion === '1' && published.length > 0) {
  const liveVersions = published.map((entry) => parseVersion(entry.manifest.versionName));
  if (liveVersions.every((versions) => versions === null)) {
    throw new Error('The live F-Droid release has no numeric major.minor.patch display version');
  }
  const highestLive = liveVersions
    .filter(Boolean)
    .reduce((best, candidate) => (compareVersions(candidate, best) > 0 ? candidate : best));
  const nextVersion = compareVersions(sourceVersion, highestLive) > 0
    ? sourceVersion
    : incrementVersion(highestLive);
  releaseVersion = nextVersion.join('.');
}
if (releaseVersion !== config.version) {
  writeVersion('package.json', releaseVersion, /("version"\s*:\s*")[^"]+(")/);
  writeVersion('src-tauri/tauri.conf.json', releaseVersion, /("version"\s*:\s*")[^"]+(")/);
  const cargoPath = 'src-tauri/Cargo.toml';
  const cargo = readFileSync(cargoPath, 'utf8');
  const crateVersions = [...cargo.matchAll(/^version\s*=\s*"([^"]+)"/gm)];
  if (crateVersions.length !== 1 || crateVersions[0][1] !== config.version) {
    throw new Error('src-tauri/Cargo.toml must declare the same release version as the app metadata');
  }
  writeVersion(cargoPath, releaseVersion, /^(version\s*=\s*")[^"]+(")/m);
}
console.log(JSON.stringify({ version: releaseVersion, versionCode: nextCode }));
JS
  )"
  release_version="$(node -p 'JSON.parse(require("node:fs").readFileSync(0, "utf8")).version' <<<"$release_metadata")"
  version_code="$(node -p 'JSON.parse(require("node:fs").readFileSync(0, "utf8")).versionCode' <<<"$release_metadata")"
  if [[ "$release_version" != "$package_version" ]]; then
    echo "Bumped the published display version from $package_version to $release_version;"
    echo "commit the updated version files (including src-tauri/Cargo.lock) with this release."
  fi
  echo "Publishing $release_version with Android version code $version_code"
  android_config=(--config "{\"bundle\":{\"android\":{\"versionCode\":$version_code,\"autoIncrementVersionCode\":false}}}")
fi

if [[ ! -d src-tauri/gen/android ]]; then
  cargo tauri android init --ci --skip-targets-install
fi

# AGP's downloaded aapt2 cannot run on NixOS. Restore the tracked Gradle file
# even if the build fails or a later publication check rejects the APK.
gradle_properties="src-tauri/gen/android/gradle.properties"
work_dir="$(mktemp -d /tmp/android-release-XXXXXX)"
backup="$work_dir/gradle.properties"
cp "$gradle_properties" "$backup"
trap 'cp "$backup" "$gradle_properties"; rm -rf "$work_dir"' EXIT
printf '\nandroid.aapt2FromMavenOverride=%s\n' "$AAPT2" >>"$gradle_properties"

cargo tauri android build --apk --target aarch64 --ci "${android_config[@]}"
cp "$backup" "$gradle_properties"
rm -rf "$work_dir"
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
