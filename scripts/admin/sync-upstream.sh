#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../helpers/repo-common.sh"
init_repo_root NIXHOMESERVER_REPO_ROOT

# secrets-common resolves every path from $repo_root, so it is sourced only
# after the repository root has been resolved above.
source "$script_dir/../helpers/secrets-common.sh"
cd_repo_root
ensure_default_nix_config

# An AI-driven sync must fail fast instead of hanging on credential prompts.
export GIT_TERMINAL_PROMPT=0

usage() {
  cat <<'EOF'
Usage: scripts/admin/sync-upstream.sh --upstream <remote-or-url> [--branch <name>] [--identity <age-key>] [--push]

Merge updates from the upstream NixHomeServer repository while preserving this
installation's own configuration files.

Instance-owned files (vars.nix, hardware-configuration.nix, secrets/*.age, and
secrets/pubkeys/age.pub) keep their current contents through every automatic
merge. Upstream changes to those paths are reported so they can be ported
manually. flake.lock follows upstream. Every other path follows the normal Git
merge rules, so an unexpected conflict in repository code is refused instead of
silently resolved.

The worktree must be clean before syncing: commit instance files to this
installation's fork first (ignored files such as secrets/unencrypted/ are
allowed). The upstream branch is merged with --no-ff and is never rebased.
Upstream additions of vars*/hardware-configuration*/secrets/pubkeys/* paths,
new root-level .nix files, and flake.lock deletions are refused as manual
migrations, so an upstream rename of an instance file can never silently
divert this installation to upstream settings.

With --push, a successful sync is pushed to origin so the private fork stays
authoritative. Pushing is refused when origin is the upstream repository
itself; a failed push is reported but does not fail the sync.

A private age identity is required whenever the merge touches secrets/*.age or
secrets/pubkeys/age.pub, so ciphertext that this installation cannot decrypt is
detected and regenerated instead of deployed. The helper accepts --identity, or
uses NIXHOMESERVER_AGE_IDENTITY_FILE, /persist/etc/agenix/age.key when readable,
or copies that installed key through passwordless sudo into a private temporary
directory.

After a successful sync, deploy the result:

  ./scripts/deploy.sh --action test
  ./scripts/deploy.sh --action switch

Set NIXHOMESERVER_SYNC_SKIP_EVAL=1 to skip the post-merge configuration preview
gate; this is reserved for regression tests that run without a flake.
EOF
}

blocked() {
  echo "blocked: $*" >&2
  exit 1
}

upstream_input=""
branch_input=""
identity_input=""
push_after_sync=false
while (($# > 0)); do
  case "$1" in
    --upstream)
      [[ $# -ge 2 && -n "${2:-}" ]] || blocked "--upstream requires a remote name or URL"
      upstream_input="${2:-}"
      shift 2
      ;;
    --branch)
      [[ $# -ge 2 && -n "${2:-}" ]] || blocked "--branch requires a branch name"
      branch_input="${2:-}"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 && -n "${2:-}" ]] || blocked "--identity requires a private age key path"
      identity_input="${2:-}"
      shift 2
      ;;
    --push)
      push_after_sync=true
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

[[ -n "$upstream_input" ]] || { usage >&2; exit 1; }

need git mktemp cmp tr
need jq nix

merge_in_progress=0
identity_tmpdir=""
merge_log=""

cleanup_sync() {
  local exit_status=$?
  trap - EXIT
  if ((merge_in_progress == 1)) \
    && git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    echo "⚠️ Upstream sync did not complete; aborting the in-progress merge." >&2
    git merge --abort >/dev/null 2>&1 || true
  fi
  if [[ -n "$identity_tmpdir" && -d "$identity_tmpdir" && ! -L "$identity_tmpdir" ]]; then
    rm -rf -- "$identity_tmpdir"
  fi
  if [[ -n "$merge_log" && -f "$merge_log" ]]; then
    rm -f -- "$merge_log"
  fi
  exit "$exit_status"
}
trap cleanup_sync EXIT
trap 'exit 130' HUP INT TERM

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  blocked "$repo_root is not a Git checkout"
fi
git_top="$(git rev-parse --show-toplevel)"
if [[ "$(cd "$git_top" && pwd -P)" != "$repo_root" ]]; then
  blocked "the sync helper must run against the checkout root: $repo_root"
fi
git_dir="$(git rev-parse --absolute-git-dir)"
if [[ "$git_dir" != "$repo_root/.git" || ! -d "$git_dir" || -L "$git_dir" ]]; then
  blocked "this checkout must use a self-contained .git directory (linked worktrees are not supported)"
fi
if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
  blocked "HEAD is detached; check out this installation's integration branch first"
fi
for state_file in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD; do
  if [[ -e "$git_dir/$state_file" ]]; then
    blocked "a Git operation is already in progress ($state_file); finish or abort it first"
  fi
done

if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "blocked: the repository worktree is not clean; sync merges require a committed tree" >&2
  echo "   Commit this installation's changes to its fork first (ignored files such as" >&2
  echo "   secrets/unencrypted/ are allowed):" >&2
  git status --short >&2
  exit 1
fi

if [[ -z "$(git config --get user.name || true)" ]] \
  || [[ -z "$(git config --get user.email || true)" ]]; then
  blocked "repository-local Git author identity is incomplete; set user.name and user.email"
fi

# Resolve the upstream remote: an existing remote name or a URL to configure
# under the canonical "upstream" remote name.
if git remote get-url "$upstream_input" >/dev/null 2>&1; then
  upstream_remote="$upstream_input"
else
  case "$upstream_input" in
    */*|*:*)
      upstream_remote="upstream"
      existing_url="$(git remote get-url "$upstream_remote" 2>/dev/null || true)"
      if [[ -n "$existing_url" ]]; then
        if [[ "$existing_url" != "$upstream_input" ]]; then
          blocked "remote $upstream_remote already points to $existing_url; refusing to repoint it to $upstream_input"
        fi
      else
        git remote add "$upstream_remote" "$upstream_input"
      fi
      ;;
    *)
      blocked "$upstream_input is not a configured Git remote and not a URL"
      ;;
  esac
