#!/usr/bin/env bash

# Return success only for the deployed managed repository. Disaster-recovery
# configs may live on restored or external storage and must not be coupled to
# the normal data-root mountpoint.
kopia_managed_requires_data_root_mount() {
  local recovery_config="${1:-}"
  [[ "$recovery_config" =~ ^[01]$ ]] || return 2
  ((recovery_config == 0))
}

# Validate a disaster-recovery config path without permitting traversal,
# nested children, symlinks, or configs in a directory writable by anyone
# other than root. A missing leaf is allowed because `repository connect`
# creates its config; an existing leaf must already be a private root-owned
# regular file. ROOT is an explicit test seam and is fixed by production
# callers to /run/kopia-recovery.
kopia_managed_validate_recovery_config_path() {
  local candidate="$1"
  local root="${2:-/run/kopia-recovery}"
  local expected_owner="${3:-0}"
  local name root_canonical candidate_canonical root_metadata file_metadata
  local file_owner file_mode file_links

  [[ -n "$candidate" && -n "$root" && "$candidate" == "$root/"* ]] || return 1
  name="${candidate#"$root/"}"
  [[ -n "$name" && "$name" != */* && "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.config$ ]] || return 1
  [[ -d "$root" && ! -L "$root" ]] || return 1
  root_canonical="$(readlink -f -- "$root" 2>/dev/null)" || return 1
  [[ "$root_canonical" == "$root" ]] || return 1
  root_metadata="$(stat -c '%u:%a' -- "$root" 2>/dev/null)" || return 1
  [[ "$root_metadata" == "${expected_owner}:700" ]] || return 1

  candidate_canonical="$(readlink -m -- "$candidate" 2>/dev/null)" || return 1
  [[ "$candidate_canonical" == "$root_canonical/$name" ]] || return 1
  if [[ -e "$candidate" || -L "$candidate" ]]; then
    [[ -f "$candidate" && ! -L "$candidate" ]] || return 1
    file_metadata="$(stat -c '%u:%a:%h' -- "$candidate" 2>/dev/null)" || return 1
    IFS=':' read -r file_owner file_mode file_links <<<"$file_metadata"
    [[ "$file_owner" == "$expected_owner" && "$file_mode" =~ ^[0-7]{3,4}$ && "$file_links" == 1 ]] || return 1
    (( (8#$file_mode & 077) == 0 )) || return 1
  fi
}
