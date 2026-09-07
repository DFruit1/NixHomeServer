#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/common.sh"

# secrets-common resolves every path from $repo_root, so it is sourced only
# after common.sh has resolved the repository root.
source "$repo_root/scripts/helpers/secrets-common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/bootstrap-host.sh <command> [options]

Guided, idempotent bootstrap phases for a new NixHomeServer host. Every
command detects the current state first, performs only the work that is
missing, and refuses to touch state it cannot verify. Run the same command
again after fixing a problem; completed phases report "already converged".

Commands:
  check                Report every bootstrap phase without changing anything,
                       and print the exact next command for the first
                       incomplete phase. Always exits 0.
  init                 Seed vars.nix from vars.example.nix when absent, fill
                       the hostId placeholder for zfs-mirror hosts, and set the
                       repository-local Git author identity from the evaluated
                       settings. Never edits values an operator already set.
  identity [--identity <age-key> | --create <path>]
                       Create or adopt the installation's private age key and
                       write secrets/pubkeys/age.pub. Converged when the
                       configured recipient already matches the key.
  secrets [--identity <age-key>]
                       Stage required external secret values (interactive;
                       refuses on a non-interactive terminal and prints the
                       exact staging paths instead), then run the repository's
                       generation helper in verify or fresh mode as the
                       current ciphertext state requires. Converged when every
                       required secret decrypts with the identity.
  pin-guid             Verify the created ZFS pool against every configured
                       member and pin its GUID into vars.nix (zfs-mirror only).
  install [--identity <age-key>] [--force-install]
                       Installer-phase sequence: verify the Disko layout, seed
                       the persisted checkout, bind-mount it at /mnt/etc/nixos,
                       install the private age key, run the readiness gate,
                       and run nixos-install. Skips steps that are already
                       done.
  first-boot           Run on the newly installed system: report failed units,
                       adopt the assigned NetBird peer address into vars.nix
                       when it differs, fix repository ownership, and print
                       the remaining operator steps.

Phases that are already handled by dedicated guarded helpers (bootstrap-disks,
bootstrap-storage-plan, and the guarded deploy) are pointed to, not wrapped.

See documentation/quickstart.md for the authoritative narrative.
EOF
}

command_name="${1:-}"
if [[ -z "$command_name" ]]; then
  usage >&2
  exit 1
fi
shift || true

case "$command_name" in
  check|init|identity|secrets|pin-guid|install|first-boot) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

host=""
identity_input=""
create_key_input=""
force_install=0
while (($# > 0)); do
  case "$1" in
    --host)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --host requires a flake hostname" >&2; exit 1; }
      host="${2:-}"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --identity requires a private age key path" >&2; exit 1; }
      identity_input="${2:-}"
      shift 2
      ;;
    --create)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --create requires a new private key path" >&2; exit 1; }
      create_key_input="${2:-}"
      shift 2
      ;;
    --force-install)
      force_install=1
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

need bash git jq nix sed grep mktemp
if ((status_blocked > 0)); then
  finish_report
fi

vars_file="$repo_root/vars.nix"
example_file="$repo_root/vars.example.nix"

# --- Shared detection helpers ------------------------------------------------

vars_exists() {
  [[ -f "$vars_file" && ! -L "$vars_file" ]]
}

vars_hostname() {
  sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$vars_file" | head -n 1
}

require_resolved_host() {
  if [[ -z "$host" ]]; then
    host="$(vars_hostname)"
  fi
  if ! validate_flake_host_name "$host"; then
    echo "blocked: could not resolve a valid flake hostname from vars.nix; pass --host <name>" >&2
    exit 1
  fi
}

# Template residue in a freshly seeded vars.nix: the exact placeholder values
# from vars.example.nix that must be replaced before the host is real.
vars_template_lines() {
  grep -nE 'CHANGE_ME|REPLACE_ME|example\.test|192\.0\.2\.|example-server' "$vars_file" 2>/dev/null || true
}

settings_json_or_empty() {
  local candidate="${host:-$(vars_hostname 2>/dev/null || true)}"
  validate_flake_host_name "$candidate" || return 0
  nix_json_for_host "$candidate" \
    "removeAttrs (builtins.getAttr hostName flake.lib.nixhomeserverSettings) [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]" \
    2>/dev/null || true
}