fi
upstream_url="$(git remote get-url "$upstream_remote")"
if [[ "$push_after_sync" == "true" ]]; then
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$origin_url" && "$origin_url" == "$upstream_url" ]]; then
    blocked "--push would publish this installation's private files to the upstream
   repository (origin and upstream resolve to the same URL). Configure a private
   fork as origin first, then rerun the sync with --push."
  fi
fi
if [[ "$upstream_remote" == "origin" ]] \
  && [[ "$upstream_url" == "$(git remote get-url origin 2>/dev/null || true)" ]]; then
  echo "note: upstream resolves to origin; merging this installation's own fork applies no external update" >&2
fi

# merge=ours is belt-and-braces for plain pulls and merges made outside this
# helper; the helper restores protected contents from the pre-merge revision
# regardless of whether the attribute is present yet.
git config merge.ours.driver true

if [[ "$(git check-attr merge -- vars.nix 2>/dev/null)" != *": merge: ours" ]]; then
  echo "note: vars.nix is not marked merge=ours in this checkout yet; this sync still" >&2
  echo "      protects it, and the attribute takes effect after this merge" >&2
fi

is_protected_path() {
  case "$1" in
    vars.nix|hardware-configuration.nix|secrets/*.age|secrets/pubkeys/age.pub) return 0 ;;
    *) return 1 ;;
  esac
}

collect_protected_paths() {
  local rev="$1" path
  git ls-tree -r --name-only "$rev" | while IFS= read -r path; do
    if is_protected_path "$path"; then
      printf '%s\n' "$path"
    fi
  done || true
  if [[ -f .gitattributes ]]; then
    git ls-tree -r --name-only -z "$rev" \
      | git check-attr --stdin -z merge \
      | {
          while IFS= read -r -d '' attr_path \
            && IFS= read -r -d '' attr_name \
            && IFS= read -r -d '' attr_value; do
            if [[ "$attr_name" == "merge" && "$attr_value" == "ours" ]]; then
              printf '%s\n' "$attr_path"
            fi
          done
          true
        }
  fi
}

pre_head="$(git rev-parse HEAD)"
protected_list="$(
  collect_protected_paths "$pre_head" | sort -u
)"

if [[ -z "$branch_input" ]]; then
  branch_input="$(
    git ls-remote --symref "$upstream_remote" HEAD \
      | sed -n 's/^ref:[[:space:]]\+refs\/heads\/\([^[:space:]]*\).*/\1/p' \
      | head -n 1
  )"
fi
[[ -n "$branch_input" ]] || blocked "could not detect the upstream default branch; pass --branch <name>"

