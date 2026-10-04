#!/usr/bin/env bash

# Proves the private deploy-archive staging namespace contract:
#
#   * a staged archive lands inside the dedicated namespace with owner-only
#     directory and file modes;
#   * a successful upload that is orphaned when the SSH session dies before the
#     executor's cleanup trap still expires on its own, bounded independently of
#     that session;
#   * the normal completion path and the failed-transfer path both still remove
#     the archive immediately;
#   * no removal path can be redirected outside the namespace: traversal,
#     foreign names, other directories, and planted symlinks are all refused or
#     unlinked without touching their targets.
#
# Everything is local and mocked. No SSH session, server, or real deploy is
# contacted: `ssh` is replaced by a shell function that runs the remote command
# locally against a temporary directory, and the expiry step runs a real
# systemd-tmpfiles binary against a temporary root. systemd-tmpfiles is read from
# the Nix store (or PATH) as a local tool; no Nix build or substitution occurs.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash rg stat jq

helper="scripts/helpers/deploy-archive-cleanup.sh"
repo_common="scripts/helpers/repo-common.sh"
deploy_script="scripts/deploy.sh"

# Source the helper so its individual containment layers can be asserted one at
# a time. Its own entry point is guarded, so sourcing it defines functions
# without running anything.
# shellcheck source=scripts/helpers/deploy-archive-cleanup.sh
source "$helper"
declare -F deploy_archive_shape_is_rejected >/dev/null ||
  { echo "❌ $helper does not expose its containment layers" >&2; exit 1; }

failures=0
note_failure() {
  echo "❌ $1" >&2
  failures=$((failures + 1))
}

test_root="$(mktemp -d)"
cleanup() { rm -rf "$test_root"; }
trap cleanup EXIT

[[ "$(env -u NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE bash "$helper" namespace 2>&1 || true)" == *'/var/lib/nixhomeserver-deploy-archives'* ]] ||
  note_failure "production helper must use the approved sibling namespace"

namespace="$test_root/archive-staging"
mkdir -p "$namespace"
chmod 0700 "$namespace"
export NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$namespace"

# --- Mocked ssh ------------------------------------------------------------
#
# The deploy flow only ever calls ssh as `ssh [-T] <host> <command>` with any
# payload on stdin. This function drops the flags and destination and runs the
# command locally, which exercises the remote half of the contract with no
# network and no server.
ssh() {
  while (($# > 0)); do
    case "$1" in
      -T) shift ;;
      *) break ;;
    esac
  done
  shift # drop the destination
  local command_text="${1:-}"
  [[ -n "$command_text" ]] || return 0
  bash -c "$command_text"
}
export -f ssh

# Simulate a dropped session: the remote command never runs at all, so whatever
# it would have cleaned up is left behind.
ssh_session_drops() { :; }

expect_refused() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    note_failure "$description (expected a refusal, the command succeeded)"
  else
    echo "  ok (refused): $description"
  fi
}

# --- Staging refuses an unusable namespace ---------------------------------

expect_refused "staging with a missing namespace" \
  env NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$test_root/absent" \
  bash "$helper" stage nixhomeserver-deploy

group_readable="$test_root/group-readable"
mkdir -p "$group_readable"
chmod 0750 "$group_readable"
expect_refused "staging with a group-readable namespace" \
  env NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$group_readable" \
  bash "$helper" stage nixhomeserver-deploy

world_readable="$test_root/world-readable"
mkdir -p "$world_readable"
chmod 0755 "$world_readable"
expect_refused "staging with a world-readable namespace" \
  env NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$world_readable" \
  bash "$helper" stage nixhomeserver-deploy

symlinked_namespace="$test_root/symlinked-namespace"
ln -s "$namespace" "$symlinked_namespace"
expect_refused "staging through a symlinked namespace" \
  env NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$symlinked_namespace" \
  bash "$helper" stage nixhomeserver-deploy

expect_refused "staging with an unexpected action" bash "$helper" shred nixhomeserver-deploy
expect_refused "staging with a traversing label" bash "$helper" stage "../escape"