resolve_age_identity() {
  identity_file=""
  if [[ -n "$identity_input" ]]; then
    if [[ ! -f "$identity_input" || -L "$identity_input" || ! -r "$identity_input" ]]; then
      echo "blocked: --identity must be a readable regular file: $identity_input" >&2
      exit 1
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
  return 1
}

require_clean_worktree() {
  if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
    echo "blocked: the repository worktree is not clean; commit or remove the changes first:" >&2
    git status --short >&2
    exit 1
  fi
}

replace_single_quoted_value() {
  local key="$1" new_value="$2" matches
  matches="$(grep -cE "^[[:space:]]*${key}[[:space:]]*=" "$vars_file" || true)"
  if [[ "$matches" != "1" ]]; then
    return 1
  fi
  sed -i -E "/^[[:space:]]*${key}[[:space:]]*=/s/\"[^\"]*\"/\"${new_value}\"/" "$vars_file"
}

# --- check -------------------------------------------------------------------

run_check() {
  local next_command=""

  report_phase() {
    local state="$1" label="$2" detail="$3"
    case "$state" in
      ok) printf '[done]   %s — %s\n' "$label" "$detail" ;;
      todo) printf '[todo]   %s — %s\n' "$label" "$detail" ;;
      blocked) printf '[blocked] %s — %s\n' "$label" "$detail" ;;
    esac
  }

  echo "NixHomeServer bootstrap status"
  echo

  # Phase 1: vars.nix
  if ! vars_exists; then
    report_phase todo "vars.nix" "missing"
    next_command="scripts/admin/bootstrap-host.sh init"
  else
    template_lines="$(vars_template_lines)"
    if [[ -n "$template_lines" ]]; then
      report_phase todo "vars.nix" "template values remain:"
      printf '         %s\n' "${template_lines//$'\n'/$'\n         '}"
      next_command='$EDITOR vars.nix   # replace every flagged template value'
    else
      vars_hostname_value="$(vars_hostname)"
      if ! validate_flake_host_name "$vars_hostname_value"; then
        report_phase blocked "vars.nix" "network.hostname is missing or malformed"
        next_command='$EDITOR vars.nix'
      else
        if settings_json="$(settings_json_or_empty)" && [[ -n "$settings_json" ]]; then
          report_phase ok "vars.nix" "evaluates for host '${vars_hostname_value}'"
        else
          report_phase blocked "vars.nix" "does not evaluate; run: nix run .#show-config-summary"
          next_command="nix run .#show-config-summary"
        fi
      fi
    fi
  fi

  # Phase 2: age identity
  if [[ -s "$pubkey_file" ]]; then
    if [[ -n "$identity_input" ]]; then
      if age-keygen -y "$identity_input" 2>/dev/null | tr -d '\r\n' \
        | grep -qxF "$(tr -d '\r\n' <"$pubkey_file")"; then
        report_phase ok "age identity" "recipient matches $pubkey_file"
      else
        report_phase blocked "age identity" "does not match $pubkey_file"
      fi
    else
      report_phase ok "age identity" "recipient configured at $pubkey_file (pass --identity to verify a key)"
    fi
  else
    report_phase todo "age identity" "no recipient configured"
    [[ -n "$next_command" ]] || next_command="scripts/admin/bootstrap-host.sh identity --create /path/to/new/age.key"
  fi

  # Phase 3: secrets
  if [[ ! -s "$pubkey_file" ]]; then
    report_phase todo "secrets" "requires the age identity phase"
  else
    if ! resolve_age_identity; then
      report_phase todo "secrets" "verify by rerunning with --identity <age-key>"
    else
      load_manifest_json >/dev/null 2>&1 || true
      if [[ -z "${NIXHOMESERVER_MANIFEST_JSON:-}" ]]; then
        report_phase blocked "secrets" "secrets/manifest.nix does not evaluate"
      else
        secrets_problem=""
        while IFS=$'\t' read -r secret_name _validator required; do
          [[ "$required" == "true" ]] || continue
          if ! verify_encrypted_secret "$repo_root/secrets/${secret_name}.age" "$identity_file"; then
            secrets_problem="$secrets_problem ${secret_name}"
          fi
        done <<<"$(manifest_external_specs)"
        if [[ -n "$secrets_problem" ]]; then
          report_phase todo "secrets" "missing or undecryptable required secrets:$secrets_problem"
          [[ -n "$next_command" ]] || next_command="scripts/admin/bootstrap-host.sh secrets --identity <age-key>"
        else
          report_phase ok "secrets" "every required secret decrypts with the configured identity"
        fi
      fi
    fi
  fi

  # Phase 4: committed checkpoint
  if [[ -n "$(git status --porcelain=v1 --untracked-files=all)" ]]; then
    report_phase todo "checkpoint" "worktree has uncommitted changes"
    [[ -n "$next_command" ]] || next_command="git add -A && git commit"
  else
    current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
    if [[ -n "$current_branch" ]] \
      && git rev-parse --verify -q "origin/$current_branch" >/dev/null 2>&1; then
      unpushed="$(git rev-list --count "origin/$current_branch..HEAD")"
      if ((unpushed > 0)); then
        report_phase todo "checkpoint" "$unpushed commit(s) not pushed to origin"
        [[ -n "$next_command" ]] || next_command="git push"
      else
        report_phase ok "checkpoint" "clean and pushed to origin/$current_branch"
      fi
    else
      report_phase ok "checkpoint" "clean (no origin branch to compare)"
    fi
  fi

  # Phase 5: storage plan / disks
  if settings_json="$(settings_json_or_empty)" && [[ -n "$settings_json" ]]; then
    storage_profile="$(jq -r '.storageProfile' <<<"$settings_json")"
    if [[ "$storage_profile" != "zfs-mirror" ]]; then
      report_phase ok "disks" "profile '$storage_profile' needs no ZFS GUID pin"
    else
      pinned_guid="$(jq -r '.zfsDataPool.expectedGuid // empty' <<<"$settings_json")"
      if [[ -n "$pinned_guid" ]]; then
        report_phase ok "disks" "ZFS pool GUID pinned ($pinned_guid)"
      else
        report_phase todo "disks" "pool GUID unpinned; provision with the guarded Disko wrapper"
        [[ -n "$next_command" ]] || next_command="nix run .#bootstrap-storage-plan   # then nix run .#bootstrap-disks (see quickstart)"
      fi
    fi
  else
    report_phase todo "disks" "requires an evaluating vars.nix"
  fi

  # Phase 6: installer target (only meaningful where /mnt is provisioned)
  if [[ -d /mnt/persist/etc/nixos/.git ]]; then
    if [[ "$(git -C /mnt/persist/etc/nixos rev-parse HEAD 2>/dev/null || true)" == "$(git rev-parse HEAD)" ]]; then
      report_phase ok "install" "persisted checkout matches this revision"
    else
      report_phase todo "install" "persisted checkout differs from this revision"
      [[ -n "$next_command" ]] || next_command="scripts/admin/bootstrap-host.sh install"
    fi
  else
    report_phase todo "install" "no persisted checkout at /mnt/persist/etc/nixos yet"
    [[ -n "$next_command" ]] || next_command="scripts/admin/bootstrap-host.sh install"
  fi

  # Phase 7: first boot (only meaningful on the installed system)
  if [[ -d /persist/etc/nixos && -d /run/agenix ]]; then
    report_phase todo "first-boot" "run the convergence helper on the installed system"
    [[ -n "$next_command" ]] || next_command="scripts/admin/bootstrap-host.sh first-boot"
  else
    report_phase todo "first-boot" "not on the installed system yet (expected during bootstrap)"
  fi

  echo
  if [[ -n "$next_command" ]]; then
    echo "next: $next_command"
  else
    echo "next: all reported phases are converged; continue with documentation/quickstart.md"
  fi
}

