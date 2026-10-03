#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"

policy_json_for() {
  nix eval --json --impure --expr "
    let
      policy = import ./lib/local-admin-sudo.nix {
        localAdminUser = \"local-admin\";
        policy = \"$1\";
      };
    in {
      policy = policy.policy;
      deployRequiresPasswordlessSudo = policy.deployRequiresPasswordlessSudo;
      recoveryViaConsoleCredential = policy.recoveryViaConsoleCredential;
      sudoUsesRecoveryCredential = policy.sudoUsesRecoveryCredential;
      wheelNeedsPassword = policy.wheelNeedsPassword;
      deployBlockedReason = policy.deployBlockedReason;
      ruleUsers = builtins.map (rule: rule.users) policy.extraRules;
      ruleCommands = builtins.map
        (rule: builtins.concatMap (command: [ command.command ]) rule.commands)
        policy.extraRules;
      ruleOptions = builtins.map
        (rule: builtins.concatMap (command: command.options) rule.commands)
        policy.extraRules;
    }
  "
}

bootstrap_policy="$(policy_json_for bootstrap-nopasswd)"

if ! jq -e '
  .policy == "bootstrap-nopasswd"
  and .deployRequiresPasswordlessSudo
  and .recoveryViaConsoleCredential
  and (.sudoUsesRecoveryCredential | not)
  and (.wheelNeedsPassword | not)
  and .deployBlockedReason == null
  and .ruleUsers == [["local-admin"]]
  and .ruleCommands == [["ALL"]]
  and .ruleOptions == [["NOPASSWD"]]
' <<<"$bootstrap_policy" >/dev/null; then
  echo "❌ The bootstrap-nopasswd policy must grant the deploy root-equivalent sudo contract."
  jq . <<<"$bootstrap_policy"
  exit 1
fi

restricted_policy="$(policy_json_for password-authenticated)"

# The restricted policy must grant no rule at all and must not leave the wheel
# group with a default passwordless ALL grant, which would silently reintroduce
# root for the same account.
if ! jq -e '
  .policy == "password-authenticated"
  and (.deployRequiresPasswordlessSudo | not)
  and .recoveryViaConsoleCredential
  and .sudoUsesRecoveryCredential
  and .wheelNeedsPassword
  and (.deployBlockedReason | contains("no passwordless sudo"))
  and .ruleUsers == []
  and .ruleCommands == []
  and .ruleOptions == []
' <<<"$restricted_policy" >/dev/null; then
  echo "❌ The password-authenticated policy still grants a passwordless sudo rule."
  jq . <<<"$restricted_policy"
  exit 1
fi

unsupported_policy_log="$(capture_eval_failure '
  in import ./lib/local-admin-sudo.nix {
    localAdminUser = "local-admin";
    policy = "trust-me";
  }
')"
if ! rg -Fq 'identity.localAdminSudo must be one of: bootstrap-nopasswd, password-authenticated' \
  <<<"$unsupported_policy_log"; then
  echo "❌ An unsupported local-admin sudo policy failed without the actionable message."
  printf '%s\n' "$unsupported_policy_log"
  exit 1
fi

invalid_sudo_setting_log="$(capture_eval_failure '
  base = import ./vars.nix { inherit lib; };
  invalid = base // { localAdminSudo = "trust-me"; };
in import ./lib/validate-host-settings.nix {
  inherit lib;
  hostName = invalid.hostname;
  settings = invalid;
}
')"
if ! rg -Fq 'identity.localAdminSudo must be "bootstrap-nopasswd" or "password-authenticated"' \
  <<<"$invalid_sudo_setting_log"; then
  echo "❌ A mistyped localAdminSudo bypassed host-settings validation."
  printf '%s\n' "$invalid_sudo_setting_log"
  exit 1
fi

runtime_sudo_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr hostName f.nixosConfigurations).config;
  settings = builtins.getAttr hostName f.lib.nixhomeserverSettings;
