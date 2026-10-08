#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
# remote-eval.sh decides where the flake check worklist is evaluated. It is
# sourced here so this gate can batch its queries instead of paying a local
# module-system instantiation on the workstation's four cores.
# shellcheck source=scripts/helpers/remote-eval.sh
source "$script_dir/helpers/remote-eval.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/validate-repo.sh [--full] [--build-checks] [--all-apps] [--run-flake-check] [--skip-flake-check] [--run-vm-tests] [--print-sandbox-exclusions]

Run the local repository validation gate.

Default mode (lean):
  - runs the lean script suite through scripts/tests/run-script-tests.sh
  - does not run the flake check by default
  - does not build lint or Rust check derivations
  - tests only enabled applications for the current host

  Use --run-flake-check to include `nix flake check --no-build`.

Build checks (--build-checks):
  - builds flake check derivations, including Rust tests and frontend checks
  - skips the sandbox-excluded checks listed below and runs them directly
  - retains lean script selection; full runtime and E2E checks require --full
  - does not replace the GC roots retained by a passing full validation

Full mode (--full):
  - runs `nix flake check --no-build` unless --skip-flake-check is used
  - runs the full script suite through scripts/tests/run-script-tests.sh --full
  - builds flake check derivations except the sandbox-excluded checks below
  - runs the pinned Homepage Playwright end-to-end suite

Sandbox-excluded checks (the class, stated once, enforced below):
  - a derivation that shells out to the invoking user's tools (cargo, hermes,
    systemd-tmpfiles, ~/.local/bin) fails inside a remote builder's sandbox,
    which has no PATH into those tools, and passes on the workstation
  - each excluded check therefore runs directly on the workstation instead,
    and the gate refuses to run if that direct path cannot be named
  - only the known rows below may be excluded: an unlisted check, or a direct
    path that is not that check's known one, is rejected before any worklist
    evaluation, build or script runs
  - an entry may only be added with that check's own failure evidence from a
    remote build; a shared cause across other failures must never be assumed
  - see documentation/operations.md, "Builds", for the measured evidence

Reporting:
  - --print-sandbox-exclusions prints the known exclusion table as
    name|direct-path lines and exits, so the policy surface is reviewable as a
    diff

Where the check worklist is evaluated:
  - the worklist is built with one batched query, so the system name and the
    check names cost a single evaluation instead of two
  - by default that query runs on the build server and the gate reports which
    host evaluated it; `nix build` still runs through the normal builders
  - REMOTE_EVAL=0 forces the evaluation onto this workstation
  - an unreachable server or a malformed payload stops the gate, never silently
    reduces the check set

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
  scripts/validate-repo.sh --build-checks --all-apps
  scripts/validate-repo.sh --full
  scripts/validate-repo.sh --full --all-apps
  scripts/validate-repo.sh --full --skip-flake-check
  scripts/validate-repo.sh --run-vm-tests
  scripts/validate-repo.sh --run-vm-tests --all-apps
  scripts/validate-repo.sh --print-sandbox-exclusions
EOF
}

full_mode=false
build_checks=false
all_apps=false
run_flake_check=false
skip_flake_check=false
run_vm_tests=false
print_sandbox_exclusions=false
tests_dir="${VALIDATE_REPO_TESTS_DIR:-$repo_root/scripts/tests}"
  eval_cache_dir=""
  eval_cache_owned=""
  pending_validation_roots_dir=""
  validation_outputs_json="[]"

cleanup_tmpdirs() {
  if [[ -n "$pending_validation_roots_dir" && -d "$pending_validation_roots_dir" ]]; then
    rm -rf "$pending_validation_roots_dir"
  fi
  # Only a run-scoped cache we created ourselves (the no-Git fallback) is ours
  # to remove. The content-keyed persistent cache must survive the run or it
  # cannot amortize host-config evals across validations; caller-supplied
  # directories are the caller's to clean up.
  if [[ "$eval_cache_owned" == "1" && -n "$eval_cache_dir" && -d "$eval_cache_dir" ]]; then
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
    --build-checks)
      build_checks=true
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
    --print-sandbox-exclusions)
      print_sandbox_exclusions=true
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