# --- init --------------------------------------------------------------------

run_init() {
  if ! vars_exists; then
    if [[ ! -f "$example_file" ]]; then
      echo "blocked: $example_file is missing; cannot seed vars.nix" >&2
      exit 1
    fi
    cp -- "$example_file" "$vars_file"
    echo "seeded vars.nix from vars.example.nix"
  else
    echo "already converged: vars.nix exists; leaving its contents untouched"
  fi

  # Fill the hostId placeholder only when it is still the documented example
  # value and the storage profile requires one. Operator values are never
  # rewritten.
  if grep -qE '^[[:space:]]*hostId[[:space:]]*=[[:space:]]*"00000000"[[:space:]]*;' "$vars_file" \
    && grep -qE '^[[:space:]]*profile[[:space:]]*=[[:space:]]*"zfs-mirror"' "$vars_file"; then
    matches="$(grep -cE '^[[:space:]]*hostId[[:space:]]*=[[:space:]]*"00000000"[[:space:]]*;' "$vars_file" || true)"
    if [[ "$matches" != "1" ]]; then
      echo "blocked: expected exactly one hostId placeholder line, found $matches" >&2
      exit 1
    fi
    new_host_id="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sed -i -E 's/^([[:space:]]*hostId[[:space:]]*=[[:space:]]*)"00000000"([[:space:]]*;)/\1"'"$new_host_id"'"\2/' "$vars_file"
    echo "generated hostId $new_host_id"
  else
    echo "already converged: hostId is set or not required"
  fi

  # The quickstart derives the repository-local Git author identity from the
  # evaluated settings. Set it only when it is not configured yet.
  if [[ -z "$(git config --local --get user.name || true)" ]] \
    || [[ -z "$(git config --local --get user.email || true)" ]]; then
    require_resolved_host
    if admin_user="$(nix eval --raw ".#lib.nixhomeserverSettings.${host}.kanidmAdminUser" 2>/dev/null)" \
      && admin_email="$(nix eval --raw ".#lib.nixhomeserverSettings.${host}.kanidmAdminEmail" 2>/dev/null)" \
      && [[ -n "$admin_user" && -n "$admin_email" ]]; then
      git config --local user.name "$admin_user"
      git config --local user.email "$admin_email"
      echo "set repository-local Git author identity from the evaluated settings"
    else
      echo "note: could not evaluate settings for a Git author identity; set user.name and user.email manually"
    fi
  else
    echo "already converged: Git author identity configured"
  fi

  template_lines="$(vars_template_lines)"
  if [[ -n "$template_lines" ]]; then
    echo
    echo "next: replace every remaining template value in vars.nix:"
    printf '  %s\n' "${template_lines//$'\n'/$'\n  '}"
    echo "then: nix run .#show-config-summary"
  else
    echo
    echo "next: nix run .#show-config-summary"
  fi
}

