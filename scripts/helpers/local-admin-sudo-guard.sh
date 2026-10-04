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
# The preflight is about what the target host can actually authenticate, not
# about what the local checkout asks for. A desired policy of
# "password-authenticated" therefore has exactly one supported route:
#
#   sudo ./scripts/deploy.sh --console --action test
#   sudo ./scripts/deploy.sh --console --action switch
#
# from the server console. That is a real route, not advice: --console runs the
# whole guarded flow as this machine's root identity with no SSH connection to
# the target, so every downstream `sudo` is already root. It is also the only
# way to *transition* onto the restricted policy: an activation that removes
# the passwordless grant also removes the authorization its own post-activation
# health gates, stamp write and lock release would need, so a remote transition
# would break halfway through its own transaction.
#
# Sourced by scripts/deploy.sh. Expects `deploy_config_json` to hold the JSON
# object produced by nix_flake_json, `target_host` the resolved target, and
# `console_mode` to be "true" for a --console deploy. Prints the configured
# policy and refuses, before anything is staged, when this deploy cannot
# authenticate the target's non-interactive sudo contract.

# Written by activation from the running generation's policy
# (modules/Core_Modules/base-system/default.nix), so it describes the host
# rather than the checkout being deployed.
local_admin_sudo_policy_state_file="/etc/nixhomeserver/local-admin-sudo-policy"

console_route_hint="run it from the server console as the local admin, where one interactive sudo prompt covers the whole deploy:
  sudo ./scripts/deploy.sh --console --action test
  sudo ./scripts/deploy.sh --console --action switch"

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
  local policy needs_passwordless blocked_reason target_policy target
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
  target="${target_host:-}"

  # The console route: the guarded flow runs as root on the target itself, so
  # every downstream `sudo` succeeds without a passwordless grant. This is the
  # only route under the restricted policy, and the only supported way to
  # transition onto it.
  if [[ "${console_mode:-false}" == "true" ]]; then
    if [[ "$(id -u)" == "0" ]]; then
      echo "local admin sudo policy=${policy} (console deploy running as root on this host; downstream sudo needs no grant)"
      return 0
    fi
    # A dry run stages nothing, so report the root requirement instead of
    # refusing: the operator needs to inspect the resolved console command
    # before authenticating.
    if [[ "${DEPLOY_DRY_RUN:-}" == "1" ]]; then
      echo "local admin sudo policy=${policy} (console dry run; the real deploy must run as root on this host, downstream sudo then needs no grant)"
      return 0
    fi
    echo "blocked: --console must run as root on this host; ${console_route_hint}" >&2
    return 1
  fi

  if [[ "$needs_passwordless" == "true" ]]; then
    # The desired grant is the unattended one, but it only helps while the
    # *running* host still has it: an activation that drops it also drops the
    # authorization this deploy's post-activation gates need. So a workstation
    # deploy of the bootstrap policy against a host that already activated the
    # restricted one is refused up front, and the console route is named.
    #
    # A dry run stages nothing and reaches nothing, so it must not open a
    # network connection to the target; it reports the desired policy only.
    if [[ "${DEPLOY_DRY_RUN:-}" != "1" ]]; then
      target_policy="$(read_target_local_admin_sudo_policy "$target")"
      if [[ "$target_policy" == "password-authenticated" ]]; then
        echo "blocked: ${target:-the target host} is already running the password-authenticated policy, which grants this deploy no passwordless sudo; ${console_route_hint}" >&2
        return 1
      fi
    fi
    echo "local admin sudo policy=${policy}"
    return 0
  fi

  # A restricted desired policy cannot be deployed from anywhere but the
  # console: this deploy reaches the target over SSH as the local admin, whose
  # restricted policy has no passwordless grant, and the activation that would
  # grant one is exactly what this deploy cannot finish. The console route is
  # printed here rather than relied on from the configured reason, so the
  # operator always gets the route even if that text is trimmed or reworded.
  echo "blocked: ${blocked_reason}" >&2
  echo "blocked: the only supported route for this policy is the console; ${console_route_hint}" >&2
  return 1
}