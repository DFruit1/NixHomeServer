#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../helpers/repo-common.sh"
init_repo_root NIXHOMESERVER_REPO_ROOT
cd_repo_root

usage() {
  cat <<'EOF'
Usage: scripts/admin/seed-install-repository.sh --target <new-directory>

Create a fresh installation checkout at <new-directory>. The target must not
already exist. Only Git-tracked current worktree contents are copied; ignored
plaintext staging and untracked, non-ignored files cause a refusal. Git metadata
is preserved so the installed repository remains a usable checkout.
EOF
}

target_input=""
while (($# > 0)); do
  case "$1" in
    --target)
      [[ $# -ge 2 && -n "${2:-}" ]] || {
        echo "blocked: --target requires a new directory path" >&2
        exit 1
      }
      target_input="${2:-}"
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

[[ -n "$target_input" ]] || {
  usage >&2
  exit 1
}

need basename chmod chown cmp cp dirname find git mktemp mv readlink rm tar

target_parent_input="$(dirname -- "$target_input")"
target_name="$(basename -- "$target_input")"
if [[ "$target_name" == "." || "$target_name" == ".." || -z "$target_name" ]]; then
  echo "blocked: --target must name a new directory, not its parent" >&2
  exit 1
fi
if ! target_parent="$(cd "$target_parent_input" 2>/dev/null && pwd -P)"; then
  echo "blocked: target parent does not exist or is not accessible: $target_parent_input" >&2
  exit 1
fi
target_path="${target_parent%/}/${target_name}"

if [[ -e "$target_path" || -L "$target_path" ]]; then
  echo "blocked: target already exists; refusing to merge or overwrite it: $target_path" >&2
  exit 1
fi
case "$target_path" in
  "$repo_root"|"$repo_root"/*)
    echo "blocked: installation target must be outside the source checkout" >&2
    exit 1
    ;;
esac

git_source=(git -c "safe.directory=$repo_root" -C "$repo_root")
if ! source_top="$("${git_source[@]}" rev-parse --show-toplevel 2>/dev/null)" \
  || [[ "$(cd "$source_top" && pwd -P)" != "$repo_root" ]]; then
  echo "blocked: source must be the top level of a Git checkout: $repo_root" >&2
  exit 1
fi
if ! git_dir="$("${git_source[@]}" rev-parse --absolute-git-dir 2>/dev/null)" \
  || [[ "$git_dir" != "$repo_root/.git" ]] \
  || [[ ! -d "$git_dir" ]] \
  || [[ -L "$git_dir" ]]; then
  echo "blocked: source must use a self-contained .git directory (linked worktrees are not supported)" >&2
  exit 1
fi
if [[ -n "$(find "$git_dir" -type f -name '*.lock' -print -quit)" ]]; then
  echo "blocked: Git metadata contains a lock file; wait for the active Git operation to finish" >&2
  exit 1
fi

refuse_plaintext_path() {
  local path="$1"
  local label="$2"

  if [[ -L "$path" || (-e "$path" && ! -d "$path") ]]; then
    echo "blocked: refusing non-directory plaintext staging path: $label" >&2
    return 1
  fi
  if [[ -d "$path" ]] && ! plaintext_staging_is_empty "$path"; then
    echo "blocked: remove all plaintext staging content before installation: $label" >&2
    return 1
  fi
}

refuse_plaintext_path "$repo_root/secrets/unencrypted" "secrets/unencrypted"
refuse_plaintext_path "$repo_root/SensitivePrivateSecrets" "SensitivePrivateSecrets"

work_dir="$(mktemp -d /tmp/nixhomeserver-install-seed.XXXXXX)"
staging_path=""
cleanup() {
  if [[ -n "$staging_path" \
    && "$staging_path" == "$target_parent/.${target_name}.seed."* \
    && -d "$staging_path" \
    && ! -L "$staging_path" ]]; then
    rm -rf -- "$staging_path"
  fi
  if [[ "$work_dir" == /tmp/nixhomeserver-install-seed.* \
    && -d "$work_dir" \
    && ! -L "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

untracked_manifest="$work_dir/untracked"
if ! "${git_source[@]}" ls-files -z --others --exclude-standard >"$untracked_manifest"; then
  echo "blocked: could not enumerate untracked source files" >&2
  exit 1
fi
if [[ -s "$untracked_manifest" ]]; then
  echo "blocked: refusing installation with untracked, non-ignored files:" >&2
  while IFS= read -r -d '' path; do
    printf '  %q\n' "$path" >&2
  done <"$untracked_manifest"
  exit 1
fi

git_manifest="$work_dir/git-files"
copy_manifest="$work_dir/current-files"
: >"$copy_manifest"
if ! "${git_source[@]}" ls-files -z --cached --modified --deduplicate >"$git_manifest"; then
  echo "blocked: could not enumerate tracked source files" >&2
  exit 1
fi
while IFS= read -r -d '' path; do
  case "$path" in
    secrets/unencrypted|secrets/unencrypted/*|SensitivePrivateSecrets|SensitivePrivateSecrets/*)
      echo "blocked: refusing tracked plaintext staging path: $path" >&2
      exit 1
      ;;
  esac

  source_path="$repo_root/$path"
  if [[ -f "$source_path" || -L "$source_path" ]]; then
    printf '%s\0' "$path" >>"$copy_manifest"
  elif [[ -e "$source_path" ]]; then
    echo "blocked: tracked path is not a regular file or symlink: $path" >&2
    exit 1
  fi
done <"$git_manifest"

archive_path="$work_dir/current-files.tar"
tar \
  --create \
  --file="$archive_path" \
  --directory="$repo_root" \
  --null \
  --verbatim-files-from \
  --files-from="$copy_manifest"

staging_path="$(mktemp -d "$target_parent/.${target_name}.seed.XXXXXX")"
cp -a -- "$git_dir" "$staging_path/.git"
tar --extract --file="$archive_path" --directory="$staging_path"
chmod --reference="$repo_root" "$staging_path"
if [[ "$EUID" -eq 0 ]]; then
  chown --reference="$repo_root" "$staging_path"
fi

git_staging=(git -c "safe.directory=$staging_path" -C "$staging_path")
if ! staging_top="$("${git_staging[@]}" rev-parse --show-toplevel 2>/dev/null)" \
  || [[ "$(cd "$staging_top" && pwd -P)" != "$staging_path" ]]; then
  echo "blocked: staged installation is not a self-contained Git checkout" >&2
  exit 1
fi
if [[ "$("${git_source[@]}" rev-parse HEAD)" != "$("${git_staging[@]}" rev-parse HEAD)" ]]; then
  echo "blocked: staged installation HEAD differs from the source checkout" >&2
  exit 1
fi

"${git_source[@]}" status --porcelain=v1 -z --untracked-files=no >"$work_dir/source-status"
"${git_staging[@]}" status --porcelain=v1 -z --untracked-files=no >"$work_dir/staging-status"
if ! cmp -s "$work_dir/source-status" "$work_dir/staging-status"; then
  echo "blocked: staged installation does not preserve the source tracked-file state" >&2
  exit 1
fi
if [[ -n "$("${git_staging[@]}" ls-files --others --exclude-standard)" ]]; then
  echo "blocked: staged installation unexpectedly contains untracked files" >&2
  exit 1
fi

while IFS= read -r -d '' path; do
  source_path="$repo_root/$path"
  staged_file="$staging_path/$path"
  if [[ -L "$source_path" ]]; then
    if [[ ! -L "$staged_file" ]] \
      || [[ "$(readlink -- "$source_path")" != "$(readlink -- "$staged_file")" ]]; then
      echo "blocked: staged symlink differs from source: $path" >&2
      exit 1
    fi
  elif [[ -f "$source_path" ]]; then
    if [[ ! -f "$staged_file" || -L "$staged_file" ]] \
      || ! cmp -s -- "$source_path" "$staged_file"; then
      echo "blocked: staged file differs from source: $path" >&2
      exit 1
    fi
  elif [[ -e "$staged_file" || -L "$staged_file" ]]; then
    echo "blocked: deleted tracked path reappeared while staging: $path" >&2
    exit 1
  fi
done <"$git_manifest"

if [[ -e "$target_path" || -L "$target_path" ]]; then
  echo "blocked: target appeared while staging; refusing to overwrite it: $target_path" >&2
  exit 1
fi
mv -T -- "$staging_path" "$target_path"
staging_path=""

echo "Seeded controlled installation checkout: $target_path"
