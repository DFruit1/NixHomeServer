#!/usr/bin/env bash

_repo_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

  tar -C "$repo_root" \
    --exclude=.git \
    --exclude='./result' \
    --exclude='./result-*' \
    --exclude='./.cache' \
    --exclude='./secrets/unencrypted' \
    --exclude='./SensitivePrivateSecrets' \
    --exclude='./custom_apps/rust/apps/mail-archive-ui/target' \
    -cf "$archive_path" .
}

stage_archive_on_remote() {
  local archive_path="$1"
  local remote_host="$2"
  local archive_label="$3"
  local remote_archive

  remote_archive="$(ssh "$remote_host" "mktemp /tmp/${archive_label}.XXXXXX.tar")"
  if ! ssh "$remote_host" "cat > $(printf '%q' "$remote_archive")" <"$archive_path"; then
    ssh "$remote_host" "rm -f $(printf '%q' "$remote_archive")" || true
    return 1
  fi
  printf '%s\n' "$remote_archive"
}

nix_eval_with_optional_cache() {
  local mode="$1"
  local expr="$2"
  local cache_dir="${REPO_NIX_EVAL_CACHE_DIR:-}"

  if [[ -n "$cache_dir" ]]; then
    local cache_key cache_file tmp_file
    cache_key="$(nix_cache_hash "${mode}"$'\n'"${repo_root}"$'\n'"${expr}")" || cache_key=""
    if [[ -n "$cache_key" ]]; then
      mkdir -p "$cache_dir"
      cache_file="${cache_dir}/${cache_key}.${mode}"
      if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
      fi

      tmp_file="${cache_file}.tmp.$$"
      if [[ "$mode" == "raw" ]]; then
        nix eval --raw --impure --expr "$expr" >"$tmp_file"
      else
        nix eval --json --impure --expr "$expr" >"$tmp_file"
      fi
      mv "$tmp_file" "$cache_file"
      cat "$cache_file"
      return 0
    fi
  fi

  if [[ "$mode" == "raw" ]]; then
    nix eval --raw --impure --expr "$expr"
  else
    nix eval --json --impure --expr "$expr"
  fi
}

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
