#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/validate-repo.sh [--full] [--all-apps] [--run-flake-check] [--skip-flake-check] [--run-vm-tests]

Run the local repository validation gate.

Default mode (lean):
  - runs the lean script suite through scripts/tests/run-script-tests.sh
  - does not run the flake check by default
  - does not build lint or Rust check derivations
  - tests only enabled applications for the current host

  Use --run-flake-check to include `nix flake check --no-build`.

Full mode (--full):
  - runs `nix flake check --no-build` unless --skip-flake-check is used
  - runs the full script suite through scripts/tests/run-script-tests.sh --full
  - builds flake check derivations except repo-policy, which is run directly
  - runs the pinned Homepage Playwright end-to-end suite

VM tests (--run-vm-tests):
  - runs integration tests requiring VM boot (failure-alert, jellyfin-oidc)
  - requires /dev/kvm
  - only run when diagnosing persistent bugs where integration test coverage
    would be severely hampered without VM validation, or with explicit permission

Application scope:
  - defaults to applications.enabled for the current host
  - --all-apps uses the repository-wide check and script-test worklists

Examples:
  scripts/validate-repo.sh
  scripts/validate-repo.sh --run-flake-check
  scripts/validate-repo.sh --full
  scripts/validate-repo.sh --full --all-apps
  scripts/validate-repo.sh --full --skip-flake-check
  scripts/validate-repo.sh --run-vm-tests
  scripts/validate-repo.sh --run-vm-tests --all-apps
EOF
}

full_mode=false
all_apps=false
run_flake_check=false
skip_flake_check=false
run_vm_tests=false
tests_dir="${VALIDATE_REPO_TESTS_DIR:-$repo_root/scripts/tests}"
  eval_cache_dir=""
  pending_validation_roots_dir=""
  validation_outputs_json="[]"

cleanup_tmpdirs() {
  if [[ -n "$pending_validation_roots_dir" && -d "$pending_validation_roots_dir" ]]; then
    rm -rf "$pending_validation_roots_dir"
  fi
  if [[ -n "$eval_cache_dir" && -d "$eval_cache_dir" ]]; then
    rm -rf "$eval_cache_dir"
  fi
}

trap cleanup_tmpdirs EXIT

while (($# > 0)); do
  case "$1" in
    --full)
      full_mode=true
      shift
      ;;
    --all-apps)
      all_apps=true
      shift
      ;;
    --run-flake-check)
      run_flake_check=true
      shift
      ;;
    --skip-flake-check)
      skip_flake_check=true
      shift
      ;;
    --run-vm-tests)
      run_vm_tests=true
      shift
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

need nix jq rg

local_attic_cache="http://127.0.0.1:8080/nixhomeserver"
if nix_uses_substituter "$local_attic_cache"; then
  need curl nohup
  ensure_local_attic_tunnel \
    "$local_attic_cache/nix-cache-info" \
    "${NIXHOMESERVER_ATTIC_TUNNEL_SCRIPT:-$HOME/.local/bin/nixhomeserver-attic-tunnel}" \
    "${XDG_CACHE_HOME:-$HOME/.cache}/nixhomeserver-attic-tunnel.log"
fi

if [[ -z "${REPO_NIX_EVAL_CACHE_DIR:-}" ]]; then
  eval_cache_dir="$(mktemp -d)"
  export REPO_NIX_EVAL_CACHE_DIR="$eval_cache_dir"
fi

current_system() {
  nix eval --impure --raw --expr 'builtins.currentSystem'
}

build_derivation_attr() {
  local attr="$1" system="$2" check_name check_names output_path root_path
  local -a check_targets=()
  local new_outputs

  if ! check_names="$(
    nix eval --json ".#${attr}" --apply 'checks: builtins.attrNames checks' \
      | jq -r '.[]' \
      | sort
  )" || [[ -z "$check_names" ]]; then
    echo "❌ Could not evaluate a non-empty flake check worklist for ${attr}." >&2
    exit 1
  fi

  while IFS= read -r check_name; do
    [[ -n "$check_name" ]] || continue
    [[ "$check_name" != "repo-policy" ]] || continue
    if [[ "$check_name" =~ ^(failure-alert|jellyfin-oidc)$ && ! -c /dev/kvm ]]; then
      echo "ℹ️ Skipping ${check_name} VM execution because /dev/kvm is unavailable; flake evaluation still checks the test definition."
      continue
    fi
    check_targets+=(".#${attr}.${check_name}")
  done <<<"$check_names"

  if ((${#check_targets[@]} == 0)); then
    return 0
  fi

  echo "ℹ️ Running ${#check_targets[@]} derivation checks from ${attr} in one Nix build…"
  new_outputs="$(
    nix build "${check_targets[@]}" --no-link --print-build-logs --json
  )"
  jq -e '
    type == "array"
    and length > 0
    and all(.[]; (.outputs | type == "object") and (.outputs | length > 0))
  ' <<<"$new_outputs" >/dev/null || {
    echo "❌ Nix returned an invalid full-check output manifest." >&2
    exit 1
  }
  validation_outputs_json="$(jq -s 'add' <<<"$validation_outputs_json $new_outputs")"
}

