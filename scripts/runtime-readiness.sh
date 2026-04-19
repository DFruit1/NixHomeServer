#!/usr/bin/env bash

set -euo pipefail

repo_root="${RUNTIME_READINESS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"
source "$repo_root/scripts/lib-storage-health.sh"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool"
      exit 1
    fi
  done
}

nix_var() {
  local expr="$1"
  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      vars = import ${repo_root}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
    in
      ${expr}
  "
}

nix_json() {
  local expr="$1"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      vars = import ${repo_root}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
    in
      ${expr}
  "
}

check_unit() {
  local unit="$1"
  if systemctl is-active --quiet "$unit"; then
    echo "✅ unit active: $unit"
  else
    echo "❌ unit inactive: $unit"
    failed=1
  fi
}

check_http() {
  local url="$1"
  shift
  local expected=("$@")
  local code

  code="$(curl -sk -o /dev/null -w '%{http_code}' "$url" || true)"
  for allowed in "${expected[@]}"; do
    if [[ "$code" == "$allowed" ]]; then
      echo "✅ http $code: $url"
      return
    fi
  done

  echo "❌ unexpected http $code: $url (expected one of: ${expected[*]})"
  failed=1
}

check_private_dns() {
  local host_name="$1"
  local expected_ip="$2"
  local answer

  answer="$(host "$host_name" 127.0.0.1 2>/dev/null | awk '/has address/ { print $4; exit }')"
  if [[ "$answer" == "$expected_ip" ]]; then
    echo "✅ dns ${host_name} -> ${answer}"
  else
    echo "❌ dns ${host_name} -> ${answer:-<no answer>} (expected ${expected_ip})"
    failed=1
  fi
}

check_public_dns() {
  local host_name="$1"
  local forbidden_ip="$2"
  local answer

  answer="$(host "$host_name" 127.0.0.1 2>/dev/null | awk '/has address/ { print $4; exit }')"
  if [[ -n "$answer" && "$answer" != "$forbidden_ip" ]]; then
    echo "✅ dns ${host_name} -> ${answer} (public path)"
  else
    echo "❌ dns ${host_name} -> ${answer:-<no answer>} (expected non-${forbidden_ip} public answer)"
    failed=1
  fi
}

check_mount() {
  local target="$1"
  local expected_fstype="$2"
  local actual_fstype
  local access_output

  actual_fstype="$(findmnt -nro FSTYPE "$target" 2>/dev/null || true)"
  if [[ "$actual_fstype" == "$expected_fstype" ]]; then
    if access_output="$(ls -d "$target" 2>&1 >/dev/null)"; then
      echo "✅ mount ${target} (${actual_fstype})"
    else
      echo "❌ mount ${target} (${actual_fstype}) inaccessible"
      printf '%s\n' "$access_output" | sed -n '1,5p'
      failed=1
      storage_failed=1
    fi
  else
    echo "❌ mount ${target} (${actual_fstype:-missing}) expected ${expected_fstype}"
    failed=1
    storage_failed=1
  fi
}

need nix curl host systemctl findmnt jq smartctl journalctl

hostname="$(nix_var 'vars.hostname')"
domain="$(nix_var 'vars.domain')"
nb_ip="$(nix_var 'vars.nbIP')"
server_lan_ip="$(nix_var 'vars.serverLanIP')"
dns_mode="$(nix_var 'vars.dnsMode')"
local_dns_private_answer="$(nix_var 'vars.localDnsPrivateAnswer')"
files_domain="$(nix_var 'vars.filesDomain')"
photos_domain="$(nix_var 'vars.photosDomain')"
audiobooks_domain="$(nix_var 'vars.audiobooksDomain')"
kavita_domain="$(nix_var 'vars.kavitaDomain')"
jellyfin_domain="$(nix_var 'vars.jellyfinDomain')"
jellyseerr_domain="$(nix_var 'vars.jellyseerrDomain')"
kanidm_domain="$(nix_var 'vars.kanidmDomain')"
cloudflared_unit="cloudflared-tunnel-$(nix_var 'vars.cloudflareTunnelName').service"
backup_disk_enabled="$(nix_var 'if vars.enableBackupDisk then "true" else "false"')"
backup_device="$(nix_var 'if vars.backupDisk == null then "" else "/dev/disk/by-id/${vars.backupDisk}"')"
backup_mount_point="$(nix_var 'vars.backupMountPoint')"

failed=0
storage_failed=0
sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi
storage_health_cmd_prefix=("${sudo_cmd[@]}")

mapfile -t data_mounts < <(
  nix_json 'builtins.genList (idx: "/mnt/disk${toString (idx + 1)}") (builtins.length vars.dataDisks)' \
    | jq -r '.[]'
)
mapfile -t parity_mounts < <(
  nix_json 'builtins.genList (idx: if idx == 0 then "/mnt/parity" else "/mnt/parity${toString (idx + 1)}") (builtins.length vars.parityDisks)' \
    | jq -r '.[]'
)
mapfile -t data_devices < <(
  nix_json 'map (diskId: "/dev/disk/by-id/${diskId}") vars.dataDisks' \
    | jq -r '.[]'
)
mapfile -t parity_devices < <(
  nix_json 'map (diskId: "/dev/disk/by-id/${diskId}") vars.parityDisks' \
    | jq -r '.[]'
)

