#!/usr/bin/env bash

set -euo pipefail

repo_root="${RUNTIME_READINESS_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

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

  actual_fstype="$(findmnt -nro FSTYPE "$target" 2>/dev/null || true)"
  if [[ "$actual_fstype" == "$expected_fstype" ]]; then
    echo "✅ mount ${target} (${actual_fstype})"
  else
    echo "❌ mount ${target} (${actual_fstype:-missing}) expected ${expected_fstype}"
    failed=1
  fi
}

need nix curl host systemctl findmnt

hostname="$(nix_var 'vars.hostname')"
domain="$(nix_var 'vars.domain')"
nb_ip="$(nix_var 'vars.nbIP')"
files_domain="$(nix_var 'vars.filesDomain')"
photos_domain="$(nix_var 'vars.photosDomain')"
audiobooks_domain="$(nix_var 'vars.audiobooksDomain')"
kavita_domain="$(nix_var 'vars.kavitaDomain')"
jellyfin_domain="$(nix_var 'vars.jellyfinDomain')"
jellyseerr_domain="$(nix_var 'vars.jellyseerrDomain')"
kanidm_domain="$(nix_var 'vars.kanidmDomain')"
cloudflared_unit="cloudflared-tunnel-$(nix_var 'vars.cloudflareTunnelName').service"

failed=0
sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi

echo "Host: ${hostname}"
echo
echo "== Units =="
for unit in \
  kanidm.service \
  caddy.service \
  oauth2-proxy.service \
  "${cloudflared_unit}" \
  unbound.service \
  immich-server.service \
  paperless-web.service \
  audiobookshelf.service \
  kavita.service \
  jellyfin.service \
  jellyseerr.service \
  snapraid-sync.timer \
  snapraid-scrub.timer
do
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
echo "== DNS via Unbound =="
check_public_dns "${kanidm_domain}" "${nb_ip}"
check_public_dns "${files_domain}" "${nb_ip}"
check_private_dns "paperless.${domain}" "${nb_ip}"
check_private_dns "${photos_domain}" "${nb_ip}"
check_private_dns "${audiobooks_domain}" "${nb_ip}"
check_private_dns "${kavita_domain}" "${nb_ip}"
check_private_dns "${jellyfin_domain}" "${nb_ip}"
check_private_dns "${jellyseerr_domain}" "${nb_ip}"

echo
echo "== Storage =="
check_mount "/mnt/data" "fuse.mergerfs"
check_mount "/mnt/parity" "xfs"

for disk in /mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/disk4 /mnt/disk5; do
  actual_fstype="$(findmnt -nro FSTYPE "$disk" 2>/dev/null || true)"
  if [[ -n "$actual_fstype" ]]; then
    echo "✅ mount ${disk} (${actual_fstype})"
  else
    echo "❌ mount ${disk} missing"
    failed=1
  fi
done

echo
echo "== SnapRAID =="
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

echo
if (( failed != 0 )); then
  echo "❌ Runtime readiness checks failed."
  exit 1
fi

echo "✅ Runtime readiness checks passed."
