#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root "RUNTIME_READINESS_REPO_ROOT"
cd_repo_root
source "$script_dir/lib-storage-health.sh"
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/runtime-readiness.sh

Read-only runtime validation for the active host. It checks core units, HTTPS
entrypoints, Unbound answers, ZFS mounts, and SMART health against vars.nix.

Example:
  sudo ./scripts/runtime-readiness.sh
EOF
}

case "${1:-}" in
  "")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

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

check_dns_resolves() {
  local host_name="$1"
  local answer

  answer="$(host "$host_name" 127.0.0.1 2>/dev/null | awk '/has address/ { print $4; exit }')"
  if [[ -n "$answer" ]]; then
    echo "✅ dns ${host_name} -> ${answer}"
  else
    echo "❌ dns ${host_name} -> <no answer>"
    failed=1
  fi
}

check_ptr_dns() {
  local ip="$1"
  local expected_name="$2"
  local answer

  answer="$(host "$ip" 127.0.0.1 2>/dev/null | awk '/domain name pointer/ { print $5; exit }' | sed 's/\.$//')"
  if [[ "$answer" == "$expected_name" ]]; then
    echo "✅ ptr ${ip} -> ${answer}"
  else
    echo "❌ ptr ${ip} -> ${answer:-<no answer>} (expected ${expected_name})"
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

run_as_copyparty() {
  if (( EUID == 0 )); then
    runuser -u copyparty -- "$@"
  else
    sudo -u copyparty "$@"
  fi
}

check_copyparty_archive_access() {
  local archive_dir="$1"
  local hist_dir="${archive_dir}/.hist"

  if [[ ! -d "$archive_dir" ]]; then
    echo "❌ copyparty archive missing: ${archive_dir}"
    failed=1
    return
  fi

  if [[ ! -d "$hist_dir" ]]; then
    echo "❌ copyparty metadata missing: ${hist_dir}"
    failed=1
    return
  fi

  if ! run_as_copyparty test -x "$archive_dir"; then
    echo "❌ copyparty cannot traverse: ${archive_dir}"
    failed=1
    return
  fi

  if ! run_as_copyparty test -r "$hist_dir"; then
    echo "❌ copyparty cannot read: ${hist_dir}"
    failed=1
    return
  fi

  if ! run_as_copyparty test -w "$hist_dir"; then
    echo "❌ copyparty cannot write: ${hist_dir}"
    failed=1
    return
  fi

  echo "✅ copyparty archive metadata access: ${hist_dir}"
}

need nix curl host systemctl findmnt jq smartctl journalctl zpool zfs runuser

hostname="$(nix_var 'vars.hostname')"
domain="$(nix_var 'vars.domain')"
nb_ip="$(nix_var 'vars.nbIP')"
server_lan_ip="$(nix_var 'vars.serverLanIP')"
dns_mode="$(nix_var 'vars.dnsMode')"
files_domain="$(nix_var 'vars.filesDomain')"
media_root="$(nix_var 'vars.mediaRoot')"
lan_dns_domain="$(nix_var 'vars.lanDnsDomain')"
kiwix_domain="$(nix_var 'vars.kiwixDomain')"
photos_domain="$(nix_var 'vars.photosDomain')"
sharephotos_domain="$(nix_var 'vars.sharePhotosDomain')"
audiobooks_domain="$(nix_var 'vars.audiobooksDomain')"
kavita_domain="$(nix_var 'vars.kavitaDomain')"
jellyfin_domain="$(nix_var 'vars.jellyfinDomain')"
kanidm_domain="$(nix_var 'vars.kanidmDomain')"
cloudflared_unit="cloudflared-tunnel-$(nix_var 'vars.cloudflareTunnelName').service"
data_pool_name="$(nix_var 'vars.zfsDataPool.name')"
data_pool_mount="$(nix_var 'vars.zfsDataPool.mountPoint')"

failed=0
storage_failed=0
sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi
storage_health_cmd_prefix=("${sudo_cmd[@]}")

if [[ "$dns_mode" == "split-horizon" ]]; then
  local_dns_private_answer="$server_lan_ip"
else
  local_dns_private_answer="$nb_ip"
fi

mapfile -t data_dataset_mounts < <(
  nix_json 'map (dataset: "${vars.zfsDataPool.mountPoint}/${dataset}") vars.zfsDataPool.datasets' \
    | jq -r '.[]'
)
data_disk_count="$(nix_var 'toString (builtins.length vars.monitoredDataDiskIds)')"
mapfile -t monitored_disk_devices < <(
  nix_json 'map (diskId: "/dev/disk/by-id/${diskId}") vars.monitoredStorageDiskIds' \
    | jq -r '.[]'
)
mapfile -t cold_storage_pool_names < <(
  nix_json 'map (pool: pool.name) vars.coldStoragePools' \
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
  kiwix.service \
  kiwix-oauth2-proxy.service \
  paperless-web.service \
  audiobookshelf.service \
  kavita.service \
  jellyfin.service
)
for unit in "${required_units[@]}"; do
  check_unit "$unit"
done

echo
echo "== HTTPS endpoints =="
check_http "https://${kanidm_domain}/" 200 303
check_http "https://${files_domain}/" 200 302 303 401 403
check_http "https://${kiwix_domain}/" 200 302
check_http "https://${photos_domain}/" 200 302
check_http "https://${sharephotos_domain}/share/healthcheck" 200
check_http "https://paperless.${domain}/" 200 302
check_http "https://${audiobooks_domain}/" 200 302
check_http "https://${kavita_domain}/" 200 302
check_http "https://${jellyfin_domain}/" 200 302

echo
echo "== Copyparty Paths =="
check_copyparty_archive_access "${media_root}/documents/archive"

echo
echo "== Internal HTTP =="
check_http "http://127.0.0.1:3923/" 200 302 401 403

echo
echo "== DNS via Unbound =="
echo "ℹ️ Validating the server-local Unbound view; LAN client DNS policy may still be mediated by the router."
check_dns_resolves "example.com"
if [[ "$dns_mode" == "split-horizon" ]]; then
  check_private_dns "${kanidm_domain}" "${server_lan_ip}"
  check_private_dns "${files_domain}" "${server_lan_ip}"
  check_private_dns "${hostname}.${lan_dns_domain}" "${server_lan_ip}"
  check_ptr_dns "${server_lan_ip}" "${hostname}.${lan_dns_domain}"
else
  check_public_dns "${kanidm_domain}" "${nb_ip}"
  check_public_dns "${files_domain}" "${nb_ip}"
fi
check_private_dns "paperless.${domain}" "${local_dns_private_answer}"
check_private_dns "${kiwix_domain}" "${local_dns_private_answer}"
check_private_dns "${photos_domain}" "${local_dns_private_answer}"
check_dns_resolves "${sharephotos_domain}"
check_private_dns "${audiobooks_domain}" "${local_dns_private_answer}"
check_private_dns "${kavita_domain}" "${local_dns_private_answer}"
check_private_dns "${jellyfin_domain}" "${local_dns_private_answer}"

echo
echo "== Storage =="
check_mount "$data_pool_mount" "zfs"

for dataset_mount in "${data_dataset_mounts[@]}"; do
  check_mount "$dataset_mount" "zfs"
done

echo
echo "== SMART =="
smart_specs=()
for idx in "${!monitored_disk_devices[@]}"; do
  if (( idx < data_disk_count )); then
    label="disk$((idx + 1))"
  else
    cold_idx=$((idx - data_disk_count))
    label="${cold_storage_pool_names[$cold_idx]}"
  fi
  smart_specs+=("${label}=${monitored_disk_devices[$idx]}")
done

if ((${#smart_specs[@]} == 0)); then
  echo "⚠️  no storage devices configured for SMART checks"
else
  storage_health_check warn "${smart_specs[@]}"
  if (( STORAGE_HEALTH_WARN_COUNT > 0 )); then
    echo "⚠️  SMART warnings detected. Review the affected disks before the next maintenance window."
  fi
  if (( STORAGE_HEALTH_CRITICAL_COUNT > 0 )); then
    echo "❌ critical SMART degradation detected."
    failed=1
  fi
fi

echo
echo "== ZFS =="
zpool_health="$("${sudo_cmd[@]}" zpool list -H -o health "$data_pool_name" 2>&1 || true)"
if [[ "$zpool_health" == "ONLINE" ]]; then
  echo "✅ zpool health ONLINE: ${data_pool_name}"
else
  echo "❌ zpool health unexpected for ${data_pool_name}: ${zpool_health}"
  "${sudo_cmd[@]}" zpool status "$data_pool_name" 2>&1 | sed -n '1,80p'
  failed=1
fi

zfs_list_output="$("${sudo_cmd[@]}" zfs list -H -r -o name,mountpoint "$data_pool_name" 2>&1 || true)"
if [[ -z "$zfs_list_output" ]]; then
  echo "❌ zfs list returned no output for ${data_pool_name}"
  failed=1
else
  echo "✅ zfs list returned datasets for ${data_pool_name}"
  for dataset_mount in "${data_dataset_mounts[@]}"; do
    if ! grep -Fq "${dataset_mount}" <<<"$zfs_list_output"; then
      echo "❌ zfs list is missing expected dataset mountpoint: ${dataset_mount}"
      failed=1
    fi
  done
fi

echo
if (( failed != 0 )); then
  echo "❌ Runtime readiness checks failed."
  exit 1
fi

echo "✅ Runtime readiness checks passed."
