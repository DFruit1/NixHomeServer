#!/usr/bin/env bash
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apk="$app_dir/src-tauri/gen/android/app/build/outputs/apk/universal/release/app-universal-release-unsigned.apk"
plugin="$app_dir/src-tauri/plugins/tauri-plugin-mobile-files/android/src/main/java/MobileFilesPlugin.kt"

test -s "$apk" || { echo "Build the Android release APK first: missing APK" >&2; exit 1; }
dex_strings="$(mktemp)"
trap 'rm -f "$dex_strings"' EXIT
mapfile -t dex_files < <(unzip -Z1 "$apk" | rg '^classes[0-9]*\.dex$')
test "${#dex_files[@]}" -gt 0 || { echo "Android release APK has no DEX bytecode" >&2; exit 1; }
for dex in "${dex_files[@]}"; do
  unzip -p "$apk" "$dex" | strings >> "$dex_strings"
done

mapfile -t commands < <(sed -n '/^[[:space:]]*@Command$/ { n; s/^[[:space:]]*fun \([[:alnum:]_]*\)(.*/\1/p; }' "$plugin")
test "${#commands[@]}" -gt 0 || { echo "No Android plugin commands found" >&2; exit 1; }
for command in "${commands[@]}" folderPicked; do
  if ! rg -Fxq "$command" "$dex_strings"; then
    echo "Android release APK is missing native command or callback: $command" >&2
    exit 1
  fi
done
if ! rg -Fq 'Lorg/nixhomeserver/filesync/mobilefiles/MobileFilesPlugin;' "$dex_strings"; then
  echo "Android release APK is missing the native plugin class" >&2
  exit 1
fi

if ! unzip -Z1 "$apk" | rg '^lib/arm64-v8a/libfilesync_lib\.so$' >/dev/null; then
  echo "Android release APK is missing its ARM64 Rust library" >&2
  exit 1
fi

echo "Android release contains ${#commands[@]} native commands, folder callback, plugin class, and the ARM64 Rust library."
