#!/usr/bin/env bash
# Deploy preflight for the configured local-admin sudo policy.
#
# The guarded deploy performs non-interactive sudo on the target host
# (scripts/helpers/deploy-executor.sh): `sudo systemctl`, `sudo /bin/sh -c ...`
# for activation scripts, and `nix --profile ... switch-to-configuration`.
# vars.identity.localAdminSudo selects whether the local admin still holds that
# passwordless grant (see lib/local-admin-sudo.nix and the "Local-Admin Sudo
# Policy" section of documentation/operations.md).
#
# The preflight is about what the *target host* can actually authenticate, not
# about what the local checkout asks for. A restricted desired policy is still
# deployable from the workstation while the target is running the bootstrap
# grant, because that grant only disappears once the activation lands; after
# that the host needs a console-driven or interactive-sudo route, which
# deployBlockedReason states with exact commands.
#
# Sourced by scripts/deploy.sh. Expects `deploy_config_json` to hold the JSON
# object produced by nix_flake_json, and `target_host` the resolved target.
# Prints the configured policy and refuses, before anything is staged, when the
# target cannot authenticate this host's non-interactive sudo contract.

# Written by activation from the running generation's policy
# (modules/Core_Modules/base-system/default.nix), so it describes the host
# rather than the checkout being deployed.
local_admin_sudo_policy_state_file="/etc/nixhomeserver/local-admin-sudo-policy"

# Reads the policy the target host is currently running. Prints "unknown" for
# any target that cannot be asked, rather than assuming it may still
# authenticate non-interactive sudo.
read_target_local_admin_sudo_policy() {
  local target="${1:-}" policy

  if [[ -z "$target" ]]; then
    printf 'unknown\n'
    return 0
  fi
  policy="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
    "head -n 1 ${local_admin_sudo_policy_state_file} 2>/dev/null" 2>/dev/null \
    | tr -d '[:space:]')" || policy=""
  case "$policy" in
    bootstrap-nopasswd|password-authenticated) printf '%s\n' "$policy" ;;
    *) printf 'unknown\n' ;;
  esac
}

enforce_local_admin_sudo_policy() {
  local policy needs_passwordless blocked_reason target_policy
  policy="$(jq -r '.localAdminSudo // "unknown"' <<<"$deploy_config_json")"
  # jq's `//` also substitutes for a literal `false`, so read the boolean
  # explicitly: a restricted policy reports false here and must not be read
  # back as a missing field.
  needs_passwordless="$(jq -r '
    if has("localAdminSudoDeployRequiresPasswordlessSudo")
    then (.localAdminSudoDeployRequiresPasswordlessSudo | tostring)
    else "true"
    end
  ' <<<"$deploy_config_json")"
  blocked_reason="$(jq -r '.localAdminSudoDeployBlockedReason // empty' <<<"$deploy_config_json")"
  if [[ "$needs_passwordless" == "true" ]]; then
    echo "local admin sudo policy=${policy}"
    return 0
  fi

  # A deploy already running as root holds the authorization the guarded flow
  # needs, because every downstream `sudo` then runs as root. This is the
  # console route: `sudo ./scripts/deploy.sh --action test`.
  if [[ "$(id -u)" == "0" ]]; then
    echo "local admin sudo policy=${policy} (deploy is running as root on ${target_host:-this host}; downstream sudo needs no grant)"
    return 0
  fi

  target_policy="$(read_target_local_admin_sudo_policy "${target_host:-}")"
  if [[ "$target_policy" == "bootstrap-nopasswd" ]]; then
    # The transition deploy is authorized: the host being replaced still holds
    # the grant this deploy needs, and it disappears only when the new
    # generation activates.
    echo "local admin sudo policy=${policy} (target still runs ${target_policy}; this activation removes unattended passwordless sudo from ${target_host:-this host})"
    return 0
  fi

  echo "blocked: ${blocked_reason}" >&2
  if [[ "$target_policy" == "unknown" ]]; then
    echo "blocked: could not read ${local_admin_sudo_policy_state_file} on ${target_host:-the target host}; refusing to assume it can still authenticate non-interactive sudo." >&2
  fi
  return 1
}