# --- A staged archive is owner-only and inside the namespace ---------------

staged="$(bash "$helper" stage nixhomeserver-deploy)"
case "$staged" in
  "$namespace"/*) ;;
  *) note_failure "staged archive escaped the namespace: $staged" ;;
esac
if [[ "$(stat -c '%a' "$staged")" != "600" ]]; then
  note_failure "staged archive must be owner-only, got mode $(stat -c '%a' "$staged")"
fi
if [[ "$(stat -c '%a' "$namespace")" != "700" ]]; then
  note_failure "namespace must stay owner-only, got mode $(stat -c '%a' "$namespace")"
fi
echo "  ok: staged archive is owner-only inside the namespace"

bash "$helper" remove "$staged" || note_failure "removing a staged archive must succeed"
if [[ -e "$staged" ]]; then
  note_failure "staged archive still present after removal"
else
  echo "  ok: staged archive removed immediately"
fi

# --- Removal cannot escape the namespace -----------------------------------

outside="$test_root/outside"
mkdir -p "$outside"
printf 'outside-content\n' >"$outside/victim.txt"

expect_refused "removal of /etc/passwd" bash "$helper" remove /etc/passwd
expect_refused "removal of a traversing path" bash "$helper" remove "$namespace/../outside/victim.txt"
expect_refused "removal of an archive-shaped path outside the namespace" \
  bash "$helper" remove "$outside/nixhomeserver-deploy.ABCDEFGH.tar"
expect_refused "removal of an unrecognised entry name in the namespace" \
  bash "$helper" remove "$namespace/not-an-archive.txt"
expect_refused "removal of a relative path" bash "$helper" remove nixhomeserver-deploy.ABCDEFGH.tar
expect_refused "removal of a nested directory inside the namespace" \
  bash "$helper" remove "$namespace/sub/nixhomeserver-deploy.ABCDEFGH.tar"
expect_refused "removal of a crafted trailing traversal" \
  bash "$helper" remove "$namespace/nixhomeserver-deploy.ABCDEFGH.tar/../../outside/victim.txt"
expect_refused "removal of a name with no mktemp placeholder run" \
  bash "$helper" remove "$namespace/nixhomeserver-deploy.tar"
expect_refused "removal of a name with extra suffix characters" \
  bash "$helper" remove "$namespace/nixhomeserver-deploy.ABCDEFGH.tar.evil"
expect_refused "removal of a path with whitespace" \
  bash "$helper" remove "$namespace/nixhomeserver-deploy.ABCDEFGH.tar "

if [[ ! -f "$outside/victim.txt" ]]; then
  note_failure "a refused removal still deleted a file outside the namespace"
fi

# Each containment layer is asserted on its own, because the layers are
# deliberately redundant. Redundancy that cannot be exercised one layer at a
# time is indistinguishable from dead code, so a layer that stops rejecting its
# own escape is a failure even when the surrounding layers still catch it.
expect_rejected_by_layer() {
  local description="$1" layer="$2"
  shift 2
  if "$layer" "$@" >/dev/null 2>&1; then
    echo "  ok (refused by ${layer}): $description"
  else
    note_failure "$description (the ${layer} layer accepted it)"
  fi
}

expect_predicate_true() {
  local description="$1" predicate="$2"
  shift 2
  if "$predicate" "$@" >/dev/null 2>&1; then
    echo "  ok (detected): $description"
  else
    note_failure "$description (${predicate} did not detect it)"
  fi
}

expect_predicate_false() {
  local description="$1" predicate="$2"
  shift 2
  if "$predicate" "$@" >/dev/null 2>&1; then
    note_failure "$description (${predicate} raised a false positive)"
  else
    echo "  ok (not detected): $description"
  fi
}

resolved_namespace="$(cd -P -- "$namespace" && pwd -P)"
expect_rejected_by_layer "traversal component" deploy_archive_shape_is_rejected \
  "$namespace/../outside/victim.txt"
expect_rejected_by_layer "crafted trailing traversal" deploy_archive_shape_is_rejected \
  "$namespace/nixhomeserver-deploy.ABCDEFGH.tar/../../outside/victim.txt"
expect_rejected_by_layer "non-absolute path" deploy_archive_shape_is_rejected \
  "nixhomeserver-deploy.ABCDEFGH.tar"
expect_rejected_by_layer "path with whitespace" deploy_archive_shape_is_rejected \
  "$namespace/nixhomeserver-deploy.ABCDEFGH.tar "
expect_rejected_by_layer "path with an embedded newline" deploy_archive_shape_is_rejected \
  "$namespace/nixhomeserver-deploy.ABCDEFGH.tar"$'\n'"/etc/passwd"
expect_rejected_by_layer "entry name without a placeholder run" deploy_archive_entry_name_is_rejected \
  "$namespace/nixhomeserver-deploy.tar"
expect_rejected_by_layer "entry name with an extra suffix" deploy_archive_entry_name_is_rejected \
  "$namespace/nixhomeserver-deploy.ABCDEFGH.tar.evil"
expect_rejected_by_layer "entry name that is not an archive" deploy_archive_entry_name_is_rejected \
  "$namespace/not-an-archive.txt"
expect_rejected_by_layer "literal parent outside the namespace" deploy_archive_literal_parent_is_rejected \
  "$outside/nixhomeserver-deploy.ABCDEFGH.tar" "$resolved_namespace"

# A directory that looks like the namespace but resolves elsewhere must be
# refused by the indirection layer, not only by the literal one.
mkdir -p "$test_root/indirection"
ln -sfn "$outside" "$test_root/indirection/looks-like-namespace"
expect_rejected_by_layer "resolved parent that is not the namespace" \
  deploy_archive_resolved_parent_is_rejected \
  "$test_root/indirection/looks-like-namespace/nixhomeserver-deploy.ABCDEFGH.tar" \
  "$resolved_namespace"

# The namespace predicates are asserted individually for the same reason: a
# composite readiness check is only ever exercised through whichever condition
# happens to fire first.
read_only_namespace="$test_root/read-only"
mkdir -p "$read_only_namespace"
chmod 0500 "$read_only_namespace"
expect_predicate_true "a missing namespace is detected" deploy_archive_namespace_missing "$test_root/absent"
expect_predicate_true "a symlinked namespace is detected" deploy_archive_namespace_is_symlink "$symlinked_namespace"
expect_predicate_true "a group-readable namespace is detected" \
  deploy_archive_namespace_is_group_or_world_accessible "$group_readable"
expect_predicate_true "a world-readable namespace is detected" \
  deploy_archive_namespace_is_group_or_world_accessible "$world_readable"
expect_predicate_true "an unwritable namespace is detected" \
  deploy_archive_namespace_is_unusable_by_caller "$read_only_namespace"
expect_predicate_false "a sound namespace is not reported missing" deploy_archive_namespace_missing "$namespace"
expect_predicate_false "a sound namespace is not reported as a symlink" deploy_archive_namespace_is_symlink "$namespace"
expect_predicate_false "a sound namespace is not reported as group/world accessible" \
  deploy_archive_namespace_is_group_or_world_accessible "$namespace"
expect_predicate_false "a sound namespace is not reported as unwritable" \
  deploy_archive_namespace_is_unusable_by_caller "$namespace"

# A symlink planted inside the namespace is unlinked, never followed.
victim_link="$namespace/nixhomeserver-deploy.LINKED01.tar"
ln -s "$outside/victim.txt" "$victim_link"
bash "$helper" remove "$victim_link" || note_failure "removing a planted symlink must succeed"
if [[ ! -f "$outside/victim.txt" ]]; then
  note_failure "removal followed a symlink out of the namespace"
fi
if [[ -e "$victim_link" ]]; then
  note_failure "planted symlink was not unlinked"
else
  echo "  ok: planted symlink unlinked without touching its target"
fi

# A symlink whose target is a directory inside the namespace must not delete
# that directory's contents either.
mkdir -p "$test_root/decoy"
printf 'decoy\n' >"$test_root/decoy/keep.txt"
decoy_link="$namespace/nixhomeserver-deploy.LINKED03.tar"
ln -s "$test_root/decoy" "$decoy_link"
bash "$helper" remove "$decoy_link" || note_failure "removing a directory symlink must succeed"
[[ -f "$test_root/decoy/keep.txt" ]] ||
  note_failure "removal recursed through a symlink into a directory"
echo "  ok: directory symlink unlinked without recursing"

# --- The transfer path, end to end through the mocked host -----------------

# shellcheck source=scripts/helpers/repo-common.sh
source "$repo_common"
declare -F stage_archive_on_remote >/dev/null || {
  echo "❌ stage_archive_on_remote is not defined by repo-common.sh" >&2
  exit 1
}

source_archive="$test_root/payload.tar"
printf 'archive-payload\n' >"$source_archive"

# The transfer delivers its own payload on each ssh call, exactly as the real
# function does, so the test must not pre-load stdin: doing so would let a
# function that uploads nothing still pass, because the outer redirection would
# supply the helper content the broken function no longer sends.
remote_archive="$(stage_archive_on_remote "$source_archive" "admin@test.invalid" "nixhomeserver-deploy")" ||
  remote_archive=""
if [[ -z "$remote_archive" ]]; then
  note_failure "staging an archive through the mocked host must succeed"
else
  case "$remote_archive" in
    "$namespace"/*) ;;
    *) note_failure "staged remote archive escaped the namespace: $remote_archive" ;;
  esac
  if [[ "$(cat "$remote_archive" 2>/dev/null || true)" != "archive-payload" ]]; then
    note_failure "the staged archive did not receive the source payload"
  else
    echo "  ok: transfer staged and filled an archive inside the namespace"
  fi
fi

# The transfer must fail safe when the namespace is unavailable, with no
# fallback to a general temporary directory.
fallback_archive="$(NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$test_root/absent" \
  stage_archive_on_remote "$source_archive" "admin@test.invalid" "nixhomeserver-deploy" \
  2>/dev/null)" ||
  fallback_archive=""
if [[ -n "$fallback_archive" ]]; then
  note_failure "staging must fail when the namespace is unavailable, not fall back"
else
  echo "  ok: no staging fallback when the namespace is unavailable"
fi

# A failed transfer removes the partially written archive immediately.
#
# The mock must fail ONLY the archive write, identified by its `.tar` target.
# An earlier version failed every command containing `cat >`, which also matched
# the subsequent removal call, so the removal was never really exercised and the
# assertion passed for the wrong reason.
transfer_root="$test_root/transfer-failure"
mkdir -p "$transfer_root/archive-staging"
chmod 0700 "$transfer_root/archive-staging"

failed_transfer_output="$(
  NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$transfer_root/archive-staging" \
  bash -c '
    ssh() {
      while (($# > 0)); do
        case "$1" in -T) shift ;; *) break ;; esac
      done
      shift
      local command_text="${1:-}"
      if [[ "$command_text" == *"cat > "*".tar"* ]]; then
        # The archive write fails after the helper has already been delivered;
        # the removal that follows must still work.
        cat >/dev/null
        return 1
      fi
      bash -c "$command_text"
    }
    source scripts/helpers/repo-common.sh
    stage_archive_on_remote "$1" admin@test.invalid nixhomeserver-deploy
  ' _ "$source_archive" 2>/dev/null
)" ||
  failed_transfer_output=""
if [[ -n "$failed_transfer_output" ]]; then
  note_failure "a failed transfer must not report a usable archive path"
fi
if find "$transfer_root/archive-staging" -mindepth 1 -print -quit | grep -q .; then
  note_failure "a failed transfer left a partially written archive behind"
else
  echo "  ok: failed transfer removed its partially written archive"
fi

# A transfer that reaches the namespace check must be able to fail on its own
# terms. This runs the real staging function with a genuinely missing source
# archive, so a broken transfer cannot report a usable path while the staged
# copy it points at was never really created.
broken_transfer_output="$(
  NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$namespace" \
  bash -c '
    ssh() {
      while (($# > 0)); do
        case "$1" in -T) shift ;; *) break ;; esac
      done
      shift
      local command_text="${1:-}"
      [[ -n "$command_text" ]] || return 0
      bash -c "$command_text"
    }
    source scripts/helpers/repo-common.sh
    stage_archive_on_remote "$1" admin@test.invalid nixhomeserver-deploy
  ' _ "$test_root/there-is-no-such-archive.tar" 2>/dev/null
)" ||
  broken_transfer_output=""
if [[ -n "$broken_transfer_output" ]]; then
  note_failure "a transfer of a missing archive must not report a usable path"
else
  echo "  ok: transfer of a missing archive reports no usable path"
fi

# The helper that defines the namespace contract must itself be present, or the
# transfer must fail rather than stage an archive nothing can later remove. The
# diagnostic matters as much as the failure: without the guard the deploy dies
# on a bare shell redirection error instead of naming the missing helper.
absent_helper_output="$(
  bash -c '
    source scripts/helpers/repo-common.sh
    deploy_archive_helper_path=/nonexistent/deploy-archive-cleanup.sh
    stage_archive_on_remote "$1" admin@test.invalid nixhomeserver-deploy
  ' _ "$source_archive" 2>&1
)" || true
# The guard makes this fail, so the captured text is the diagnostic, not a
# usable archive path. Do not reset it on a non-zero exit: that would discard
# the very message this check exists to assert.
if [[ "$absent_helper_output" == /* ]]; then
  note_failure "a transfer must not proceed when the namespace helper is missing"
fi
if [[ "$absent_helper_output" != *"staging helper is missing"* ]]; then
  note_failure "a missing namespace helper must be reported as such, got: ${absent_helper_output}"
else
  echo "  ok: transfer refuses to proceed without the namespace helper"
fi

# A remote host that answers with something other than a single absolute path
# must not be trusted: a diagnostic line, a wrapped error, or a blank answer
# would otherwise be handed to `tar` as a filename.
#
# The reply is injected as an environment variable rather than interpolated,
# and the archive write below is given an explicit path, so no stray file is
# created in the repository root.
for bogus_reply in '' 'not-a-path' $'/tmp/one\n/tmp/two' 'mktemp: failed to create file'; do
  noisy_root="$test_root/noisy-host"
  mkdir -p "$noisy_root/archive-staging"
  chmod 0700 "$noisy_root/archive-staging"
  noisy_output="$(
    NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$noisy_root/archive-staging" REPLY="$bogus_reply" \
    bash -c '
      ssh() {
              while (($# > 0)); do
                case "$1" in -T) shift ;; *) break ;; esac
              done
              shift
              local command_text="${1:-}"
              # The staging call is the one that uploads the helper and claims the
              # slot; the archive write is the later, separate `cat >` of the payload.
              case "$command_text" in
                *"bash \"\$helper\" stage"*)
                  # Discard the genuine path so only the injected reply remains.
                  bash -c "$command_text" >/dev/null
                  printf "%s\\n" "$REPLY"
                  return 0
                  ;;
                *".tar"*)
                  cat >/dev/null
                  return 0
                  ;;
              esac
              bash -c "$command_text"
            }
      source scripts/helpers/repo-common.sh
      stage_archive_on_remote "$1" admin@test.invalid nixhomeserver-deploy
    ' _ "$source_archive" 2>/dev/null
  )" ||
    noisy_output=""
  if [[ -n "$noisy_output" ]]; then
    note_failure "a host reply of [${bogus_reply}] must not yield a usable archive path"
  fi
done
echo "  ok: unusable host replies are all rejected"

# An orphaned upload: the transfer succeeds, then the session dies before the
# executor's cleanup trap can run. Nothing removes it in-session, so only the
# declared expiry can reclaim it.
orphan_root="$test_root/orphan-root"
mkdir -p "$orphan_root/var/lib/nixhomeserver-deploy-archives" "$orphan_root/outside"
chmod 0700 "$orphan_root/var/lib/nixhomeserver-deploy-archives"
orphan_archive="$orphan_root/var/lib/nixhomeserver-deploy-archives/nixhomeserver-deploy.ORPHANED.tar"
printf 'orphaned-payload\n' >"$orphan_archive"
printf 'still-here\n' >"$orphan_root/outside/victim.txt"

# Prefer a systemd-tmpfiles on PATH; otherwise fall back to one already present
# in the local Nix store. This is a read of an existing local binary, not a
# build or substitution, so the test stays offline.
tmpfiles_bin="$(command -v systemd-tmpfiles 2>/dev/null || true)"
if [[ -z "$tmpfiles_bin" ]]; then
  # `ls -d` on a glob is fine here: every match is a Nix store path, so there
  # are no irregular filenames to mangle.
  # shellcheck disable=SC2012
  tmpfiles_bin="$(ls -d /nix/store/*systemd-*/bin/systemd-tmpfiles 2>/dev/null | sort | tail -1 || true)"