need nix jq rg flock

local_attic_cache="http://127.0.0.1:8080/nixhomeserver"
if nix_uses_substituter "$local_attic_cache"; then
  need curl nohup
  ensure_local_attic_tunnel \
    "$local_attic_cache/nix-cache-info" \
    "${NIXHOMESERVER_ATTIC_TUNNEL_SCRIPT:-$HOME/.local/bin/nixhomeserver-attic-tunnel}" \
    "${XDG_CACHE_HOME:-$HOME/.cache}/nixhomeserver-attic-tunnel.log"
fi

if [[ -z "${REPO_NIX_EVAL_CACHE_DIR:-}" ]]; then
  eval_cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/nixhomeserver/eval-cache"
  content_hash="$(repo_content_hash || true)"
  if [[ -n "$content_hash" ]]; then
    # Persist across runs. Keying the directory by repository content (not
    # just its path) makes entries from an older revision unreachable instead
    # of stale, so repeated validation reuses host-config evals safely.
    eval_cache_key="$(nix_cache_hash "${repo_root}"$'\n'"$content_hash")"
    eval_cache_dir="${eval_cache_root}/${eval_cache_key}"
    mkdir -p "$eval_cache_dir"
    # Bound growth: keep the most recent cache generations only.
    find "$eval_cache_root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
      | sort -rn | awk 'NR>4 {print $2}' | while IFS= read -r stale; do
        [[ "$stale" == "$eval_cache_dir" ]] || rm -rf "$stale"
      done
  else
    # Content hashing is unavailable (for example outside a Git worktree): a
    # path-only key would go stale across edits, so use a throwaway cache that
    # cleanup_tmpdirs removes on exit.
    eval_cache_dir="$(mktemp -d "${TMPDIR:-/tmp}/nixhomeserver-eval-cache.XXXXXX")"
    eval_cache_owned="1"
  fi
  export REPO_NIX_EVAL_CACHE_DIR="$eval_cache_dir"
else
  # A caller-supplied directory is the caller's to manage; remember its path so
  # commit_validation_roots stages its manifest inside it instead of at "/".
  eval_cache_dir="$REPO_NIX_EVAL_CACHE_DIR"
fi

current_system() {
  nix eval --impure --raw --expr 'builtins.currentSystem'
}

# Checks that must never be built inside a Nix derivation sandbox, with the
# direct workstation path that keeps their coverage instead.
#
# The class: a derivation that shells out to the invoking user's tools. A remote
# builder's sandbox has no PATH into cargo, hermes, systemd-tmpfiles or
# ~/.local/bin, so such a check fails on the server and passes on the
# workstation. Measured evidence and the numbers behind it are in
# documentation/operations.md, "Builds".
#
# Every row is a known coverage-preserving relocation: the check on the left,
# and the one direct path on the right that runs that check's own coverage.
#
# Rule for changing this table: add a row only with that check's own failure
# output from a remote build. A shared cause across a group of failing checks is
# a hypothesis, not evidence, and must never be used to exclude a check whose
# own failure was not sampled. Never exclude a check to make the gate green.
sandbox_exclusion_table() {
  cat <<'EOF'
repo-policy|scripts/tests/run-script-tests.sh
EOF
}

# The effective table. A caller-supplied table is the regression seam, not a
# policy switch: it may only select rows from the known table above, and every
# row it names must be a relocation the gate can prove preserves coverage.
# Without that restriction any executable in the tree could stand in for a
# check's validation path, drop its coverage, and still let the gate report a
# pass.
sandbox_excluded_checks() {
  if [[ -n "${VALIDATE_REPO_SANDBOX_EXCLUSIONS:-}" ]]; then
    cat "${VALIDATE_REPO_SANDBOX_EXCLUSIONS}"
    return 0
  fi
  sandbox_exclusion_table
}

