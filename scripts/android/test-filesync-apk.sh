#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: $0 <signed-filesync.apk> <result-directory>" >&2
  exit 2
fi

apk="$(readlink -f "$1")"
results="$(readlink -m "$2")"
[[ -s "$apk" ]] || { echo "APK does not exist: $apk" >&2; exit 1; }
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || {
  echo "Android emulator needs usable /dev/kvm" >&2
  exit 1
}
[[ -n "${ANDROID_HOME:-}" ]] || {
  echo "Run inside nix develop .#filesync-android-emulator" >&2
  exit 1
}

cmdline_tools=("$ANDROID_HOME"/cmdline-tools/*/bin/avdmanager)
avdmanager="${cmdline_tools[0]}"
emulator="$ANDROID_HOME/emulator/emulator"
adb="$ANDROID_HOME/platform-tools/adb"
for tool in "$avdmanager" "$emulator" "$adb"; do
  [[ -x "$tool" ]] || { echo "Android tool is missing: $tool" >&2; exit 1; }
done

serial='emulator-5584'
if "$adb" devices | grep -q "^${serial}[[:space:]]"; then
  echo "Emulator port 5584 is already in use" >&2
  exit 1
fi

mkdir -p "$results"
chmod 0700 "$results"
work_dir="$(mktemp -d /var/tmp/filesync-emulator.XXXXXX)"
emulator_pid=''
cleanup() {
  if [[ -n "$emulator_pid" ]]; then
    "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
    wait "$emulator_pid" 2>/dev/null || true
  fi
  rm -rf "$work_dir"
}
trap cleanup EXIT

export ANDROID_USER_HOME="$work_dir/android"
export ANDROID_AVD_HOME="$work_dir/avd"
mkdir -p "$ANDROID_USER_HOME" "$ANDROID_AVD_HOME"

# Android 11 Google APIs x86_64 supports ARM64 app translation. This tests
# the signed phone APK instead of a separately built x86 client.
# https://android-developers.googleblog.com/2020/03/run-arm-apps-on-android-emulator.html
printf 'no\n' | "$avdmanager" create avd \
  -n filesync-api30 -k 'system-images;android-30;google_apis;x86_64' \
  -p "$work_dir/device" >"$results/avd-create.log" 2>&1

# -no-window is Android's documented headless server mode.
# https://developer.android.com/studio/run/emulator-commandline#common
"$emulator" -avd filesync-api30 -port 5584 -no-window -no-audio \
  -no-snapshot -accel on >"$results/emulator.log" 2>&1 &
emulator_pid=$!

booted=false
for _ in {1..90}; do
  if [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
    booted=true
    break
  fi
  if ! kill -0 "$emulator_pid" 2>/dev/null; then
    echo "Emulator exited before Android booted; see $results/emulator.log" >&2
    exit 1
  fi
  sleep 2
done
[[ "$booted" == true ]] || { echo "Android did not boot within 180 seconds" >&2; exit 1; }

"$adb" -s "$serial" install "$apk" >"$results/install.log"
"$adb" -s "$serial" logcat -c
"$adb" -s "$serial" shell am start -W \
  -n org.nixhomeserver.filesync/.MainActivity >"$results/launch.log"
sleep 10
"$adb" -s "$serial" logcat -d -v threadtime >"$results/logcat.log"
"$adb" -s "$serial" logcat -d -b crash >"$results/crash.log"
"$adb" -s "$serial" exec-out screencap -p >"$results/screen.png"
if [[ -z "$("$adb" -s "$serial" shell pidof org.nixhomeserver.filesync 2>/dev/null | tr -d '\r')" ]]; then
  echo "File Sync exited after launch; see $results/crash.log" >&2
  exit 1
fi
if [[ -s "$results/crash.log" ]]; then
  echo "Android recorded a crash; see $results/crash.log" >&2
  exit 1
fi
echo "File Sync remained running after launch; screenshot: $results/screen.png"