echo "Fetching upstream $upstream_url branch $branch_input"
git fetch --no-tags "$upstream_remote" "$branch_input"
if git rev-parse --verify -q "refs/remotes/$upstream_remote/$branch_input" >/dev/null 2>&1; then
  upstream_ref="refs/remotes/$upstream_remote/$branch_input"
elif git rev-parse --verify -q FETCH_HEAD >/dev/null 2>&1; then
  upstream_ref="FETCH_HEAD"
else
  blocked "upstream branch $branch_input could not be resolved after fetching"
fi

incoming_commits="$(git rev-list --count "$pre_head..$upstream_ref")"
if ((incoming_commits == 0)); then
  echo "✅ Already up to date with $upstream_remote/$branch_input; nothing to merge."
  exit 0
fi

if ! merge_base="$(git merge-base "$pre_head" "$upstream_ref" 2>/dev/null)"; then
  blocked "upstream has no common history with this checkout; reconcile manually"
fi

# Instance-file topology guard. A rename of an instance file upstream would
# arrive as a delete plus an addition: the local contents would be kept under
# the old name while the merged tree starts importing the new path, silently
# bypassing this installation's settings. Refuse those shapes before merging
# so the change is ported deliberately.
mapfile -d '' -t upstream_added_paths < <(
  git diff --name-only -z --diff-filter=A "$merge_base" "$upstream_ref"
)
mapfile -d '' -t upstream_deleted_lock_paths < <(
  git diff --name-only -z --diff-filter=D "$merge_base" "$upstream_ref" -- 'flake.lock'
)
instance_topology_blockers=("${upstream_deleted_lock_paths[@]}")
for added_path in "${upstream_added_paths[@]}"; do
  case "$added_path" in
    vars*|hardware-configuration*|secrets/pubkeys/*)
      instance_topology_blockers+=("$added_path")
      ;;
    *)
      if [[ "$added_path" != */* && "$added_path" == *.nix ]]; then
        instance_topology_blockers+=("$added_path")
      fi
      ;;
  esac