# --- identity ----------------------------------------------------------------

run_identity() {
  need age-keygen
  if ((status_blocked > 0)); then
    finish_report
  fi
  install -d -m 0755 "$repo_root/secrets/pubkeys"

  if [[ -n "$create_key_input" && -n "$identity_input" ]]; then
    echo "blocked: --create and --identity are mutually exclusive" >&2
    exit 1
  fi

  if [[ -s "$pubkey_file" ]]; then
    if [[ -n "$identity_input" ]]; then
      require_identity_for_recipient "$identity_input"
      echo "already converged: $identity_input matches $pubkey_file"
      return
    fi
    if [[ -n "$create_key_input" ]]; then
      if [[ -f "$create_key_input" ]] \
        && age-keygen -y "$create_key_input" 2>/dev/null | tr -d '\r\n' \
          | grep -qxF "$(tr -d '\r\n' <"$pubkey_file")"; then
        echo "already converged: $create_key_input matches $pubkey_file"
        return
      fi
      echo "blocked: $pubkey_file already configures a different recipient; refusing to replace it" >&2
      echo "   Adopt the existing key with --identity <path>, or rotate deliberately with" >&2
      echo "   nix run .#generate-secrets -- --rekey (see documentation/quickstart.md)." >&2
      exit 1
    fi
    echo "already converged: recipient configured at $pubkey_file"
    return
  fi

  if [[ -n "$identity_input" ]]; then
    age-keygen -y "$identity_input" >"$pubkey_file"
    echo "configured recipient at $pubkey_file from the provided identity"
    return
  fi

  if [[ -z "$create_key_input" ]]; then
    echo "blocked: creating a new identity requires --create <path> for the private key" >&2
    exit 1
  fi
  if [[ -e "$create_key_input" || -L "$create_key_input" ]]; then
    echo "blocked: refusing to overwrite an existing file: $create_key_input" >&2
    exit 1
  fi
  key_parent="$(dirname -- "$create_key_input")"
  # Existing directories keep their permissions; newly created ones are 0700.
  install -d -m 0700 -- "$key_parent"
  age-keygen -o "$create_key_input" >/dev/null
  chmod 0400 "$create_key_input"
  age-keygen -y "$create_key_input" >"$pubkey_file"
  echo "created private key at $create_key_input (mode 0400)"
  echo "configured recipient at $pubkey_file"
  echo
  echo "next: keep a second copy of this key on separately mounted durable storage"
  echo "      before destructive disk work; documentation/quickstart.md requires it."
}

