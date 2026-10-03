#!/usr/bin/env bash

_repo_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The archive namespace contract is sourced rather than duplicated: the same
# functions decide on both ends what may be created and removed.
# shellcheck source=scripts/helpers/deploy-archive-cleanup.sh
source "$_repo_lib_dir/deploy-archive-cleanup.sh"

# Resolve the helper's own path here, at source time, where BASH_SOURCE is
# unambiguously this file. Recomputing it from inside a function is unreliable:
# BASH_SOURCE inside a function reports the *caller's* file, so the lookup would
# silently resolve against whatever sourced repo-common.sh.
deploy_archive_helper_path="$_repo_lib_dir/deploy-archive-cleanup.sh"

init_repo_root() {
  local override_var="${1:-}"
  local requested_root git_root

  if [[ -n "$override_var" && -n "${!override_var:-}" ]]; then
    requested_root="${!override_var}"
  else
    requested_root="${_repo_lib_dir}/../.."
  fi

  if ! repo_root="$(cd "$requested_root" && pwd -P)"; then
    echo "❌ Repository root does not exist or is not accessible: $requested_root" >&2
    return 1
  fi

  # Nix expressions consume these through builtins.getEnv so repository paths
  # are never interpolated as Nix syntax. A live checkout uses Git filtering to
  # exclude ignored build trees; deployment archives have no .git directory and
  # are already manifest-filtered, so they deliberately use a path flake.
  export NIXHOMESERVER_REPO_ROOT_FOR_EVAL="$repo_root"
  git_root=""
  if command -v git >/dev/null 2>&1; then
    git_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [[ -n "$git_root" ]] && [[ "$(cd "$git_root" && pwd -P)" == "$repo_root" ]]; then
    export NIXHOMESERVER_FLAKE_REF_FOR_EVAL="git+file://$repo_root"
  else
    export NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$repo_root"
  fi
}

cd_repo_root() {
  cd "$repo_root" || exit
}

ensure_default_nix_config() {
  export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes
accept-flake-config = true}"
}