done
if (( ${#instance_topology_blockers[@]} > 0 )); then
  echo "blocked: upstream adds, renames, or removes instance-critical path(s) that cannot be merged automatically:" >&2
  printf '   %s\n' "${instance_topology_blockers[@]}" >&2
  echo "   Nothing was merged. Renames of vars.nix, hardware-configuration.nix, flake.lock," >&2
  echo "   or secrets/pubkeys/*, and new root-level .nix files, are manual migrations:" >&2
  echo "   inspect the upstream revision, port what is needed into this checkout, commit," >&2
  echo "   and rerun scripts/admin/sync-upstream.sh." >&2
  exit 1
fi

mapfile -d '' -t upstream_protected_changes < <(
  git diff --name-only -z "$merge_base" "$upstream_ref" -- \
    'vars.nix' 'hardware-configuration.nix' 'secrets/*.age' 'secrets/pubkeys/age.pub'
)
secrets_affected=false
for changed_protected_path in "${upstream_protected_changes[@]}"; do
  case "$changed_protected_path" in
    secrets/*.age|secrets/pubkeys/age.pub) secrets_affected=true ;;
  esac
done

resolve_age_identity() {
  identity_file=""
  if [[ -n "$identity_input" ]]; then
    if [[ ! -f "$identity_input" || -L "$identity_input" || ! -r "$identity_input" ]]; then
      blocked "--identity must be a readable regular file: $identity_input"
    fi
    identity_file="$identity_input"
    return 0
  fi
  if [[ -n "${NIXHOMESERVER_AGE_IDENTITY_FILE:-}" ]] \
    && [[ -f "${NIXHOMESERVER_AGE_IDENTITY_FILE}" \
      && ! -L "${NIXHOMESERVER_AGE_IDENTITY_FILE}" \
      && -r "${NIXHOMESERVER_AGE_IDENTITY_FILE}" ]]; then
    identity_file="$NIXHOMESERVER_AGE_IDENTITY_FILE"
    return 0
  fi
  installed_key="/persist/etc/agenix/age.key"
  if [[ -f "$installed_key" && ! -L "$installed_key" && -r "$installed_key" ]]; then
    identity_file="$installed_key"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 \
    && sudo -n true >/dev/null 2>&1 \
    && sudo -n test -f "$installed_key" 2>/dev/null \
    && sudo -n test -r "$installed_key" 2>/dev/null; then
    identity_tmpdir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/nixhomeserver-sync-age.XXXXXX")"
    chmod 0700 "$identity_tmpdir"
    # shellcheck disable=SC2024 # The redirect is intentional: the private
    # copy must be owned by the invoking user, not by root.
    sudo -n cat "$installed_key" >"$identity_tmpdir/age.key"
    chmod 0600 "$identity_tmpdir/age.key"
    identity_file="$identity_tmpdir/age.key"
    return 0
  fi
  return 1
}

if [[ "$secrets_affected" == "true" ]]; then
  need age age-keygen
  if ! resolve_age_identity; then
    blocked "the upstream changes modify instance secrets (secrets/*.age or secrets/pubkeys/age.pub)
   Provide this installation's private age identity so foreign ciphertext can be
   detected and regenerated instead of deployed: pass --identity <age-key>, export
   NIXHOMESERVER_AGE_IDENTITY_FILE, or make /persist/etc/agenix/age.key readable
   (the helper can copy it through passwordless sudo)."
  fi
  require_pubkey
  require_identity_for_recipient "$identity_file"
fi

echo "Merging $incoming_commits upstream commit(s) from $upstream_remote/$branch_input"
merge_in_progress=1
merge_log="$(mktemp)"
if ! git merge --no-ff --no-commit --no-edit "$upstream_ref" >"$merge_log" 2>&1; then
  mapfile -d '' -t conflicted_paths < <(git diff --name-only -z --diff-filter=U)
  unexpected_conflicts=()
  for conflict_path in "${conflicted_paths[@]}"; do
    if is_protected_path "$conflict_path"; then
      if ! git cat-file -e "$pre_head:$conflict_path" 2>/dev/null; then
        unexpected_conflicts+=("$conflict_path (protected path is absent from the pre-merge revision)")
        continue
      fi
      git cat-file blob "$pre_head:$conflict_path" >"$conflict_path"
      git add -- "$conflict_path"
    elif [[ "$conflict_path" == "flake.lock" ]] \
      && git cat-file -e "$upstream_ref:flake.lock" 2>/dev/null; then
      git cat-file blob "$upstream_ref:flake.lock" >"$conflict_path"
      git add -- "$conflict_path"
    else
      unexpected_conflicts+=("$conflict_path")
    fi
  done
  if (( ${#unexpected_conflicts[@]} > 0 )); then
    echo "blocked: upstream merge conflicts in path(s) this helper does not resolve:" >&2
    printf '   %s\n' "${unexpected_conflicts[@]}" >&2
    echo "   Nothing was merged. Port the change manually or reset the conflicting" >&2
    echo "   local file, commit, and rerun scripts/admin/sync-upstream.sh." >&2
    exit 1
  fi
  if ! git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    echo "blocked: git merge failed without entering conflict resolution:" >&2
    cat "$merge_log" >&2
    exit 1
  fi
fi
rm -f -- "$merge_log"
merge_log=""

# Instance-file enforcement: whatever the merge or conflict resolution did,
# protected paths tracked before the merge must keep their pre-merge contents,
# and every upstream change to an instance-owned path is reported for manual
# porting even when the local contents already won.
preserved_reports=()
upstream_protected_list="$(printf '%s\n' "${upstream_protected_changes[@]}")"
while IFS= read -r protected_path; do
  [[ -n "$protected_path" ]] || continue
  if [[ ! -e "$protected_path" && ! -L "$protected_path" ]]; then
    git cat-file blob "$pre_head:$protected_path" >"$protected_path"
    git add -- "$protected_path"
    preserved_reports+=("$protected_path restored (upstream deleted or moved it)")
  elif ! git cat-file blob "$pre_head:$protected_path" | cmp -s - "$protected_path"; then
    git cat-file blob "$pre_head:$protected_path" >"$protected_path"
    git add -- "$protected_path"
    preserved_reports+=("$protected_path kept (upstream changed instance-owned contents)")
  elif grep -qxF "$protected_path" <<<"$upstream_protected_list"; then
    preserved_reports+=("$protected_path kept (upstream changed instance-owned contents)")
  fi
done <<<"$protected_list"

# Secrets reconciliation: ciphertext this installation cannot decrypt must be
# replaced before the merge is committed, never carried into a deployment.
regenerated_secrets=()
foreign_orphan_secrets=()
retained_orphan_secrets=()
if [[ "$secrets_affected" == "true" ]]; then
  load_manifest_json
  generated_secret_names="$(manifest_generated_names)"
  all_secret_names="$(manifest_all_secret_names)"
  external_secret_names="$(manifest_external_specs | sed 's/\t.*//')"
  mapfile -d '' -t tracked_age_paths < <(git ls-files -z -- 'secrets/*.age')
  external_staging_blockers=()
  for age_path in "${tracked_age_paths[@]}"; do
    [[ -n "$age_path" ]] || continue
    secret_name="$(basename "$age_path" .age)"
    age_file="$repo_root/$age_path"
    if verify_encrypted_secret "$age_file" "$identity_file"; then
      if ! grep -qxF "$secret_name" <<<"$all_secret_names"; then
        retained_orphan_secrets+=("$secret_name")
      fi
      continue
    fi
    if grep -qxF "$secret_name" <<<"$generated_secret_names"; then
      rm -f -- "$age_file"
      regenerated_secrets+=("$secret_name")
    elif grep -qxF "$secret_name" <<<"$external_secret_names"; then
      if [[ -s "$repo_root/secrets/unencrypted/$secret_name" ]]; then
        rm -f -- "$age_file"
        regenerated_secrets+=("$secret_name")
      else
        external_staging_blockers+=("$secret_name")
      fi
    else
      rm -f -- "$age_file"
      foreign_orphan_secrets+=("$secret_name")
    fi
  done
  if (( ${#external_staging_blockers[@]} > 0 )); then
    echo "blocked: upstream adds external secret(s) without a staged value:" >&2
    printf '   %s\n' "${external_staging_blockers[@]}" >&2
    echo "   Nothing was merged. Create secrets/unencrypted/<name> with each plaintext" >&2
    echo "   value, then rerun scripts/admin/sync-upstream.sh. See documentation/quickstart.md" >&2
    echo "   for the staging and encryption workflow." >&2
    exit 1
  fi
  if (( ${#regenerated_secrets[@]} > 0 || ${#foreign_orphan_secrets[@]} > 0 )); then
    NIXHOMESERVER_REPO_ROOT="$repo_root" \
      bash "$script_dir/../generate-all-secrets.sh" --identity "$identity_file"
    for regenerated_name in "${regenerated_secrets[@]}"; do
      rm -f -- "$repo_root/secrets/unencrypted/$regenerated_name"
    done
    git add -- secrets
  fi
fi

git commit --no-edit >/dev/null
merge_in_progress=0

if [[ "${NIXHOMESERVER_SYNC_SKIP_EVAL:-0}" != "1" ]]; then
  if ! NIXHOMESERVER_REPO_ROOT="$repo_root" bash "$script_dir/show-config-summary.sh"; then
    echo
    echo "⚠️ The merged tree did not pass the configuration preview gate. The merge is" >&2
    echo "   committed with every instance file preserved. Port the failing setting" >&2
    echo "   manually (upstream changes to protected files are never applied" >&2
    echo "   automatically), commit, and rerun this helper before deploying." >&2
    exit 1
  fi
fi

if [[ "$push_after_sync" == "true" ]]; then
  sync_branch="$(git symbolic-ref --short HEAD)"
  if push_output="$(git push origin "$sync_branch" 2>&1)"; then
    echo "   pushed $sync_branch to origin"
  else
    echo "⚠️ Could not push $sync_branch to origin; the fork is now behind this checkout:" >&2
    printf '%s\n' "$push_output" >&2
    echo "   The local checkout and deployment are unaffected; resolve origin separately." >&2
  fi
fi

echo
echo "✅ Upstream sync complete: merged $incoming_commits commit(s) from $upstream_remote/$branch_input."
if (( ${#upstream_protected_changes[@]} > 0 )); then
  echo "   Upstream touched these instance-owned paths; port changes manually if needed:"
  printf '   %s\n' "${upstream_protected_changes[@]}"
fi
for preserved_report in "${preserved_reports[@]}"; do
  echo "   preserved instance file: $preserved_report"
done
for regenerated_name in "${regenerated_secrets[@]}"; do
  echo "   regenerated ciphertext with this installation's age key: $regenerated_name"
done
for foreign_name in "${foreign_orphan_secrets[@]}"; do
  echo "   removed foreign undecryptable ciphertext without a manifest entry: $foreign_name"
done
for orphan_name in "${retained_orphan_secrets[@]}"; do
  echo "   retained ciphertext without a manifest entry: $orphan_name"
done
if [[ "${NIXHOMESERVER_SYNC_SKIP_EVAL:-0}" != "1" ]]; then
  echo "   Next: ./scripts/deploy.sh --action test, then --action switch."
fi