# Print the one direct path known to preserve $1's coverage; return 1 for a
# check the table does not know how to relocate.
sandbox_exclusion_known_path() {
  local check_name="$1" entry direct_path
  while IFS='|' read -r entry direct_path; do
    [[ "$entry" == "$check_name" ]] || continue
    printf '%s\n' "$direct_path"
    return 0
  done < <(sandbox_exclusion_table)
  return 1
}

# Print the direct validation path for a sandbox-excluded check. Returns 1 when
# the check is not excluded, and fails the gate (exit 2 to the caller) whenever
# the exclusion cannot preserve the check's coverage:
#   - an entry naming a check the table does not know,
#   - a direct path that is not that check's known path (any other executable,
#     however plausible, does not run this check's coverage), or
#   - a known direct path that is missing or not executable.
# An exclusion that silently drops coverage is worse than the remote failure it
# avoids, so none of these is ever a skip.
sandbox_exclusion_direct_path() {
  local check_name="$1" entry direct_path known_path
  while IFS='|' read -r entry direct_path; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" != "$check_name" ]]; then
      continue
    fi
    if ! known_path="$(sandbox_exclusion_known_path "$check_name")"; then
      echo "❌ ${check_name} is excluded from derivation builds but is not a" \
        "known sandbox-excluded check; an exclusion needs that check's own" \
        "remote-build failure evidence." >&2
      return 2
    fi
    if [[ -z "$direct_path" || ! -x "$repo_root/$direct_path" ]]; then
      echo "❌ ${check_name} is excluded from derivation builds but its direct" \
        "validation path is missing or not executable: ${direct_path:-<unset>}" >&2
      return 2
    fi
    if [[ "$direct_path" != "$known_path" ]]; then
      echo "❌ ${check_name} is excluded from derivation builds onto an unrelated" \
        "direct path: ${direct_path}. Its coverage-preserving path is ${known_path}." >&2
      return 2
    fi
    printf '%s\n' "$direct_path"
    return 0
  done < <(sandbox_excluded_checks)
  return 1
}

# Reject an unusable exclusion table before the gate spends a worklist
# evaluation or a build on it. The helper above names the specific reason; the
# exit here is what keeps the gate from reaching a narrowed run it would then
# report as a pass.
validate_sandbox_exclusion_table() {
  local entry_name _direct_path status
  while IFS='|' read -r entry_name _direct_path; do
    [[ -n "$entry_name" ]] || continue
    status=0
    sandbox_exclusion_direct_path "$entry_name" >/dev/null || status=$?
    ((status == 0)) || exit 1
  done < <(sandbox_excluded_checks)
}