# --- secrets -----------------------------------------------------------------

run_secrets() {
  need age age-keygen openssl
  if ((status_blocked > 0)); then
    finish_report
  fi
  if ! resolve_age_identity; then
    echo "blocked: staging and verifying secrets requires this installation's private age identity" >&2
    echo "   Pass --identity <age-key> or export NIXHOMESERVER_AGE_IDENTITY_FILE." >&2
    exit 1
  fi
  require_pubkey
  require_identity_for_recipient "$identity_file"
  load_manifest_json

  ensure_secrets_layout >/dev/null
  external_specs="$(manifest_external_specs)"

  # Classify the current ciphertext state to choose the generation mode.
  mode="verify"
  while IFS=$'\t' read -r secret_name _validator required; do
    [[ "$required" == "true" ]] || continue
    if ! verify_encrypted_secret "$repo_root/secrets/${secret_name}.age" "$identity_file"; then
      if [[ -s "$repo_root/secrets/${secret_name}.age" ]]; then
        # Ciphertext that this installation cannot decrypt requires a fresh
        # generation pass; verify mode would refuse it.
        mode="fresh"
      fi
    fi
  done <<<"$external_specs"

  created_staging_files=()
  stage_external_value() {
    local secret_name="$1" validator="$2" value attempts=0
    local target="$repo_root/secrets/unencrypted/$secret_name"
    if [[ -s "$target" ]] && "$validator" "$target"; then
      return 0
    fi
    if [[ ! -t 0 ]]; then
      echo "blocked: $secret_name needs a staged value but this terminal is not interactive" >&2
      echo "   Create $target (mode 0600) with the plaintext value, then rerun this command." >&2
      exit 1
    fi
    while ((attempts < 3)); do
      attempts=$((attempts + 1))
      printf 'Enter %s (input hidden): ' "$secret_name" >&2
      IFS= read -r -s value </dev/tty || true
      printf '%s' "$value" >"$target"
      chmod 0600 "$target"
      unset value
      if [[ -s "$target" ]] && "$validator" "$target"; then
        created_staging_files+=("$secret_name")
        return 0
      fi
      echo "  invalid format for $secret_name; try again" >&2
    done
    echo "blocked: $secret_name did not accept a valid value after 3 attempts" >&2
    exit 1
  }

  while IFS=$'\t' read -r secret_name validator_name required; do
    [[ "$required" == "true" ]] || continue
    if [[ "$mode" == "verify" ]] \
      && verify_encrypted_secret "$repo_root/secrets/${secret_name}.age" "$identity_file"; then
      continue
    fi
    stage_external_value "$secret_name" "$(validator_function "$validator_name")"
  done <<<"$external_specs"

  # Prove convergence without regenerating anything when every generated and
  # required external secret already decrypts with this identity.
  if [[ "$mode" == "verify" && ${#created_staging_files[@]} -eq 0 ]]; then
    all_ciphertext_ok=1
    while IFS= read -r generated_name; do
      [[ -n "$generated_name" ]] || continue
      if ! verify_encrypted_secret "$repo_root/secrets/${generated_name}.age" "$identity_file"; then
        all_ciphertext_ok=0
        break
      fi
    done <<<"$(manifest_generated_names)"
    if [[ "$all_ciphertext_ok" == "1" ]]; then
      echo "already converged: every required secret decrypts with the configured identity"
      return
    fi
  fi

  fresh_flag=()
  if [[ "$mode" == "fresh" ]]; then
    fresh_flag=(--fresh)
    echo "replacing inherited ciphertext with values for this installation"
  fi
  NIXHOMESERVER_REPO_ROOT="$repo_root" \
    bash "$repo_root/scripts/generate-all-secrets.sh" "${fresh_flag[@]+"${fresh_flag[@]}"}" --identity "$identity_file"

  # Hygiene: plaintext staged for this run is now encrypted and redundant.
  # Remove the required external values plus every generated secret's plaintext
  # copy so the readiness gate's staging check stays clean.
  while IFS=$'\t' read -r secret_name _validator required; do
    [[ "$required" == "true" ]] || continue
    rm -f -- "$repo_root/secrets/unencrypted/$secret_name"
  done <<<"$external_specs"
  while IFS= read -r generated_name; do
    [[ -n "$generated_name" ]] || continue
    rm -f -- "$repo_root/secrets/unencrypted/$generated_name"
  done <<<"$(manifest_generated_names)"
  leftover="$(find "$repo_root/secrets/unencrypted" -mindepth 1 -print -quit 2>/dev/null || true)"
  if [[ -n "$leftover" ]]; then
    echo "note: secrets/unencrypted still contains operator-staged values; move them to"
    echo "      a vault and remove them before installation or deployment."
  fi
  echo
  echo "next: commit the encrypted configuration (git add vars.nix secrets && git commit)"
}

# --- pin-guid ----------------------------------------------------------------

run_pin_guid() {
  require_resolved_host
  settings_json="$(nix_json_for_host "$host" \
    "removeAttrs (builtins.getAttr hostName flake.lib.nixhomeserverSettings) [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]")"
  storage_profile="$(jq -r '.storageProfile' <<<"$settings_json")"
  if [[ "$storage_profile" != "zfs-mirror" ]]; then
    echo "already converged: storage profile '$storage_profile' has no ZFS pool GUID to pin"
    return
  fi
  pool_name="$(jq -r '.zfsDataPool.name' <<<"$settings_json")"
  current_guid="$(jq -r '.zfsDataPool.expectedGuid // empty' <<<"$settings_json")"

  if ! command -v zpool >/dev/null 2>&1; then
    echo "blocked: zpool is not available on this machine; pin the GUID from the installer" >&2
    echo "   after nix run .#bootstrap-disks has created the pool (documentation/quickstart.md)." >&2
    exit 1
  fi

  device_args=()
  while IFS= read -r disk_id; do
    [[ -n "$disk_id" ]] || continue
    device_args+=(--expected-device "/dev/disk/by-id/$disk_id")
  done <<<"$(jq -r '.zfsDataPoolDiskIds[]' <<<"$settings_json")"
  if (( ${#device_args[@]} == 0 )); then
    echo "blocked: no data-pool members are configured in vars.nix" >&2
    exit 1
  fi

  bash "$repo_root/scripts/helpers/verify-zfs-pool-identity.sh" \
    --pool "$pool_name" "${device_args[@]}"
  live_guid="$(zpool get -H -o value guid "$pool_name" 2>/dev/null || true)"
  if [[ ! "$live_guid" =~ ^[0-9]+$ ]]; then
    echo "blocked: could not read a numeric GUID for pool '$pool_name' (run as root on the installer?)" >&2
    exit 1
  fi

  if [[ -n "$current_guid" ]]; then
    if [[ "$current_guid" == "$live_guid" ]]; then
      echo "already converged: pool '$pool_name' GUID $live_guid is pinned in vars.nix"
      return
    fi
    echo "blocked: vars.nix pins GUID $current_guid but the live pool reports $live_guid" >&2
    echo "   A changed pool identity is a recovery scenario, not a bootstrap routine;" >&2
    echo "   see documentation/restore-and-recovery.md." >&2
    exit 1
  fi

  require_clean_worktree
  null_matches="$(grep -cE '^[[:space:]]*expectedGuid[[:space:]]*=[[:space:]]*null[[:space:]]*;' "$vars_file" || true)"
  if [[ "$null_matches" != "1" ]]; then
    echo "blocked: expected exactly one 'expectedGuid = null;' line in vars.nix, found $null_matches" >&2
    exit 1
  fi
  sed -i "s/^\([[:space:]]*expectedGuid[[:space:]]*=[[:space:]]*\)null[[:space:]]*;/\1\"$live_guid\";/" "$vars_file"
  evaluated_guid="$(nix eval --raw ".#lib.nixhomeserverSettings.${host}.zfsDataPool.expectedGuid")"
  if [[ "$evaluated_guid" != "$live_guid" ]]; then
    echo "blocked: the patched vars.nix evaluates to '$evaluated_guid', expected '$live_guid'" >&2
    exit 1
  fi
  git add -- vars.nix
  git commit -q -m "Pin newly created ZFS pool identity"
  echo "pinned pool '$pool_name' GUID $live_guid in vars.nix and committed"
}

# --- install -----------------------------------------------------------------

run_install() {
  [[ "$(id -u)" -eq 0 ]] || {
    echo "blocked: the installer phase runs as root on the NixOS installer" >&2
    exit 1
  }
  require_resolved_host
  settings_json="$(nix_json_for_host "$host" \
    "removeAttrs (builtins.getAttr hostName flake.lib.nixhomeserverSettings) [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]")"
  storage_profile="$(jq -r '.storageProfile' <<<"$settings_json")"

  if [[ "$storage_profile" == "zfs-mirror" ]]; then
    for mount_point in /mnt /mnt/boot /mnt/nix /mnt/persist; do
      findmnt -rno SOURCE,TARGET,FSTYPE "$mount_point" >/dev/null 2>&1 || {
        echo "blocked: $mount_point is not mounted; run 'nix run .#bootstrap-disks' first" >&2
        echo "   (read-only review: sudo nix run .#bootstrap-disks -- --host $host)" >&2
        exit 1
      }
    done
    zpool list -H -o name 2>/dev/null | grep -qx "$(jq -r '.zfsDataPool.name' <<<"$settings_json")" || {
      echo "blocked: the configured ZFS pool is not imported; run the Disko wrapper first" >&2
      exit 1
    }
  else
    findmnt -rno SOURCE,TARGET,FSTYPE /mnt >/dev/null 2>&1 || {
      echo "blocked: /mnt is not mounted; run 'nix run .#bootstrap-disks' first" >&2
      exit 1
    }
    for required_dir in /mnt/persist /mnt/nix; do
      [[ -d "$required_dir" ]] || {
        echo "blocked: $required_dir is missing; run 'nix run .#bootstrap-disks' first" >&2
        exit 1
      }
    done
  fi

  install_target="/mnt/persist/etc/nixos"
  if [[ -d "$install_target/.git" ]]; then
    seeded_head="$(git -c safe.directory="$install_target" -C "$install_target" rev-parse HEAD 2>/dev/null || true)"
    seeded_dirty="$(git -c safe.directory="$install_target" -C "$install_target" status --porcelain 2>/dev/null || true)"
    if [[ "$seeded_head" == "$(git rev-parse HEAD)" && -z "$seeded_dirty" ]]; then
      echo "already converged: persisted checkout matches revision $(git rev-parse HEAD)"
    else
      echo "blocked: $install_target exists with a different revision or dirty state" >&2
      echo "   seeded HEAD: ${seeded_head:-none}; local HEAD: $(git rev-parse HEAD)" >&2
      echo "   Reconcile manually or remove the directory to reseed." >&2
      exit 1
    fi
  else
    bash "$repo_root/scripts/admin/seed-install-repository.sh" --target "$install_target"
  fi

  if findmnt -rno TARGET /mnt/etc/nixos >/dev/null 2>&1; then
    echo "already converged: /mnt/etc/nixos is bound to the persisted checkout"
  else
    install -d -m 0755 /mnt/etc/nixos
    mount --bind "$install_target" /mnt/etc/nixos
    echo "bound /mnt/etc/nixos to $install_target"
  fi

  target_key="/mnt/persist/etc/agenix/age.key"
  if [[ -f "$target_key" ]]; then
    echo "already converged: private age key is installed at $target_key"
  else
    if ! resolve_age_identity; then
      echo "blocked: installing the private age key requires --identity <age-key>" >&2
      exit 1
    fi
    install -d -m 0700 /mnt/persist/etc/agenix
    install -m 0400 -- "$identity_file" "$target_key"
    echo "installed the private age key at $target_key"
  fi
  if [[ "$(age-keygen -y "$target_key" 2>/dev/null | tr -d '\r\n')" \
    != "$(tr -d '\r\n' <"$repo_root/secrets/pubkeys/age.pub")" ]]; then
    echo "blocked: the installed age key does not match secrets/pubkeys/age.pub" >&2
    exit 1
  fi
  echo "verified: installed age key matches the configured recipient"

  (
    cd "$install_target"
    bash "$install_target/scripts/admin/validate-config-readiness.sh" \
      --host "$host" --require-local-hardware --identity "$target_key"
  )

  if [[ -z "$(readlink /mnt/nix/var/nix/profiles/system 2>/dev/null || true)" ]] || [[ "$force_install" == "1" ]]; then
    nixos-install --flake "/mnt/etc/nixos#${host}"
    echo "installed NixOS for host '${host}'"
  else
    echo "already converged: a system profile exists; skipping nixos-install (use --force-install to reinstall)"
  fi

  echo
  echo "next: reboot, then run scripts/admin/bootstrap-host.sh first-boot on the server"
}

# --- first-boot --------------------------------------------------------------

run_first_boot() {
  require_resolved_host
  if [[ ! -d /persist/etc/nixos || ! -d /run/agenix ]]; then
    echo "blocked: this command runs on the installed system (needs /persist/etc/nixos and /run/agenix)" >&2
    exit 1
  fi
  settings_json="$(nix_json_for_host "$host" \
    "removeAttrs (builtins.getAttr hostName flake.lib.nixhomeserverSettings) [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]")"

  failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | grep -v '^$' || true)"
  if [[ -n "$failed_units" ]]; then
    echo "note: failed units (the NetBird verifier fails until its address is adopted):"
    printf '  %s\n' "${failed_units//$'\n'/$'\n  '}"
  else
    echo "already converged: no failed systemd units"
  fi

  expected_netbird_ip="$(jq -r '.networking.netbird.ip' <<<"$settings_json")"
  netbird_cidr="$(jq -r '.networking.netbird.cidr' <<<"$settings_json")"
  actual_netbird_ip="$(ip -4 -o address show dev nb0 2>/dev/null \
    | awk '{ sub(/\/.*/, "", $4); print $4; exit }')"
  if [[ -z "$actual_netbird_ip" ]]; then
    echo "blocked: nb0 has no IPv4 address yet; check netbird-main-login.service and the setup key" >&2
    exit 1
  fi
  if [[ "$actual_netbird_ip" != "$expected_netbird_ip" ]]; then
    if ! python3 -c 'import ipaddress, sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 1)' \
      "$actual_netbird_ip" "$netbird_cidr"; then
      echo "blocked: NetBird assigned $actual_netbird_ip, which is outside $netbird_cidr" >&2
      exit 1
    fi
    repo_dir="/persist/etc/nixos"
    cd "$repo_dir"
    require_clean_worktree
    if ! replace_single_quoted_value "netbirdIp" "$actual_netbird_ip"; then
      echo "blocked: expected exactly one netbirdIp assignment in vars.nix" >&2
      exit 1
    fi
    evaluated_ip="$(nix eval --raw ".#lib.nixhomeserverSettings.${host}.nbIP")"
    if [[ "$evaluated_ip" != "$actual_netbird_ip" ]]; then
      echo "blocked: the patched vars.nix evaluates to '$evaluated_ip', expected '$actual_netbird_ip'" >&2
      exit 1
    fi
    git add -- vars.nix
    git commit -q -m "Adopt assigned NetBird peer address"
    echo "adopted NetBird peer address $actual_netbird_ip into vars.nix and committed"
    echo
    echo "next: ./scripts/deploy.sh --action test && ./scripts/deploy.sh --action switch"
    return
  fi
  echo "already converged: NetBird address matches vars.nix ($expected_netbird_ip)"

  if [[ "$(id -u)" -eq 0 ]]; then
    local_admin_user="$(jq -r '.localAdminUser' <<<"$settings_json")"
    repo_owner="$(stat -c '%U' /persist/etc/nixos)"
    if [[ "$repo_owner" != "$local_admin_user" ]]; then
      chown -R "$local_admin_user:" /persist/etc/nixos
      echo "transferred /persist/etc/nixos ownership to $local_admin_user"
    else
      echo "already converged: repository owned by $local_admin_user"
    fi
  else
    echo "note: run with sudo once to hand /persist/etc/nixos to the configured local administrator"
  fi

  if command -v kanidm-operator-bootstrap >/dev/null 2>&1; then
    sudo -n kanidm-operator-bootstrap status 2>/dev/null || true
  fi
  echo
  echo "next: sudo kanidm-operator-bootstrap issue   # then open the printed reset URL"
  echo "next: ./scripts/deploy.sh --action test && ./scripts/deploy.sh --action switch"
}

case "$command_name" in
  check) run_check ;;
  init) run_init ;;
  identity) run_identity ;;
  secrets) run_secrets ;;
  pin-guid) run_pin_guid ;;
  install) run_install ;;
  first-boot) run_first_boot ;;
esac