fi

if [[ -z "$tmpfiles_bin" ]]; then
  note_failure "no systemd-tmpfiles binary available to prove expiry"
else
  # Build the expiry rule from the configuration itself, so this proves the
  # declarative contract rather than a re-statement of it.
  host="$(test_default_host)"
  if ! declared_rule="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
    host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
    cfg = (builtins.getAttr host f.nixosConfigurations).config;
    matching = builtins.filter
      (rule: builtins.match "d /var/lib/nixhomeserver-deploy-archives .*" rule != null)
      cfg.systemd.tmpfiles.rules;
  in {
    rules = matching;
    dir = cfg.repo.deploy.archiveStagingDir;
    contract = builtins.map
      (path: (builtins.getAttr host f.nixosConfigurations).options.repo.deploy.archiveStagingDir.type.check path)
      [ "/var/lib/nixhomeserver-deploy-archives"
        "/var/lib/nixhomeserver-deploy/archive-staging"
        "/var/lib/other" "/var/lib/nixhomeserver-deploy-archives/../other" ];
  }' |
    jq -er 'if .dir == "/var/lib/nixhomeserver-deploy-archives" and .contract == [true,false,false,false]
      then .rules | if length == 1 then .[0] else error("expected exactly one archive staging tmpfiles rule") end
      else error("archive namespace contract is not restricted to the approved sibling") end')"; then
    note_failure "could not read the archive staging tmpfiles rule from the configuration"
  else
    [[ "$declared_rule" == *" 0700 "* ]] ||
      note_failure "archive staging namespace must be declared owner-only, got: $declared_rule"
    [[ "$declared_rule" == *" mM:48h -" ]] ||
      note_failure "archive staging expiry must use the mtime-only 48h age, got: $declared_rule"
    # 48h must outlast the 26h transaction lock, or an in-flight deploy could
    # have its own archive reaped.
    [[ "${declared_rule#*mM:}" == "48h -" ]] ||
      note_failure "archive staging retention must be 48h, got: $declared_rule"
    echo "  ok: declared expiry rule is owner-only with a 48h mtime-only age"

    require_fixed modules/Core_Modules/base-system/default.nix 'mM:48h -' \
      "the expiry rule must survive a refactor of the deploy module"

    mkdir -p "$orphan_root/etc/tmpfiles.d"
    printf 'd /var/lib/nixhomeserver-deploy-archives 0700 %s %s mM:48h -\n' "$(id -u)" "$(id -g)" \
      >"$orphan_root/etc/tmpfiles.d/deploy.conf"

    "$tmpfiles_bin" --root="$orphan_root" --clean >/dev/null 2>&1
    if [[ ! -e "$orphan_archive" ]]; then
      note_failure "a fresh orphan must survive until its age is reached"
    else
      echo "  ok: fresh orphan retained"
    fi

    touch -m -d '72 hours ago' "$orphan_archive"
    "$tmpfiles_bin" --root="$orphan_root" --clean >/dev/null 2>&1
    if [[ -e "$orphan_archive" ]]; then
      note_failure "an orphaned archive older than the retention window must expire"
    else
      echo "  ok: orphaned archive expired after 48h"
    fi

    # An aged symlink must be unlinked, not followed. `touch -h` is required:
    # a plain `touch` follows the link and ages the target instead, which would
    # leave the link itself fresh and prove nothing.
    touch -m -d '72 hours ago' "$orphan_root/outside/victim.txt"
    expiry_link="$orphan_root/var/lib/nixhomeserver-deploy-archives/nixhomeserver-deploy.LINKED02.tar"
    ln -s "$orphan_root/outside/victim.txt" "$expiry_link"
    touch -h -m -d '72 hours ago' "$expiry_link"
    "$tmpfiles_bin" --root="$orphan_root" --clean >/dev/null 2>&1
    [[ -f "$orphan_root/outside/victim.txt" ]] ||
      note_failure "expiry followed a symlink out of the namespace"
    [[ -e "$expiry_link" ]] &&
      note_failure "expiry should unlink an aged symlink" ||
      echo "  ok: expiry unlinked the symlink without touching its target"

    # Expiry must not recurse through a directory symlink either.
    mkdir -p "$orphan_root/decoy"
    printf 'decoy\n' >"$orphan_root/decoy/keep.txt"
    decoy_link="$orphan_root/var/lib/nixhomeserver-deploy-archives/nixhomeserver-deploy.LINKED04.tar"
    ln -s "$orphan_root/decoy" "$decoy_link"
    touch -h -m -d '72 hours ago' "$decoy_link"
    "$tmpfiles_bin" --root="$orphan_root" --clean >/dev/null 2>&1
    [[ -f "$orphan_root/decoy/keep.txt" ]] ||
      note_failure "expiry recursed through a symlinked directory"
    echo "  ok: expiry did not recurse through a symlinked directory"

    # Expiry must never collect a fresh neighbour it was not asked to remove.
    printf 'fresh-neighbour\n' >"$orphan_root/var/lib/nixhomeserver-deploy-archives/nixhomeserver-deploy.FRESH000.tar"
    touch -m -d '72 hours ago' "$orphan_root/var/lib/nixhomeserver-deploy-archives"
    "$tmpfiles_bin" --root="$orphan_root" --clean >/dev/null 2>&1
    [[ -f "$orphan_root/var/lib/nixhomeserver-deploy-archives/nixhomeserver-deploy.FRESH000.tar" ]] ||
      note_failure "expiry removed a fresh archive it should have retained"
    echo "  ok: expiry retained a fresh neighbour"
  fi
