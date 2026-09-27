#!/usr/bin/env bash
# Publish a signed Android release through the server's existing F-Droid and IPFS units.
# shellcheck disable=SC2029 # Remote command arguments intentionally use locally validated values.
set -euo pipefail

if [[ "$#" != 2 ]]; then
  echo "Usage: $0 <filesync|youtube-downloader> <signed.apk>" >&2
  exit 2
fi

app="$1"
apk="$(readlink -f "$2")"
case "$app" in
  filesync)
    app_id="org.nixhomeserver.filesync"
    app_dir="custom_apps/node/apps/filesync"
    destination="/var/lib/fdroidserver/incoming/filesync.apk"
    owner="root"
    group="fdroidserver"
    mode="0644"
    publish_unit="fdroid-filesync-publish.service"
    ;;
  youtube-downloader)
    app_id="org.sydneybasiniot.youtubedownloader"
    app_dir="custom_apps/node/apps/youtube-downloader"
    destination="/var/lib/youtube-downloader/app/youtube-downloader.apk"
    owner="youtube-downloader"
    group="youtube-downloader"
    mode="0640"
    publish_unit="fdroid-youtube-downloader-publish.service"
    ;;
  *) echo "Unsupported Android app: $app" >&2; exit 2 ;;
esac

# shellcheck source=scripts/helpers/repo-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/helpers/repo-common.sh"
repo_root=""
init_repo_root
ensure_default_nix_config
need jq nix curl ssh sha256sum node unzip rg

build_tools="${ANDROID_HOME:?Run in the Android Nix dev shell}/build-tools/35.0.0"
need "$build_tools/aapt" "$build_tools/apksigner"
[[ -f "$apk" && "$apk" == *.apk ]] || { echo "Signed APK not found: $apk" >&2; exit 1; }

app_version="$(node -p 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).version' "$repo_root/$app_dir/package.json")"
tauri_version="$(jq -r '.version' "$repo_root/$app_dir/src-tauri/tauri.conf.json")"
[[ "$app_version" == "$tauri_version" ]] || {
  echo "Package and Tauri versions differ for $app" >&2
  exit 1
}

badge="$("$build_tools/aapt" dump badging "$apk")"
apk_id="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badge")"
version_code="$(sed -n "s/^package: .*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badge")"
version_name="$(sed -n "s/^package: .*versionName='\([^']*\)'.*/\1/p" <<<"$badge")"
[[ "$apk_id" == "$app_id" && "$version_name" == "$app_version" && "$version_code" =~ ^[0-9]+$ ]] || {
  echo "APK identity or version does not match $app release metadata" >&2
  exit 1
}
signer="$("$build_tools/apksigner" verify --print-certs "$apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')"
[[ "$signer" =~ ^[a-f0-9]{64}$ ]] || { echo "APK signature could not be verified" >&2; exit 1; }
if ! unzip -Z1 "$apk" | rg '^lib/arm64-v8a/lib[^/]+\.so$' >/dev/null; then
  echo "APK has no ARM64 native library" >&2
  exit 1
fi
apk_hash="$(sha256sum "$apk" | cut -d' ' -f1)"

settings="$(nix_flake_json '{ domain = vars.domain; user = vars.localAdminUser; serverLanIP = vars.serverLanIP; }')"
domain="$(jq -er '.domain' <<<"$settings")"
target="${NIXHOMESERVER_ANDROID_RELEASE_TARGET:-$(jq -er '.user + "@" + .serverLanIP' <<<"$settings")}"
[[ "$target" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*@[a-zA-Z0-9.:-]+$ ]] || {
  echo "Invalid Android release target" >&2
  exit 1
}
ssh_options=(-T -o BatchMode=yes -o ConnectTimeout=8)
index_url="https://fdroid.$domain/fdroid/repo/index-v2.json"
mirror_url="https://ipfs.$domain/fdroid/repo/index-v2.json"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
curl -fsSL --connect-timeout 8 --max-time 20 "$index_url" -o "$work_dir/current.json"
current_code="$(jq -r --arg id "$app_id" '[.packages[$id].versions[]?.manifest.versionCode] | max // -1' "$work_dir/current.json")"
current_signer="$(jq -r --arg id "$app_id" '.packages[$id].metadata.preferredSigner // ""' "$work_dir/current.json")"
[[ "$current_code" =~ ^-?[0-9]+$ ]] || { echo "Current F-Droid version is invalid" >&2; exit 1; }
if (( version_code <= current_code )); then
  echo "Refusing to publish $app version code $version_code; F-Droid has $current_code" >&2
  exit 1
fi
if [[ -n "$current_signer" && "$signer" != "$current_signer" ]]; then
  echo "Refusing to replace $app: APK signing certificate changed" >&2
  exit 1
fi

ssh "${ssh_options[@]}" "$target" "sudo -n true && systemctl is-active --quiet ipfs.service && systemctl is-active --quiet '${publish_unit%.service}.path'"
remote_stage="/var/tmp/nixhomeserver-${app}-${apk_hash:0:16}.apk"
remote_temp="${destination}.release-${apk_hash:0:16}.tmp"
ssh "${ssh_options[@]}" "$target" "umask 077; cat > '$remote_stage'" <"$apk"
uploaded_hash="$(ssh "${ssh_options[@]}" "$target" "sha256sum '$remote_stage'" | cut -d' ' -f1)"
[[ "$uploaded_hash" == "$apk_hash" ]] || { echo "Uploaded APK checksum mismatch" >&2; exit 1; }
ssh "${ssh_options[@]}" "$target" "sudo -n install -o '$owner' -g '$group' -m '$mode' '$remote_stage' '$remote_temp'"
ssh "${ssh_options[@]}" "$target" "sudo -n mv -f '$remote_temp' '$destination'"
ssh "${ssh_options[@]}" "$target" "sudo -n systemctl start '$publish_unit'"

published=false
for _ in {1..40}; do
  if curl -fsSL --connect-timeout 5 --max-time 15 "$index_url" -o "$work_dir/fdroid.json" \
    && curl -fsSL --connect-timeout 5 --max-time 15 "$mirror_url" -o "$work_dir/ipfs.json" \
    && cmp -s "$work_dir/fdroid.json" "$work_dir/ipfs.json" \
    && jq -e --arg id "$app_id" --arg hash "$apk_hash" --arg signer "$signer" --argjson code "$version_code" \
      '.packages[$id].versions[$hash].manifest.versionCode == $code and
       .packages[$id].versions[$hash].file.sha256 == $hash and
       .packages[$id].metadata.preferredSigner == $signer' "$work_dir/fdroid.json" >/dev/null; then
    published=true
    break
  fi
  sleep 2
done
if [[ "$published" != true ]]; then
  echo "F-Droid or IPFS did not serve the verified $app release in time" >&2
  exit 1
fi

cid="$(ssh "${ssh_options[@]}" "$target" 'cat /var/lib/ipfs-distribution/channels/fdroid.cid')"
[[ "$cid" =~ ^b[a-z2-7]{49,119}$ ]] || { echo "IPFS channel CID is invalid" >&2; exit 1; }
ssh "${ssh_options[@]}" "$target" "rm -f '$remote_stage'"
printf 'Published %s %s (code %s, SHA-256 %s)\n' "$app" "$version_name" "$version_code" "$apk_hash"
printf 'F-Droid: %s\nIPFS CID: %s\n' "$index_url" "$cid"
