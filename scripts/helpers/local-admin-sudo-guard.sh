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
# Sourced by scripts/deploy.sh. Expects `deploy_config_json` to hold the JSON
# object produced by nix_flake_json. Prints the configured policy and refuses,
# before anything is staged, when the policy cannot authenticate this host's
# non-interactive sudo contract.

enforce_local_admin_sudo_policy() {
  local policy needs_passwordless blocked_reason
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
  if [[ "$needs_passwordless" != "true" && -n "$blocked_reason" ]]; then
    echo "blocked: ${blocked_reason}" >&2
    return 1
  fi
  echo "local admin sudo policy=${policy}"
}