fi

# --- Execute the actual production remote heredoc --------------------------
# Only the executor is stubbed: extraction, EXIT trap and helper are real.
ensure_tools python3 tar
python3 - "$deploy_script" "$helper" "$test_root" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tarfile

source, helper, root = map(Path, sys.argv[1:])
text = source.read_text()
marker = 'ssh -T "$build_host" "$remote_command" <<\'EOF\'\n'
assert text.count(marker) == 1, "remote wrapper marker is not unique"
wrapper = text.split(marker, 1)[1].split('\nEOF\n', 1)[0]
fixture = root / 'wrapper-fixture'
(fixture / 'scripts/helpers').mkdir(parents=True)
(fixture / 'scripts/helpers/deploy-archive-cleanup.sh').write_bytes(helper.read_bytes())
executor = fixture / 'scripts/helpers/deploy-executor.sh'
executor.write_text('exit "$STUB_EXECUTOR_STATUS"\n')
namespace = root / 'wrapper-staging'
namespace.mkdir(mode=0o700)
work = root / 'wrapper-work'
work.mkdir()
for status in (0, 17):
    archive = namespace / f'nixhomeserver-deploy.EXIT00{status:02d}.tar'
    with tarfile.open(archive, 'w') as tar:
        tar.add(fixture / 'scripts', arcname='scripts')
    archive.chmod(0o600)
    env = dict(os.environ, REMOTE_ARCHIVE=str(archive),
               NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE=str(namespace),
               STUB_EXECUTOR_STATUS=str(status), TMPDIR=str(work))
    result = subprocess.run(['bash', '-s'], input=wrapper, text=True,
                            env=env, cwd=root, capture_output=True)
    assert result.returncode == status, (result.returncode, result.stderr)
    assert not archive.exists(), f'exit {status}: archive survived EXIT cleanup'
    assert not list(work.iterdir()), f'exit {status}: extracted tree survived'
    print(f'  ok: actual remote wrapper exit {status}, immediate archive/tree removal')

