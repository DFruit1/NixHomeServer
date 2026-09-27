#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mapping="$app_dir/src-tauri/gen/android/app/build/outputs/mapping/universalRelease/mapping.txt"
apk="$app_dir/src-tauri/gen/android/app/build/outputs/apk/universal/release/app-universal-release-unsigned.apk"
plugin="$app_dir/src-tauri/plugins/tauri-plugin-mobile-files/android/src/main/java/MobileFilesPlugin.kt"

test -s "$mapping" || { echo "Build the Android release APK first: missing R8 mapping" >&2; exit 1; }
test -s "$apk" || { echo "Build the Android release APK first: missing APK" >&2; exit 1; }

mapfile -t commands < <(sed -n '/^[[:space:]]*@Command$/ { n; s/^[[:space:]]*fun \([[:alnum:]_]*\)(.*/\1/p; }' "$plugin")
test "${#commands[@]}" -gt 0 || { echo "No Android plugin commands found" >&2; exit 1; }
for command in "${commands[@]}" folderPicked; do
  signature='app\.tauri\.plugin\.Invoke'
  if [[ "$command" == folderPicked ]]; then signature='app\.tauri\.plugin\.Invoke,androidx\.activity\.result\.ActivityResult'; fi
  if ! rg -q "void ${command}\\(${signature}\\):.* -> ${command}$" "$mapping"; then
    echo "R8 removed or renamed native command: $command" >&2
    exit 1
  fi
done

if ! unzip -Z1 "$apk" | rg '^lib/arm64-v8a/libfilesync_lib\.so$' >/dev/null; then
  echo "Android release APK is missing its ARM64 Rust library" >&2
  exit 1
fi

echo "Android release retains ${#commands[@]} native commands, folder callback, and the ARM64 Rust library."
