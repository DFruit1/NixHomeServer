#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

usage() {
  cat <<'EOF'
Usage: scripts/deploy-validated.sh --target <user@host> [--build-host <user@host>] [--action test|switch] [--hostname <flake-hostname>]
EOF
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

target_host=""
build_host=""
action="test"
hostname="$(nix_var 'vars.hostname')"

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

run_rebuild() {
  local rebuild_action="$1"
  nix run nixpkgs#nixos-rebuild -- "$rebuild_action" \
    --flake ".#${hostname}" \
    --target-host "$target_host" \
    --build-host "$build_host" \
    --sudo \
    --ask-sudo-password
}

echo "ℹ️ Running flake checks (no build)…"
nix flake check --no-build

echo "ℹ️ Running repository checks…"
"$repo_root/scripts/check-repo.sh"

echo "ℹ️ Running remote nixos-rebuild test…"
run_rebuild test

echo "ℹ️ Checking for failed units on ${target_host}…"
ssh -t "$target_host" "sudo systemctl --failed --no-pager"

if ssh "$target_host" "test -x '$repo_root/scripts/runtime-readiness.sh'"; then
  echo "ℹ️ Running runtime readiness checks on ${target_host}…"
  ssh -t "$target_host" "cd '$repo_root' && sudo ./scripts/runtime-readiness.sh"
else
  echo "ℹ️ Remote runtime readiness script not found at $repo_root/scripts/runtime-readiness.sh"
  echo "   Next step on the target host:"
  echo "   cd $repo_root && sudo ./scripts/runtime-readiness.sh"
fi

if [[ "$action" == "switch" ]]; then
  echo "ℹ️ Running remote nixos-rebuild switch…"
  run_rebuild switch
fi

echo "✅ Deploy validation completed."
echo "Next verification command:"
echo "  ssh -t $target_host 'cd $repo_root && sudo ./scripts/runtime-readiness.sh'"