# Evaluate the flake check worklist in one batched evaluation instead of paying a
# local module-system instantiation for it.
#
# Why batch: Nix shares nothing between separate `nix eval` processes, and this
# gate needs two answers from the same flake (the host system, and the check
# names for that system). One remote_eval_batch_json call carries both, and by
# default runs them on the build server rather than the four-core workstation.
# The `nix build` below is deliberately untouched: only evaluation moves.
#
# Why fail closed on shape: a transport or payload problem must never read as an
# empty (or silently narrower) worklist, because the gate would then report
# success without having checked anything. Every field is validated here, and a
# malformed payload stops the gate instead of being retried locally, so a broken
# offload can never quietly shrink the check set.
#
# Sets eval_batch_system and CHECK_WORKLIST_NAMES.
evaluate_check_worklist() {
  local all_apps_flag="$1" batch system names name_count names_inline remote_stderr
  local fell_back=1 eval_receipt_host batch_expr

  remote_stderr="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-worklist-stderr.XXXXXX")" || {
    echo "❌ Could not create a worklist diagnostic file." >&2
    exit 1
  }

  # ${all_apps_flag} is a Nix boolean literal and both sides are named with
  # `f.` rather than `builtins.getFlake .#`, so one expression is valid whether
  # or not the repository-wide attr exists on this revision.
  if [[ "$all_apps_flag" == "true" ]]; then
    batch_expr='builtins.attrNames f.legacyPackages.${builtins.currentSystem}.nixhomeserverAllChecks'
  else
    batch_expr='builtins.attrNames f.checks.${builtins.currentSystem}'
  fi

  if ! batch="$(
    remote_eval_batch_json \
      'batchSystem=builtins.currentSystem' \
      "batchNames=${batch_expr}" \
      2>"$remote_stderr"
  )"; then
    cat "$remote_stderr" >&2
    rm -f "$remote_stderr"
    echo "❌ Could not evaluate the flake check worklist." >&2
    exit 1
  fi

  # The helper's diagnostics belong on this gate's stderr; a caller watching the
  # log must see whether the evaluation actually went remote.
  cat "$remote_stderr" >&2

  # An explicit REMOTE_EVAL=0 is a deliberate local run and prints no fallback
  # warning, so the opt-out itself decides the receipt, not the absence of one.
  if [[ "${REMOTE_EVAL:-1}" == "0" ]]; then
    fell_back=0
  elif grep -q '^remote-eval: falling back to local evaluation' "$remote_stderr"; then
    fell_back=0
  fi
  rm -f "$remote_stderr"

  if ! jq -e '
    type == "object"
    and (.batchSystem | type == "string" and test("^[A-Za-z0-9_]+-[A-Za-z0-9_]+$"))
    and (.batchNames | type == "array" and length > 0)
    and all(.batchNames[]; type == "string" and length > 0)
  ' <<<"$batch" >/dev/null 2>&1; then
    echo "❌ The check worklist evaluation returned a malformed payload: ${batch}" >&2
    exit 1
  fi

  system="$(jq -r '.batchSystem' <<<"$batch")"
  names="$(jq -r '.batchNames | sort | .[]' <<<"$batch")"

  # The helper runs inside a command substitution, so the host it cached is gone
  # by the time it returns. Re-resolve it here, through the same resolver, and
  # say "unknown" rather than guessing when even that fails.
  eval_receipt_host="$(_remote_eval_resolve_host 2>/dev/null || true)"
  eval_receipt_host="${eval_receipt_host:-an unknown host}"

  # ${#names} is a character count, not a check count. Counting lines is what
  # makes the receipt a truthful one.
  name_count="$(grep -c . <<<"$names")"
  names_inline="${names//$'\n'/, }"

  if ((fell_back == 1)); then
    # Receipt: naming the build server that ran the evaluation is what makes an
    # offloaded gate auditable, instead of a claim nobody can check. The host is
    # resolved through the helper's own resolver, the same one it uses to open
    # the connection, so the receipt cannot name a host it did not reach.
    echo "ℹ️ Evaluated the check worklist on ${eval_receipt_host}" \
      "(${names_inline}); ${name_count} checks, in one batched query."
  else
    echo "ℹ️ Evaluated the check worklist on this workstation" \
      "(${names_inline}); ${name_count} checks."
  fi

  eval_batch_system="$system"
  CHECK_WORKLIST_NAMES="$names"
}

