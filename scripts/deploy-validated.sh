#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/deploy-validated.sh --target <user@host> [--build-host <user@host>] [--action test|switch] [--hostname <flake-hostname>]

Guarded remote deploy entrypoint for this repo. The reserved target LAN IP still
comes from vars.serverLanIP; use a temporary SSH host only via --target and
--build-host during cutover work.

Example:
  export TARGET_SERVER_IP="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanIP')"
  export CURRENT_SERVER_IP="${CURRENT_SERVER_IP:-$TARGET_SERVER_IP}"
  ./scripts/deploy-validated.sh --target "dsaw@$CURRENT_SERVER_IP" --build-host "dsaw@$CURRENT_SERVER_IP" --action test --hostname server
EOF
}

target_host=""
build_host=""
action="test"
hostname="$(nix_var 'vars.hostname')"
expected_lan_ip="$(nix_var 'vars.serverLanIP')"
min_build_host_free_bytes=$((10 * 1024 * 1024 * 1024))
min_remote_tmp_free_bytes=$((1 * 1024 * 1024 * 1024))
repo_archive=""

while (($# > 0)); do
  case "$1" in
    --target)
      target_host="${2:-}"
      shift 2
      ;;
    --build-host)
      build_host="${2:-}"
      shift 2
      ;;
    --action)
      action="${2:-}"
      shift 2
      ;;
    --hostname)
      hostname="${2:-}"
      shift 2
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
done