# Corrupt tar never supplies a trusted helper. Leave it for expiry, not bare rm.
archive = namespace / 'nixhomeserver-deploy.BADTAR00.tar'
archive.write_text('not a tar archive')
result = subprocess.run(['bash', '-s'], input=wrapper, text=True,
                        env=dict(env, REMOTE_ARCHIVE=str(archive)),
                        cwd=root, capture_output=True)
assert result.returncode != 0, 'corrupt tar unexpectedly succeeded'
assert archive.exists(), 'extraction failure used an unsafe removal fallback'
assert not list(work.iterdir()), 'extraction failure leaked working directory'
print('  ok: extraction failure retains archive for expiry without unsafe deletion')

# A tar error after the helper was extracted must still use it before cd.
archive = namespace / 'nixhomeserver-deploy.PARTIAL0.tar'
with tarfile.open(archive, 'w') as tar:
    tar.add(fixture / 'scripts/helpers/deploy-archive-cleanup.sh',
            arcname='scripts/helpers/deploy-archive-cleanup.sh')
    tar.add(executor, arcname='scripts/helpers/deploy-executor.sh')
# Force a real read error in a later member, after the complete helper member.
with tarfile.open(archive) as tar:
    last = tar.getmember('scripts/helpers/deploy-executor.sh')
    cut_at = last.offset_data
