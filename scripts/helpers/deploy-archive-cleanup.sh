#!/usr/bin/env bash

# Private staging namespace for deployment archives on the build/target host.
#
# A successful upload can be orphaned when the SSH session drops before the
# executor's cleanup trap runs, so the archive's lifetime cannot depend on the
# uploading session alone. Archives are staged inside one dedicated directory
# whose contents are expired declaratively by systemd-tmpfiles (48h, longer
# than the 26h transaction lock lifetime) instead of by sweeping arbitrary
# temporary paths.
#
# Every removal path is constrained twice: the entry name must match the
# staging template, and its parent must resolve to the namespace itself. Names
# are unlinked, never followed, so a symlink planted inside the namespace cannot
# delete anything outside it. This helper adds no privilege of its own: it runs
# as the SSH user and only touches files that user could already remove.
#
# NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE overrides the namespace path so the
# regression suite can exercise this logic against temporary local directories.
# It is a test seam, not supported production configurability. Production uses
# exactly the dedicated sibling below, matching the single-value Nix option;
# never place archives below the root-only transaction/stamp directory.
# The remote deploy payload does not set an override.

deploy_archive_namespace_path() {
  printf '%s\n' "${NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE:-/var/lib/nixhomeserver-deploy-archives}"
}

# Print a usable namespace path, or explain why the namespace cannot be used.
# Fails closed: there is deliberately no fallback to a general temporary
# directory, because an unbounded fallback would reintroduce the orphan window
# this namespace exists to bound.
#
# Each condition is its own predicate for the same reason as the path layers:
# a composite check is only ever exercised through whichever of its conditions
# happens to fire first, so the rest can rot unnoticed.
deploy_archive_namespace_missing() {
  [[ ! -d "$1" ]]
}

deploy_archive_namespace_is_symlink() {
  [[ -L "$1" ]]
}