build_derivation_attr() {
  local attr="$1" system="$2" check_name check_names output_path root_path direct_path
  local -a check_targets=()
  local new_outputs

  if [[ -z "${CHECK_WORKLIST_NAMES:-}" ]]; then
    echo "❌ Could not evaluate a non-empty flake check worklist for ${attr}." >&2
    exit 1
  fi
  check_names="$CHECK_WORKLIST_NAMES"

  while IFS= read -r check_name; do
    [[ -n "$check_name" ]] || continue
    local exclusion_status=0
    direct_path="$(sandbox_exclusion_direct_path "$check_name")" || exclusion_status=$?
    if ((exclusion_status == 2)); then
      # Never a skip: an exclusion with no working direct path fails the gate.
      exit 1
    fi
    if ((exclusion_status == 0)); then
      # Coverage is preserved by running it directly on this host, so the
      # exclusion is only ever a relocation, never a skip.
      echo "ℹ️ Building ${check_name} is excluded: a derivation sandbox has no" \
        "PATH into the invoking user's tools. It runs directly here via ${direct_path}."
      continue
    fi
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
    nix build "${check_targets[@]}" --keep-going --no-link --print-build-logs --json
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

run_derivation_checks() {
  local system check_attr root_state_dir output_path root_path

  if [[ "$full_mode" != true && "$build_checks" != true ]]; then
    return 0
  fi

  # Fail closed before the worklist evaluation or any build: an exclusion that
  # cannot preserve its check's coverage must not survive to the point where the
  # gate reports a narrowed run as a pass.
  validate_sandbox_exclusion_table

  if [[ "$all_apps" == true ]]; then
    evaluate_check_worklist true
  else
    evaluate_check_worklist false
  fi
  # The system that reported the worklist names it, so the build targets and the
  # worklist cannot drift apart through two independent local evals.
  system="$eval_batch_system"

  if [[ "$all_apps" == true ]]; then
    check_attr="legacyPackages.${system}.nixhomeserverAllChecks"
  else
    check_attr="checks.${system}"
  fi

  build_derivation_attr "$check_attr" "$system"
  # VM tests are run separately via --run-vm-tests flag
  # build_derivation_attr "$vm_attr" "$system"

  if [[ "$full_mode" != true || "$all_apps" == true ]]; then
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

retain_validation_roots="${VALIDATE_RETAIN_OUTPUT_ROOTS:-0}"
case "$retain_validation_roots" in
  0|1) ;;
  *)
    echo "❌ VALIDATE_RETAIN_OUTPUT_ROOTS must be 0 or 1." >&2
    exit 1
    ;;
esac

commit_validation_roots() {
  local root_state_dir current_dir desired_manifest output_path root_path existing_root lock_fd

  if [[ "$full_mode" != true || "$all_apps" == true ]]; then
    return 0
  fi

  root_state_dir="${VALIDATE_REPO_ROOTS_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/nixhomeserver/validation-roots}"
  current_dir="$root_state_dir/current"
  desired_manifest="$eval_cache_dir/desired-validation-roots"
  install -d -m 0700 "$current_dir"
  exec {lock_fd}>"$root_state_dir/.roots.lock"
  flock "$lock_fd"

  if [[ "$retain_validation_roots" != 1 || -z "$validation_outputs_json" ]]; then
    while IFS= read -r -d '' existing_root; do
      if [[ -e "$existing_root" && ! -L "$existing_root" ]]; then
        echo "❌ Refusing to remove non-symlink validation root: $existing_root" >&2
        exit 1
      fi
      rm -f "$existing_root"
    done < <(find "$current_dir" -mindepth 1 -maxdepth 1 -type l -print0)
    rm -rf "$pending_validation_roots_dir"
    pending_validation_roots_dir=""
    if [[ "$retain_validation_roots" == 0 ]]; then
      echo "ℹ️ Released prior full-validation outputs; they are eligible for Nix GC."
    fi
    return 0
  fi

  mkdir -p "$eval_cache_dir"
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

if [[ "$print_sandbox_exclusions" == true ]]; then
  # Report the known policy surface itself -- not a caller-supplied selection
  # from it -- so a change to what may be excluded is reviewable as a diff
  # without running the gate.
  sandbox_exclusion_table
  exit 0
fi

if [[ "$skip_flake_check" == false ]]; then
  if [[ "$full_mode" == true || "$run_flake_check" == true ]]; then
    echo "ℹ️ Running flake checks (no build)…"
    nix flake check --no-build
  fi
fi

run_derivation_checks
run_shell_tests
run_vm_tests
run_full_e2e_checks
commit_validation_roots

echo "✅ Repository checks passed."