run_vm_tests() {
  if [[ "$run_vm_tests" != true ]]; then
    return 0
  fi

  echo "ℹ️ Running VM integration tests…"
  local system
  system="$(current_system)"
  if [[ "$all_apps" == true ]]; then
    nix build ".#hydraJobs.${system}.vmTestsAll" --no-link --print-build-logs
  else
    nix build ".#hydraJobs.${system}.vmTests" --no-link --print-build-logs
  fi
}

run_full_derivation_checks() {
  local system check_attr vm_attr root_state_dir output_path root_path

  if [[ "$full_mode" != true ]]; then
    return 0
  fi

  system="$(current_system)"
  if [[ "$all_apps" == true ]]; then
    check_attr="legacyPackages.${system}.nixhomeserverAllChecks"
    vm_attr="hydraJobs.${system}.vmTestsAll"
  else
    check_attr="checks.${system}"
    vm_attr="hydraJobs.${system}.vmTests"
  fi

  build_derivation_attr "$check_attr" "$system"
  # VM tests are run separately via --run-vm-tests flag
  # build_derivation_attr "$vm_attr" "$system"

  if [[ "$all_apps" == true ]]; then
    return 0
  fi

  root_state_dir="${VALIDATE_REPO_ROOTS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nixhomeserver/validation-roots}"
  install -d -m 0700 "$root_state_dir"
  pending_validation_roots_dir="$(mktemp -d "$root_state_dir/pending.XXXXXX")"
  while IFS= read -r output_path; do
    [[ "$output_path" == /nix/store/* ]] || {
      echo "❌ Full validation returned a non-store output path." >&2
      exit 1
    }
    root_path="$pending_validation_roots_dir/$(basename "$output_path")"
    nix-store --add-root "$root_path" --indirect --realise "$output_path" >/dev/null
  done < <(jq -r '[.[].outputs[]] | unique[]' <<<"$validation_outputs_json")
}

commit_validation_roots() {
  local root_state_dir current_dir desired_manifest output_path root_path existing_root

  if [[ "$full_mode" != true || "$all_apps" == true || -z "$validation_outputs_json" ]]; then
    return 0
  fi

  root_state_dir="${VALIDATE_REPO_ROOTS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nixhomeserver/validation-roots}"
  current_dir="$root_state_dir/current"
  desired_manifest="$eval_cache_dir/desired-validation-roots"
  install -d -m 0700 "$current_dir"
  : >"$desired_manifest"

  while IFS= read -r output_path; do
    root_path="$current_dir/$(basename "$output_path")"
    printf '%s\n' "$root_path" >>"$desired_manifest"
    if [[ -e "$root_path" && ! -L "$root_path" ]]; then
      echo "❌ Refusing to replace non-symlink validation root: $root_path" >&2
      exit 1
    fi
    if [[ ! -L "$root_path" ]]; then
      nix-store --add-root "$root_path" --indirect --realise "$output_path" >/dev/null
    elif [[ "$(readlink "$root_path")" != "$output_path" ]]; then
      ln -sfn "$output_path" "$root_path"
    fi
  done < <(jq -r '[.[].outputs[]] | unique[]' <<<"$validation_outputs_json")

  while IFS= read -r existing_root; do
    if ! rg -Fxq "$existing_root" "$desired_manifest"; then
      rm -f "$existing_root"
    fi
  done < <(find "$current_dir" -mindepth 1 -maxdepth 1 -type l -print)

  rm -rf "$pending_validation_roots_dir"
  pending_validation_roots_dir=""
  echo "ℹ️ Retained the latest passing host-scoped validation outputs in $current_dir"
}

run_shell_tests() {
  echo "ℹ️ Running repository policy tests…"
  if [[ "$full_mode" == true ]]; then
    if [[ "$all_apps" == true ]]; then
      "${tests_dir}/run-script-tests.sh" --all-apps --full
    else
      "${tests_dir}/run-script-tests.sh" --full
    fi
  else
    if [[ "$all_apps" == true ]]; then
      "${tests_dir}/run-script-tests.sh" --all-apps
    else
      "${tests_dir}/run-script-tests.sh"
    fi
  fi
}

run_full_e2e_checks() {
  if [[ "$full_mode" != true ]]; then
    return 0
  fi

  echo "ℹ️ Running Homepage Playwright end-to-end tests…"
  "$repo_root/scripts/test-homepage-ui.sh"
}

if [[ "$skip_flake_check" == false ]]; then
  if [[ "$full_mode" == true || "$run_flake_check" == true ]]; then
    echo "ℹ️ Running flake checks (no build)…"
    nix flake check --no-build
  fi
fi

run_full_derivation_checks
run_shell_tests
run_vm_tests
run_full_e2e_checks
commit_validation_roots

echo "✅ Repository checks passed."