deploy_archive_namespace_is_group_or_world_accessible() {
  local mode
  mode="$(stat -c '%a' "$1")" || return 0
  (($((8#$mode)) & 077))
}

deploy_archive_namespace_is_unusable_by_caller() {
  [[ ! -w "$1" || ! -x "$1" ]]
}

deploy_archive_namespace_ready() {
  local namespace mode

  namespace="$(deploy_archive_namespace_path)"
  if deploy_archive_namespace_missing "$namespace"; then
    echo "blocked: deploy archive staging namespace is missing: $namespace" >&2
    echo "   Activate the server configuration that declares it, then retry." >&2
    return 1
  fi
  if deploy_archive_namespace_is_symlink "$namespace"; then
    echo "blocked: deploy archive staging namespace is a symlink: $namespace" >&2
    return 1
  fi
  mode="$(stat -c '%a' "$namespace")"
  if deploy_archive_namespace_is_group_or_world_accessible "$namespace"; then
    echo "blocked: deploy archive staging namespace is accessible beyond its owner: $namespace (mode $mode)" >&2
    echo "   Archives are deployment sources; the namespace must stay mode 0700." >&2
    return 1
  fi
  if deploy_archive_namespace_is_unusable_by_caller "$namespace"; then
    echo "blocked: deploy archive staging namespace is not writable by $(id -un): $namespace" >&2
    return 1
  fi
  printf '%s\n' "$namespace"
}

# Each containment layer below is a separate function on purpose. They are
# deliberately redundant - any one of them refuses an escaping path - but
# redundancy that cannot be tested one layer at a time is indistinguishable from
# dead code, so each is independently callable and independently asserted.

# Reject a non-absolute path, and one carrying a newline or space that could
# split one shell word into two or smuggle a second command.
deploy_archive_shape_is_rejected() {
  local path="$1" component

  if [[ -z "$path" || "$path" != /* ]]; then
    echo "blocked: refusing to touch a non-absolute deploy archive path" >&2
    return 0
  fi
  if [[ "$path" == *$'\n'* || "$path" == *" "* ]]; then
    echo "blocked: refusing to touch a deploy archive path containing whitespace" >&2
    return 0
  fi
  while IFS= read -r component; do
    case "$component" in
      ""|"."|"..")
        echo "blocked: refusing to touch a deploy archive path with traversal components: $path" >&2
        return 0
        ;;
    esac
  done < <(tr '/' '\n' <<<"${path#/}")
  return 1
}

# Reject any leaf name that is not exactly what `mktemp` in this namespace
# produces: `<label>.<8 random characters>.tar`. A caller therefore cannot
# append a suffix, choose a name, or reach a file it did not stage.
deploy_archive_entry_name_is_rejected() {
  local base="${1##*/}"

  if [[ "$base" == "$1" ]]; then
    echo "blocked: refusing to touch a deploy archive path outside the staging namespace: $1" >&2
    return 0
  fi
  if [[ ! "$base" =~ ^[A-Za-z][A-Za-z0-9-]*\.[A-Za-z0-9]{8}\.tar$ ]]; then
    echo "blocked: refusing to touch an unrecognised deploy archive name: $base" >&2
    return 0
  fi
  return 1
}

# Reject a path whose literal parent directory is not the namespace itself.
# This is the textual layer: it refuses any caller-chosen directory, including
# `..` sequences that would only resolve elsewhere.
deploy_archive_literal_parent_is_rejected() {
  local path="$1" namespace="$2"

  if [[ "$(dirname -- "$path")" != "$namespace" ]]; then
    echo "blocked: refusing to touch a deploy archive path outside the staging namespace: $path" >&2
    return 0
  fi
  return 1
}

# Reject a path whose parent resolves elsewhere after symlink evaluation. This
# is the indirection layer, and it is deliberately separate from the textual one
# so each can be exercised on its own.
deploy_archive_resolved_parent_is_rejected() {
  local path="$1" namespace="$2" parent

  parent="$(cd -P -- "$(dirname -- "$path")" 2>/dev/null && pwd -P)" || {
    echo "blocked: deploy archive staging namespace is unreadable: $namespace" >&2
    return 0
  }
  if [[ "$parent" != "$namespace" ]]; then
    echo "blocked: refusing to touch a deploy archive path that resolves outside the staging namespace: $path" >&2
    return 0
  fi
  return 1
}

# Accept only `<namespace>/<label>.XXXXXXXX.tar` with no traversal, no extra
# separator, and no caller-supplied directory. Prints the accepted path.
deploy_archive_path_accepted() {
  local path="$1" namespace

  if deploy_archive_shape_is_rejected "$path"; then
    return 1
  fi
  if deploy_archive_entry_name_is_rejected "$path"; then
    return 1
  fi

  namespace="$(deploy_archive_namespace_ready)" || return 1
  namespace="$(cd -P -- "$namespace" && pwd -P)"
  if deploy_archive_literal_parent_is_rejected "$path" "$namespace"; then
    return 1
  fi
  if deploy_archive_resolved_parent_is_rejected "$path" "$namespace"; then
    return 1
  fi

  printf '%s\n' "$path"
}

# Create a private archive file inside the namespace and print its path. The
# file is created with owner-only access before any content is written.
deploy_archive_stage() {
  local label="$1" namespace remote_archive

  if [[ ! "$label" =~ ^[A-Za-z][A-Za-z0-9-]*$ ]]; then
    echo "blocked: deploy archive label must be alphanumeric: $label" >&2
    return 1
  fi
  namespace="$(deploy_archive_namespace_ready)" || return 1
  if ! remote_archive="$(mktemp "${namespace}/${label}.XXXXXXXX.tar")"; then
    echo "blocked: could not create a deploy archive inside $namespace" >&2
    return 1
  fi
  chmod 0600 "$remote_archive"
  printf '%s\n' "$remote_archive"
}

# Remove a staged archive. Refuses anything outside the namespace, and unlinks
# rather than follows, so a planted symlink cannot redirect the deletion.
deploy_archive_remove() {
  local path="$1" accepted

  accepted="$(deploy_archive_path_accepted "$path")" || return 1
  rm -f -- "$accepted"
}

# Remove a staged archive on a remote host, using a freshly uploaded copy of
# this helper so the remote decision is made by the same constrained code. The
# helper is uploaded and removed through the ordinary channel; if it cannot be
# delivered the removal is skipped rather than falling back to an unvalidated
# `rm`, because leaving one archive behind is strictly better than deleting an
# attacker-chosen path.
remove_remote_archive() {
  local remote_host="$1" path="$2" helper_path="${deploy_archive_helper_path:-}"

  if [[ -z "$path" ]]; then
    return 0
  fi
  # Without the helper the removal is skipped rather than falling back to an
  # unvalidated `rm`: leaving one archive behind is strictly better than
  # deleting an attacker-chosen path, and the namespace expiry still reclaims
  # it. This function is defined in the helper itself, so when the helper is
  # run as a program it resolves its own path from BASH_SOURCE directly.
  if [[ -z "$helper_path" ]]; then
    helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  fi
  if [[ ! -r "$helper_path" ]]; then
    return 0
  fi
  # As with the staging call, the payload redirect must sit inside the command
  # substitution; attached to the assignment it would feed nothing to ssh.
  ssh -T "$remote_host" \
    "set -e; helper=\$(mktemp); trap 'rm -f \"\$helper\"' EXIT; cat >\"\$helper\"; chmod 0700 \"\$helper\"; bash \"\$helper\" remove $(printf '%q' "$path")" \
    <"$helper_path" >/dev/null 2>&1 || true
  return 0
}

deploy_archive_main() {
  local action="${1:-}" argument="${2:-}"

  case "$action" in
    stage)
      [[ -n "$argument" ]] || {
        echo "usage: deploy-archive-cleanup.sh stage <label>" >&2
        return 2
      }
      deploy_archive_stage "$argument"
      ;;
    remove)
      [[ -n "$argument" ]] || {
        echo "usage: deploy-archive-cleanup.sh remove <path>" >&2
        return 2
      }
      deploy_archive_remove "$argument"
      ;;
    namespace)
      deploy_archive_namespace_ready
      ;;
    *)
      echo "usage: deploy-archive-cleanup.sh {stage|remove|namespace} [argument]" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  deploy_archive_main "$@"
fi