in {
  wheelNeedsPassword = cfg.security.sudo.wheelNeedsPassword;
  localAdminRuleUsers = builtins.concatMap (rule: rule.users) cfg.security.sudo.extraRules;
  localAdminRuleCommands = builtins.concatMap
    (rule: builtins.concatMap (command: [ command.command ]) rule.commands)
    cfg.security.sudo.extraRules;
  configuredPolicy = settings.localAdminSudo;
  policyMatchesConfiguration = settings.localAdminSudoPolicy.policy == settings.localAdminSudo;
  deployRequiresPasswordlessSudo = settings.localAdminSudoPolicy.deployRequiresPasswordlessSudo;
  wheelGrantNeedsPassword = settings.localAdminSudoPolicy.wheelNeedsPassword;
  sshPasswordAuthentication = cfg.services.openssh.settings.PasswordAuthentication;
  sshKbdInteractiveAuthentication = cfg.services.openssh.settings.KbdInteractiveAuthentication;
  rootPermitRootLogin = cfg.services.openssh.settings.PermitRootLogin;
}
')"

# The evaluated host must render the policy that vars.nix selects, and the wheel
# setting must agree with the derived policy rather than drifting from it.
if ! jq -e --arg admin "$(nix_flake_var 'vars.localAdminUser')" '
  .configuredPolicy == "bootstrap-nopasswd"
  and .policyMatchesConfiguration
  and .wheelNeedsPassword == .wheelGrantNeedsPassword
  and (.localAdminRuleUsers | index($admin) != null)
  and (.localAdminRuleCommands | index("ALL") != null)
  and .deployRequiresPasswordlessSudo
' <<<"$runtime_sudo_json" >/dev/null; then
  echo "❌ The rendered sudoers policy does not follow vars.identity.localAdminSudo."
  jq . <<<"$runtime_sudo_json"
  exit 1
fi

# SSH password login must stay disabled: the reconciled console recovery
# credential must never become a network-reachable sudo path.
if ! jq -e '
  .sshPasswordAuthentication == false
  and .sshKbdInteractiveAuthentication == false
  and .rootPermitRootLogin == "no"
' <<<"$runtime_sudo_json" >/dev/null; then
  echo "❌ Local-console sudo recovery became reachable over SSH."
  jq . <<<"$runtime_sudo_json"
  exit 1
fi

# deploy.sh must refuse a restricted-policy deploy before anything is staged,
# and must pass the bootstrap policy through.
source scripts/helpers/local-admin-sudo-guard.sh
restricted_guard_output="$(
  deploy_config_json='{"localAdminSudo":"password-authenticated","localAdminSudoDeployRequiresPasswordlessSudo":false,"localAdminSudoDeployBlockedReason":"sudo policy under test cannot authenticate deploy"}'
  enforce_local_admin_sudo_policy 2>&1
)" && restricted_guard_status=0 || restricted_guard_status=$?
if [[ "$restricted_guard_status" -eq 0 ]] \
  || ! rg -Fq 'blocked: sudo policy under test cannot authenticate deploy' <<<"$restricted_guard_output"; then
  echo "❌ The deploy sudo guard did not refuse a policy that cannot authenticate deploy sudo."
  printf '%s\n' "$restricted_guard_output"
  exit 1
fi

bootstrap_guard_output="$(
  deploy_config_json='{"localAdminSudo":"bootstrap-nopasswd","localAdminSudoDeployRequiresPasswordlessSudo":true,"localAdminSudoDeployBlockedReason":null}'
  enforce_local_admin_sudo_policy
)"
require_json_equal "$bootstrap_guard_output" "local admin sudo policy=bootstrap-nopasswd" \
  "The deploy sudo guard must accept the bootstrap policy without blocking."

# A deploy archive predating this guard carries none of the policy fields and
# must not be blocked by their absence.
legacy_guard_output="$(
  deploy_config_json='{}'
  enforce_local_admin_sudo_policy
)"
require_json_equal "$legacy_guard_output" "local admin sudo policy=unknown" \
  "The deploy sudo guard must not block a deploy config without policy fields."

# deploy.sh must actually apply the guard before staging.
require_fixed scripts/deploy.sh 'enforce_local_admin_sudo_policy' \
  "deploy.sh must apply the local-admin sudo guard."

require_fixed modules/Core_Modules/homepage/services.nix \
  'Bypasses every guarded deploy check and changes the boot profile' \
  "The emergency rollback guide must state that it bypasses guarded deploy checks."

require_fixed documentation/operations.md '## Local-Admin Sudo Policy' \
  "Operations must document the selectable local-admin sudo policy."

require_match documentation/operations.md \
  'password and keyboard-interactive authentication remain disabled in both sudo\s+policies' \
  "The sudo policy contract must state that console recovery is not a network path."

echo "✅ Local-admin sudo policy selection and recovery contract passed."