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
  nix run nixpkgs#nixos-rebuild -- "$rebuild_action" \
    --flake ".#${hostname}" \
    --target-host "$target_host" \
    --build-host "$build_host" \
    --sudo \
    --ask-sudo-password
}

create_runtime_readiness_archive() {
  local archive_path="$1"

  tar -C "$repo_root" \
    --exclude=.git \
    --exclude='./result' \
    --exclude='./result-*' \
    --exclude='./rust/apps/mail-archive-ui/target' \
    --exclude='./rust/apps/kanidm-admin/target' \
    -cf "$archive_path" .
}

echo "ℹ️ Running flake checks (no build)…"
nix flake check --no-build

echo "ℹ️ Running repository checks…"
"$repo_root/scripts/check-repo.sh" --full --skip-flake-check

print_transition_notice_if_needed

echo "ℹ️ Running remote nixos-rebuild test…"
run_rebuild test

echo "ℹ️ Checking for failed units on ${target_host}…"
ssh -t "$target_host" "sudo systemctl --failed --no-pager"

if [[ -x "$repo_root/scripts/runtime-readiness.sh" ]]; then
  echo "ℹ️ Running runtime readiness checks on ${target_host}…"
  readiness_archive="$(mktemp)"
  trap 'rm -f "$readiness_archive"' EXIT
  create_runtime_readiness_archive "$readiness_archive"
  scp "$readiness_archive" "$target_host:/tmp/runtime-readiness.tar"
  ssh -tt "$target_host" "
    set -euo pipefail
    tmpdir=\$(mktemp -d)
    trap 'rm -rf \"\$tmpdir\" /tmp/runtime-readiness.tar' EXIT
    tar -C \"\$tmpdir\" -xf /tmp/runtime-readiness.tar
    chmod +x \"\$tmpdir/scripts/runtime-readiness.sh\"
    sudo env RUNTIME_READINESS_REPO_ROOT=\"\$tmpdir\" \"\$tmpdir/scripts/runtime-readiness.sh\" --profile deploy
  "
  rm -f "$readiness_archive"
  trap - EXIT
else
  echo "ℹ️ Local runtime readiness script not found at $repo_root/scripts/runtime-readiness.sh"
fi

if [[ "$action" == "switch" ]]; then
  echo "ℹ️ Running remote nixos-rebuild switch…"
  run_rebuild switch
fi

echo "✅ Deploy validation completed."
echo "Next verification command:"
echo "  readiness_archive=\$(mktemp) && tar -C $repo_root --exclude=.git --exclude='./result' --exclude='./result-*' --exclude='./rust/apps/mail-archive-ui/target' --exclude='./rust/apps/kanidm-admin/target' -cf \"\$readiness_archive\" . && scp \"\$readiness_archive\" $target_host:/tmp/runtime-readiness.tar && ssh -tt $target_host 'tmpdir=\$(mktemp -d); trap \"rm -rf \\\"\$tmpdir\\\" /tmp/runtime-readiness.tar\" EXIT; tar -C \"\$tmpdir\" -xf /tmp/runtime-readiness.tar; chmod +x \"\$tmpdir/scripts/runtime-readiness.sh\"; sudo env RUNTIME_READINESS_REPO_ROOT=\"\$tmpdir\" \"\$tmpdir/scripts/runtime-readiness.sh\" --profile deploy' && rm -f \"\$readiness_archive\""
