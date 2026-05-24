#!/usr/bin/env bash

_repo_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

init_repo_root() {
  local override_var="${1:-}"

  if [[ -n "$override_var" && -n "${!override_var:-}" ]]; then
    repo_root="${!override_var}"
  else
    repo_root="$(cd "${_repo_lib_dir}/../.." && pwd)"
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

sha256_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print $1 }'
    return 0
  fi

  return 1
}

create_deploy_repo_archive() {
  local archive_path="$1"
  local manifest tar_status

  if command -v git >/dev/null 2>&1 && git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    manifest="$(mktemp /tmp/deploy-repo-manifest.XXXXXX)"

    while IFS= read -r -d '' path; do
      if [[ -f "$repo_root/$path" || -L "$repo_root/$path" ]]; then
        printf '%s\0' "$path"
      fi
    done < <(
      git -C "$repo_root" ls-files -z --cached --modified --others --exclude-standard
    ) >"$manifest"

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
    --exclude='./custom_apps/rust/apps/kanidm-admin/target' \
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

hash_deploy_repo_archive() {
  local archive_path archive_status

  archive_path="$(mktemp /tmp/deploy-validation-archive.XXXXXX.tar)"

  if create_deploy_repo_archive "$archive_path"; then
    if sha256_file "$archive_path"; then
      archive_status=0
    else
      archive_status=$?
    fi
  else
    archive_status=$?
  fi

  rm -f "$archive_path"
  return "$archive_status"
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
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
      cfg = (builtins.getAttr vars.hostname flake.nixosConfigurations).config;
    in
      ${expr}
  "
}

nix_flake_var() {
  local expr="$1"
  nix_eval_with_optional_cache raw "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
    in
      ${expr}
  "
}