archive.write_bytes(archive.read_bytes()[:cut_at])
result = subprocess.run(['bash', '-s'], input=wrapper, text=True,
                        env=dict(env, REMOTE_ARCHIVE=str(archive)),
                        cwd=root, capture_output=True)
assert result.returncode != 0, 'truncated tar unexpectedly succeeded'
assert not archive.exists(), 'partial extraction lost access to available helper'
assert not list(work.iterdir()), 'partial extraction leaked working directory'
print('  ok: partial extraction failure uses available constrained helper before cd')
PY

require_match "$deploy_script" \
  'bash "\$tmpdir/scripts/helpers/deploy-archive-cleanup\.sh" remove "\$REMOTE_ARCHIVE"' \
  "deploy.sh must remove the staged archive through the namespace helper"
forbid_match "$deploy_script" \
  'rm -rf "\$tmpdir" "\$REMOTE_ARCHIVE"' \
  "deploy.sh must not delete the archive with an unvalidated rm"

# --- The ciphertext-only archive policy is preserved -----------------------

require_fixed "$repo_common" 'Refusing to archive tracked plaintext secret path' \
  "the archive manifest must still refuse tracked plaintext secret paths"
require_fixed "$repo_common" 'Refusing to deploy with untracked, non-ignored files.' \
  "the archive must still refuse a dirty worktree"
require_fixed "$repo_common" 'tar -C "$repo_root" --null -T "$manifest" -cf "$archive_path"' \
  "the archive must still be built from the tracked-file manifest, not a directory sweep"
# The refusal is only load-bearing if it still names every plaintext path.
for secret_path in 'secrets/unencrypted' 'secrets/unencrypted/*' \
  'SensitivePrivateSecrets' 'SensitivePrivateSecrets/*'; do
  require_fixed "$repo_common" "$secret_path" \
    "the ciphertext-only manifest policy must still refuse: ${secret_path}"
done

if ((failures > 0)); then
  echo "❌ deploy archive staging: ${failures} check(s) failed" >&2
  exit 1
fi

echo "✅ deploy archive staging namespace contract verified"