if [[ -z "$target_host" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$build_host" ]]; then
  build_host="$target_host"
fi

if [[ "$action" != "test" && "$action" != "switch" ]]; then
  echo "❌ --action must be 'test' or 'switch'." >&2
  exit 1
fi

cleanup_local_archive() {
  if [[ -n "$repo_archive" && -f "$repo_archive" ]]; then
    rm -f "$repo_archive"
  fi
}

trap cleanup_local_archive EXIT

host_part() {
  local host_spec="$1"
  if [[ "$host_spec" == *@* ]]; then
    printf '%s\n' "${host_spec##*@}"
  else
    printf '%s\n' "$host_spec"
  fi
}

host_matches_expected_lan_ip() {
  local host_spec="$1"
  local host_value resolved

  host_value="$(host_part "$host_spec")"
  if [[ "$host_value" == "$expected_lan_ip" ]]; then
    return 0
  fi

  if [[ "$host_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi

  if ! command -v getent >/dev/null 2>&1; then
    return 1
  fi

  while read -r resolved _; do
    if [[ "$resolved" == "$expected_lan_ip" ]]; then
      return 0
    fi
  done < <(getent ahostsv4 "$host_value" 2>/dev/null || true)

  return 1
}

print_transition_notice_if_needed() {
  local target_matches build_matches

  target_matches=0
  build_matches=0
  if host_matches_expected_lan_ip "$target_host"; then
    target_matches=1
  fi
  if host_matches_expected_lan_ip "$build_host"; then
    build_matches=1
  fi

  if (( target_matches == 1 && build_matches == 1 )); then
    return
  fi

  echo "ℹ️ Transition deploy: the current SSH/build endpoint differs from vars.serverLanIP."
  echo "   Target host: ${target_host}"
  echo "   Build host: ${build_host}"
  echo "   Expected reserved LAN IP from vars.nix: ${expected_lan_ip}"
  echo "   This is advisory only. Deploy will continue, but post-cutover validation must still confirm SSH and runtime readiness on ${expected_lan_ip}."
}

run_rebuild() {
  local rebuild_action="$1"
  check_remote_build_host_storage "$build_host"
  nix run nixpkgs#nixos-rebuild -- "$rebuild_action" \
    --flake ".#${hostname}" \
    --target-host "$target_host" \
    --build-host "$build_host" \
    --sudo \
    --ask-sudo-password
}

create_repo_archive() {
  local archive_path="$1"

  tar -C "$repo_root" \
    --exclude=.git \
    --exclude='./result' \
    --exclude='./result-*' \
    --exclude='./rust/apps/mail-archive-ui/target' \
    --exclude='./rust/apps/kanidm-admin/target' \
    -cf "$archive_path" .
}

stage_archive_on_remote() {
  local archive_path="$1"
  local remote_host="$2"
  local archive_label="$3"
  local remote_archive

  remote_archive="$(ssh "$remote_host" "mktemp /tmp/${archive_label}.XXXXXX.tar")"
  scp "$archive_path" "$remote_host:$remote_archive"
  printf '%s\n' "$remote_archive"
}

check_remote_build_host_storage() {
  local remote_host="$1"

  echo "ℹ️ Checking build host free space on ${remote_host}…"
  ssh "$remote_host" \
    "MIN_BUILD_FREE_BYTES=${min_build_host_free_bytes} MIN_TMP_FREE_BYTES=${min_remote_tmp_free_bytes} bash -s" <<'EOF'
set -euo pipefail

human_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
}

sandbox_build_dir="$(nix config show 2>/dev/null | sed -n 's/^sandbox-build-dir = //p' | head -n 1)"
if [[ -z "$sandbox_build_dir" ]]; then
  sandbox_build_dir="/build"
fi

build_backing_path="$sandbox_build_dir"
while [[ ! -e "$build_backing_path" && "$build_backing_path" != "/" ]]; do
  build_backing_path="$(dirname "$build_backing_path")"
done

build_available_bytes="$(df -B1 --output=avail "$build_backing_path" | awk 'NR==2 { print $1 }')"
tmp_available_bytes="$(df -B1 --output=avail /tmp | awk 'NR==2 { print $1 }')"

echo "ℹ️ Build host storage summary: sandbox-build-dir=${sandbox_build_dir}, backing-path=${build_backing_path}, available=$(human_bytes "$build_available_bytes"), /tmp=$(human_bytes "$tmp_available_bytes")"

if (( build_available_bytes < MIN_BUILD_FREE_BYTES )); then
  echo "❌ Insufficient free space on build host"
  echo "   sandbox-build-dir: ${sandbox_build_dir}"
  echo "   backing path: ${build_backing_path}"
  echo "   available: ${build_available_bytes} bytes ($(human_bytes "$build_available_bytes"))"
  echo "   required: ${MIN_BUILD_FREE_BYTES} bytes ($(human_bytes "$MIN_BUILD_FREE_BYTES"))"
  exit 1
fi

if (( tmp_available_bytes < MIN_TMP_FREE_BYTES )); then
  echo "❌ Insufficient free space on build host"
  echo "   sandbox-build-dir: /tmp"
  echo "   backing path: /tmp"
  echo "   available: ${tmp_available_bytes} bytes ($(human_bytes "$tmp_available_bytes"))"
  echo "   required: ${MIN_TMP_FREE_BYTES} bytes ($(human_bytes "$MIN_TMP_FREE_BYTES"))"
  exit 1
fi
EOF
}

run_remote_repo_checks() {
  local remote_host="$1"
  local remote_archive

  remote_archive="$(stage_archive_on_remote "$repo_archive" "$remote_host" "deploy-validated-repo")"

  ssh "$remote_host" "REMOTE_ARCHIVE=$(printf '%q' "$remote_archive") bash -s" <<'EOF'
set -euo pipefail
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
chmod +x "$tmpdir/scripts/check-repo.sh"
cd "$tmpdir"
nix shell nixpkgs#ripgrep nixpkgs#python3 -c ./scripts/check-repo.sh --full --skip-flake-check
EOF
}

run_remote_runtime_readiness() {
  local remote_host="$1"
  local remote_archive

  remote_archive="$(stage_archive_on_remote "$repo_archive" "$remote_host" "runtime-readiness")"

  ssh -tt "$remote_host" "REMOTE_ARCHIVE=$(printf '%q' "$remote_archive") bash -s" <<'EOF'
set -euo pipefail
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
chmod +x "$tmpdir/scripts/runtime-readiness.sh"
cd "$tmpdir"
sudo env RUNTIME_READINESS_REPO_ROOT="$PWD" ./scripts/runtime-readiness.sh --profile deploy
EOF
}

repo_archive="$(mktemp /tmp/deploy-validated-repo.XXXXXX.tar)"
create_repo_archive "$repo_archive"

print_transition_notice_if_needed

check_remote_build_host_storage "$build_host"

echo "ℹ️ Running repository checks on ${build_host}…"
run_remote_repo_checks "$build_host"

echo "ℹ️ Running remote nixos-rebuild test…"
run_rebuild test

echo "ℹ️ Checking for failed units on ${target_host}…"
ssh -t "$target_host" "sudo systemctl --failed --no-pager"

if [[ -x "$repo_root/scripts/runtime-readiness.sh" ]]; then
  echo "ℹ️ Running runtime readiness checks on ${target_host}…"
  run_remote_runtime_readiness "$target_host"
else
  echo "ℹ️ Local runtime readiness script not found at $repo_root/scripts/runtime-readiness.sh"
fi

if [[ "$action" == "switch" ]]; then
  echo "ℹ️ Running remote nixos-rebuild switch…"
  run_rebuild switch
fi

echo "✅ Deploy validation completed."
echo "Next verification command:"
cat <<EOF
  repo_archive=\$(mktemp /tmp/runtime-readiness.XXXXXX.tar) && tar -C $repo_root --exclude=.git --exclude='./result' --exclude='./result-*' --exclude='./rust/apps/mail-archive-ui/target' --exclude='./rust/apps/kanidm-admin/target' -cf "\$repo_archive" . && remote_archive=\$(ssh $target_host 'mktemp /tmp/runtime-readiness.XXXXXX.tar') && scp "\$repo_archive" $target_host:"\$remote_archive" && ssh -tt $target_host "REMOTE_ARCHIVE=\"\$remote_archive\" bash -s" <<'REMOTE_EOF'
set -euo pipefail
tmpdir=\$(mktemp -d)
trap 'rm -rf "\$tmpdir" "\$REMOTE_ARCHIVE"' EXIT
tar -C "\$tmpdir" -xf "\$REMOTE_ARCHIVE"
chmod +x "\$tmpdir/scripts/runtime-readiness.sh"
cd "\$tmpdir"
sudo env RUNTIME_READINESS_REPO_ROOT="\$PWD" ./scripts/runtime-readiness.sh --profile deploy
REMOTE_EOF
rm -f "\$repo_archive"
EOF