need() {
  local tool
  for tool in "$@"; do
    if [[ "$tool" == */* ]]; then
      if [[ ! -x "$tool" ]]; then
        echo "❌ Missing required tool: $tool" >&2
        exit 1
      fi
      continue
    fi

    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

nix_uses_substituter() {
  local expected="$1"
  local substituters

  substituters="$(nix config show substituters 2>/dev/null)" || return 1
  [[ " $substituters " == *" $expected "* ]]
}

# $4 selects the failure contract: "required" (default) keeps the fail-closed
# behaviour callers such as repository validation depend on, "optional" only
# downgrades the diagnosis to a warning for best-effort preflight callers.
ensure_local_attic_tunnel() {
  local health_endpoint="$1"
  local tunnel_script="$2"
  local log_file="$3"
  local requirement="${4:-required}"
  local prefix="blocked"
  # The persistent tunnel retries SSH after a 15-second backoff. Allow one
  # complete retry window so a transient disconnect cannot race a rebuild.
  local wait_attempts="${NIXHOMESERVER_ATTIC_WAIT_ATTEMPTS:-40}"
  local wait_delay="${NIXHOMESERVER_ATTIC_WAIT_DELAY:-0.5}"
  local attempt

  if [[ "$requirement" != "required" && "$requirement" != "optional" ]]; then
    echo "blocked: Attic tunnel requirement must be required or optional" >&2
    return 1
  fi
  if [[ "$requirement" == "optional" ]]; then
    prefix="warning"
  fi

  if curl --fail --silent --show-error --max-time 2 \
    --output /dev/null "$health_endpoint"; then
    return 0
  fi

  if [[ ! -x "$tunnel_script" ]]; then
    echo "$prefix: local Attic cache is configured but its tunnel is unavailable" >&2
    echo "   Missing executable tunnel helper: $tunnel_script" >&2
    return 1
  fi

  mkdir -p "$(dirname "$log_file")"
  echo "local Attic cache is unavailable; starting its SSH tunnel"
  nohup "$tunnel_script" >>"$log_file" 2>&1 </dev/null &

  for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
    sleep "$wait_delay"
    if curl --fail --silent --show-error --max-time 2 \
      --output /dev/null "$health_endpoint"; then
      echo "local Attic cache tunnel is ready"
      return 0
    fi
  done

  echo "$prefix: local Attic cache tunnel did not become ready at $health_endpoint" >&2
  echo "   Inspect: $log_file" >&2
  return 1
}

# Decide whether this deploy needs the workstation's loopback Attic cache at
# all. Only a workstation build consumes the cache through the local
# substituter, so the resolved allocation - not the requested mode name -
# decides. Recovery itself is best effort: an unreachable cache costs build
# throughput, never correctness, because Nix keeps its public caches. Callers
# run this after the allocation is resolved and before staging and building.
local_attic_cache_recovery_needed() {
  local build_locally="$1"
  local cache_url="$2"

  [[ "$build_locally" == "true" ]] || return 1
  nix_uses_substituter "$cache_url" || return 1
  return 0
}

recover_local_attic_tunnel_if_needed() {
  local build_locally="$1"
  local cache_url="$2"
  local tunnel_script="$3"
  local log_file="$4"

  [[ "${DEPLOY_DRY_RUN:-}" != "1" ]] || return 0

  if ! local_attic_cache_recovery_needed "$build_locally" "$cache_url"; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1 || ! command -v nohup >/dev/null 2>&1; then
    echo "warning: local Attic cache tunnel needs curl and nohup; continuing with the public caches" >&2
    return 0
  fi

  # Never fatal: without this cache the deploy simply builds from the official
  # and community caches.
  if ! ensure_local_attic_tunnel \
    "$cache_url/nix-cache-info" \
    "$tunnel_script" \
    "$log_file" \
    optional; then
    echo "warning: continuing without the local Attic cache; Nix falls back to the official and community caches" >&2
    return 0
  fi
  return 0
}

nix_cache_hash() {
  local payload="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha256sum | awk '{ print $1 }'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 256 | awk '{ print $1 }'
    return 0
  fi

  return 1
}

# Hash the repository file set (tracked plus untracked, excluding gitignored
# paths) so persistent caches can key on content instead of location: a path-
# only key would keep serving results from an older revision. Prints nothing
# and returns non-zero when Git cannot enumerate the worktree, letting callers
# fall back to a run-scoped cache instead of a stale shared one.
repo_content_hash() {
  local digest empty_digest="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  if ! command -v git >/dev/null 2>&1 ||
    ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 1
  fi
  # Validate enumeration on its own: a swallowed Git failure would otherwise
  # look like the digest of an empty file set and poison the cache key.
  git -C "$repo_root" ls-files -z --cached --others --exclude-standard \
    >/dev/null 2>&1 || return 1

  # sha256sum keeps hashing remaining paths but exits non-zero when a file was
  # deleted mid-enumeration; disable pipefail inside this subshell only, so a
  # partial worktree cannot abort callers running under `set -euo pipefail`.
  digest="$(
    set +o pipefail
    git -C "$repo_root" ls-files -z --cached --others --exclude-standard 2>/dev/null |
      xargs -0 -r sha256sum 2>/dev/null |
      sha256sum 2>/dev/null |
      awk '{ print $1 }'
  )" || digest=""

  [[ -n "$digest" && "$digest" != "$empty_digest" ]] || return 1
  printf '%s\n' "$digest"
}

plaintext_staging_is_empty() {
  local staging_dir="$1"
  local first_entry

  [[ ! -d "$staging_dir" ]] && return 0
  if ! first_entry="$(find "$staging_dir" -mindepth 1 -print -quit)"; then
    return 1
  fi
  [[ -z "$first_entry" ]]
}

create_deploy_repo_archive() {
  local archive_path="$1"
  local manifest git_manifest untracked_manifest refused_path tar_status

  if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    manifest="$(mktemp /tmp/deploy-repo-manifest.XXXXXX)"
    git_manifest="$(mktemp /tmp/deploy-git-manifest.XXXXXX)"
    untracked_manifest="$(mktemp /tmp/deploy-untracked-manifest.XXXXXX)"

    if ! git -C "$repo_root" ls-files -z --others --exclude-standard >"$untracked_manifest"; then
      rm -f "$manifest" "$git_manifest" "$untracked_manifest"
      return 1
    fi
    if [[ -s "$untracked_manifest" ]]; then
      echo "❌ Refusing to deploy with untracked, non-ignored files." >&2
      echo "   Review and stage intended files with 'git add', or ignore local-only files:" >&2
      while IFS= read -r -d '' path; do
        printf '   %s\n' "$path" >&2
      done <"$untracked_manifest"
      rm -f "$manifest" "$git_manifest" "$untracked_manifest"
      return 1
    fi
    rm -f "$untracked_manifest"

    if ! git -C "$repo_root" ls-files -z --cached --modified --deduplicate >"$git_manifest"; then
      rm -f "$manifest" "$git_manifest"
      return 1
    fi
    refused_path=""
    if ! while IFS= read -r -d '' path; do
      case "$path" in
        secrets/unencrypted|secrets/unencrypted/*|SensitivePrivateSecrets|SensitivePrivateSecrets/*)
          echo "❌ Refusing to archive tracked plaintext secret path: $path" >&2
          refused_path="$path"
          break
          ;;
      esac
      if [[ -f "$repo_root/$path" || -L "$repo_root/$path" ]]; then
        printf '%s\0' "$path"
      fi
    done <"$git_manifest" >"$manifest"; then
      rm -f "$manifest" "$git_manifest"
      return 1
    fi
    if [[ -n "$refused_path" ]]; then
      rm -f "$manifest" "$git_manifest"
      return 1
    fi
    rm -f "$git_manifest"

    if tar -C "$repo_root" --null -T "$manifest" -cf "$archive_path"; then
      tar_status=0
    else
      tar_status=$?
    fi
    rm -f "$manifest"
    return "$tar_status"
  fi

  # Deploy source must come from Git's explicit tracked-file manifest. A broad
  # directory tar from a copied/ZIP checkout can silently include ignored
  # plaintext secrets, node_modules, caches, and other host-local state; Nix
  # would then import those files into the build host store. The already staged
  # remote archive never calls this helper, so failing closed here does not
  # interfere with executor-side path-flake evaluation.
  echo "❌ Refusing to create a deployment archive outside a Git worktree." >&2
  echo "   Clone the repository with Git, review/stage intended files, and retry." >&2
  return 1
}

stage_archive_on_remote() {
  local archive_path="$1"
  local remote_host="$2"
  local archive_label="$3"
  local helper_path="$deploy_archive_helper_path"
  local remote_archive

  if [[ ! -r "$helper_path" ]]; then
    echo "blocked: deploy archive staging helper is missing: $helper_path" >&2
    return 1
  fi

  # The namespace contract lives in a standalone helper so the same code decides
  # on both ends what may be created and removed. Upload it through the
  # ordinary SSH channel first, then use it on the remote host to claim a slot.
  # If any step fails, everything this function created is removed through the
  # same constrained path rather than an unvalidated one.
  # The helper payload redirect belongs *inside* the command substitution.
  # As `x="$(ssh ...)" <file` it attaches to the assignment statement instead,
  # and the substitution's ssh receives an empty stdin.
  remote_archive="$(ssh -T "$remote_host" \
    "set -e; helper=\$(mktemp); trap 'rm -f \"\$helper\"' EXIT; cat >\"\$helper\"; chmod 0700 \"\$helper\"; bash \"\$helper\" stage $(printf '%q' "$archive_label")" \
    <"$helper_path")" || return 1

  # The helper prints exactly one absolute path; a remote diagnostic on stdout,
  # a wrapped error, or a blank line is not a usable archive path.
  if [[ ! "$remote_archive" == /* ]] || [[ "$remote_archive" == *$'\n'* ]]; then
    echo "blocked: remote deploy archive staging did not return a usable path" >&2
    return 1
  fi

  if ! ssh -T "$remote_host" "cat > $(printf '%q' "$remote_archive")" \
      <"$archive_path"; then
    remove_remote_archive "$remote_host" "$remote_archive"
    return 1
  fi
  printf '%s\n' "$remote_archive"
}

# Callers own the cache directory's lifetime and keying: a directory that
# outlives one invocation must be keyed by repository content (see
# repo_content_hash) so fixture/config mutations or source edits cannot reuse
# stale results. Coalesce concurrent identical requests.
nix_eval_with_optional_cache() (
  local eval_output_mode="$1" expr="$2" cache_dir="${REPO_NIX_EVAL_CACHE_DIR:-}"
  local cache_key cache_file tmp_file lock_fd environment_hash
  if [[ -n "$cache_dir" ]]; then
    environment_hash="$(env -0 | LC_ALL=C sort -z | sha256sum)" || return
    cache_key="$(nix_cache_hash "${eval_output_mode}"$'\n'"${repo_root}"$'\n'"${NIXHOMESERVER_FLAKE_REF_FOR_EVAL:-}"$'\n'"${NIXHOMESERVER_REPO_ROOT_FOR_EVAL:-}"$'\n'"${environment_hash}"$'\n'"${expr}")" || cache_key=""
    if [[ -n "$cache_key" ]]; then
      mkdir -p "$cache_dir" || return
      cache_file="${cache_dir}/${cache_key}.${eval_output_mode}"
      exec {lock_fd}>"${cache_file}.lock"
      flock "$lock_fd" || return
      if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return
      fi
      tmp_file="$(mktemp "${cache_file}.tmp.XXXXXX")" || return
      trap 'rm -f "$tmp_file"' EXIT
      nix eval "--${eval_output_mode}" --impure --expr "$expr" >"$tmp_file" || return
      mv "$tmp_file" "$cache_file" || return
      cat "$cache_file"
      return
    fi
  fi
  nix eval "--${eval_output_mode}" --impure --expr "$expr"
)

nix_json() {
  local expr="$1"
  nix_eval_with_optional_cache json "
    let
      repoPath = builtins.getEnv \"NIXHOMESERVER_REPO_ROOT_FOR_EVAL\";
      flake = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      lib = flake.inputs.nixpkgs.lib;
      vars = import (builtins.toPath (repoPath + \"/vars.nix\")) { inherit lib; };
      cfg = (builtins.getAttr vars.hostname flake.nixosConfigurations).config;
    in
      ${expr}
  "
}

nix_flake_var() {
  local expr="$1"
  nix_eval_with_optional_cache raw "
    let
      repoPath = builtins.getEnv \"NIXHOMESERVER_REPO_ROOT_FOR_EVAL\";
      flake = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      lib = flake.inputs.nixpkgs.lib;
      vars = import (builtins.toPath (repoPath + \"/vars.nix\")) { inherit lib; };
    in
      ${expr}
  "
}

nix_flake_json() {
  local expr="$1"
  nix_eval_with_optional_cache json "
    let
      repoPath = builtins.getEnv \"NIXHOMESERVER_REPO_ROOT_FOR_EVAL\";
      flake = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      lib = flake.inputs.nixpkgs.lib;
      vars = import (builtins.toPath (repoPath + \"/vars.nix\")) { inherit lib; };
    in
      ${expr}
  "
}