echo "Host: ${hostname}"
echo
echo "== Units =="
required_units=(
  kanidm.service \
  caddy.service \
  oauth2-proxy.service \
  "${cloudflared_unit}" \
  unbound.service \
  copyparty.service \
  immich-server.service \
  paperless-web.service \
  audiobookshelf.service \
  kavita.service \
  jellyfin.service \
  jellyseerr.service \
  snapraid-sync.timer \
  snapraid-scrub.timer
)
if [[ "$backup_disk_enabled" == "true" ]]; then
  required_units+=(mnt-backup.mount)
fi
for unit in "${required_units[@]}"; do
  check_unit "$unit"
done

echo
echo "== HTTPS endpoints =="
check_http "https://${kanidm_domain}/" 200 303
check_http "https://${files_domain}/" 200 302 303 401 403
check_http "https://${photos_domain}/" 200 302
check_http "https://paperless.${domain}/" 200 302
check_http "https://${audiobooks_domain}/" 200 302
check_http "https://${kavita_domain}/" 200 302
check_http "https://${jellyfin_domain}/" 200 302
check_http "https://${jellyseerr_domain}/" 200 302 307

echo
echo "== Internal HTTP =="
check_http "http://127.0.0.1:3923/" 200 302 401 403

echo
echo "== DNS via Unbound =="
if [[ "$dns_mode" == "split-horizon" ]]; then
  check_private_dns "${kanidm_domain}" "${server_lan_ip}"
  check_private_dns "${files_domain}" "${server_lan_ip}"
else
  check_public_dns "${kanidm_domain}" "${nb_ip}"
  check_public_dns "${files_domain}" "${nb_ip}"
fi
check_private_dns "paperless.${domain}" "${local_dns_private_answer}"
check_private_dns "${photos_domain}" "${local_dns_private_answer}"
check_private_dns "${audiobooks_domain}" "${local_dns_private_answer}"
check_private_dns "${kavita_domain}" "${local_dns_private_answer}"
check_private_dns "${jellyfin_domain}" "${local_dns_private_answer}"
check_private_dns "${jellyseerr_domain}" "${local_dns_private_answer}"

echo
echo "== Storage =="
check_mount "/mnt/data" "fuse.mergerfs"

for disk in "${data_mounts[@]}"; do
  check_mount "$disk" "xfs"
done

for parity_mount in "${parity_mounts[@]}"; do
  check_mount "$parity_mount" "xfs"
done

if [[ "$backup_disk_enabled" == "true" ]]; then
  check_mount "$backup_mount_point" "xfs"
fi

echo
echo "== SMART =="
smart_specs=()
for idx in "${!data_devices[@]}"; do
  smart_specs+=("disk$((idx + 1))=${data_devices[$idx]}")
done
for idx in "${!parity_devices[@]}"; do
  if (( idx == 0 )); then
    smart_specs+=("parity=${parity_devices[$idx]}")
  else
    smart_specs+=("parity$((idx + 1))=${parity_devices[$idx]}")
  fi
done

if [[ -n "$backup_device" ]]; then
  if [[ -e "$backup_device" ]]; then
    smart_specs+=("backupDisk=${backup_device}")
  elif [[ "$backup_disk_enabled" == "true" ]]; then
    echo "❌ configured backup disk is enabled but not attached: ${backup_device}"
    failed=1
  else
    echo "ℹ️ backupDisk is configured but not attached: ${backup_device}"
  fi
fi

if ((${#smart_specs[@]} == 0)); then
  echo "⚠️  no storage devices configured for SMART checks"
else
  storage_health_check warn "${smart_specs[@]}"
  if (( STORAGE_HEALTH_WARN_COUNT > 0 )); then
    echo "⚠️  SMART warnings detected. Review the affected disks before the next maintenance window."
  fi
  if (( STORAGE_HEALTH_CRITICAL_COUNT > 0 )); then
    echo "❌ critical SMART degradation detected."
    if (( storage_failed == 0 )); then
      echo "   Active array mounts are present, so this is a hard runtime-readiness failure."
    fi
    failed=1
  fi
fi

echo
echo "== SnapRAID =="
if (( storage_failed != 0 )); then
  echo "❌ Skipping SnapRAID checks because storage mounts are unhealthy."
else
  snapraid_status="$("${sudo_cmd[@]}" snapraid status 2>&1 || true)"
  if grep -Fq "No error detected." <<<"$snapraid_status"; then
    echo "✅ snapraid status clean"
  else
    echo "❌ snapraid status did not report a clean state"
    printf '%s\n' "$snapraid_status" | sed -n '1,80p'
    failed=1
  fi

  snapraid_diff="$("${sudo_cmd[@]}" snapraid diff 2>&1 || true)"
  if grep -Fq "There are differences!" <<<"$snapraid_diff"; then
    echo "⚠️  snapraid diff shows pending changes"
    printf '%s\n' "$snapraid_diff" | sed -n '1,40p'
  elif grep -Eq '^[[:space:]]*[0-9]+ equal' <<<"$snapraid_diff"; then
    echo "✅ snapraid diff completed"
  else
    echo "❌ snapraid diff did not return an expected summary"
    printf '%s\n' "$snapraid_diff" | sed -n '1,80p'
    failed=1
  fi
fi

echo
if (( failed != 0 )); then
  echo "❌ Runtime readiness checks failed."
  exit 1
fi

echo "✅ Runtime readiness checks passed."
