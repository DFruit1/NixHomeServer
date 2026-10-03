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
      trustLocalAdmin = policy.trustLocalAdmin;
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

# Every rule the selected policy grants to the local admin must be a real
# passwordless root grant under bootstrap, and no rule at all otherwise. Kept
# separate from the evaluated host below because that evaluation also carries
# unrelated nixpkgs defaults (root SETENV, the homepage helper grants).
bootstrap_policy="$(policy_json_for bootstrap-nopasswd)"

if ! jq -e '
  .policy == "bootstrap-nopasswd"
  and .deployRequiresPasswordlessSudo
  and .recoveryViaConsoleCredential
  and (.sudoUsesRecoveryCredential | not)
  and (.wheelNeedsPassword | not)
  and .trustLocalAdmin
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
  and (.trustLocalAdmin | not)
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
  trustedUsers = cfg.nix.settings.trusted-users;
  policyStateFile = cfg.environment.etc."nixhomeserver/local-admin-sudo-policy".text;
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
  and (.trustedUsers | index($admin) != null)
  and .policyStateFile == "bootstrap-nopasswd\n"
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

# Evaluate the real host with the restricted policy selected. Gating sudo alone
# would leave the local admin a passwordless root-equivalent path through Nix
# daemon trust, so assert on the evaluated restricted host that neither sudo nor
# daemon trust remains for that account.
restricted_host_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  base = builtins.getAttr hostName f.lib.nixhomeserverSettings;
  settings = import ./lib/validate-host-settings.nix {
    inherit lib;
    hostName = base.hostname;
    settings = base // { identity = base.identity // { localAdminSudo = "password-authenticated"; }; };
  };
  vars = settings // (import ./lib/derive-vars.nix { inherit lib settings; });
  pkgs = f.inputs.nixpkgs.legacyPackages.${vars.hostPlatform};
  packages = import ./flake/packages.nix {
    inherit lib;
    pkgsUnstable = f.inputs.nixpkgs-unstable.legacyPackages.${vars.hostPlatform};
    crane = f.inputs.crane;
  };
  host = (import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs;
    system = vars.hostPlatform;
    appPackages = packages.appPackages;
  }).nixosConfigurations.${vars.hostname};
  cfg = host.config;
  admin = vars.localAdminUser;
  # Rules that would let the local admin obtain root without a password, by any
  # route: a direct user grant, or a group grant for a group the admin is in.
  # nixpkgs always adds a root ALL entry and a wheel entry, so only those two
  # can grant the admin anything; the options decide whether it is passwordless.
  adminAllRules = builtins.filter
    (rule: builtins.elem admin rule.users || builtins.any (g: builtins.elem g rule.groups) [ "wheel" ])
    cfg.security.sudo.extraRules;
in {
  wheelNeedsPassword = cfg.security.sudo.wheelNeedsPassword;
  adminIsWheel = builtins.elem "wheel" (cfg.users.users.${admin}.extraGroups or [ ]);
  adminAllRuleOptions = builtins.concatMap (rule: rule.commands) adminAllRules;
  # A single NOPASSWD ALL command entry is the passwordless root grant; options
  # are per command, so match them together rather than per rule.
  adminPasswordlessAll = builtins.any
    (command: builtins.elem "NOPASSWD" command.options && command.command == "ALL")
    (builtins.concatMap (rule: rule.commands) adminAllRules);
  trustedUsers = cfg.nix.settings.trusted-users;
  policyStateFile = cfg.environment.etc."nixhomeserver/local-admin-sudo-policy".text;
  deployRequiresPasswordlessSudo = vars.localAdminSudoPolicy.deployRequiresPasswordlessSudo;
  sshPasswordAuthentication = cfg.services.openssh.settings.PasswordAuthentication;
  rootPermitRootLogin = cfg.services.openssh.settings.PermitRootLogin;
}
')"

# Under the restricted policy the local admin must hold no passwordless ALL by
# any route — directly or through the wheel group — and must not be a trusted
# Nix user, which is root-equivalent on its own.
if ! jq -e --arg admin "$(nix_flake_var 'vars.localAdminUser')" '
  .wheelNeedsPassword
  and .adminIsWheel
  and (.deployRequiresPasswordlessSudo | not)
  and (.adminPasswordlessAll | not)
  and (.trustedUsers | index($admin) == null)
  and .policyStateFile == "password-authenticated\n"
  and .sshPasswordAuthentication == false
  and .rootPermitRootLogin == "no"
' <<<"$restricted_host_json" >/dev/null; then
  echo "❌ The restricted host still gives the local admin a passwordless root-equivalent grant (sudo or Nix daemon trust)."
  jq . <<<"$restricted_host_json"
  exit 1
fi

# The bootstrap host, by contrast, must still carry the passwordless grant and
# the daemon trust the unattended deploy flow depends on.
if ! jq -e --arg admin "$(nix_flake_var 'vars.localAdminUser')" '
  (.wheelNeedsPassword | not)
  and .deployRequiresPasswordlessSudo
  and (.trustedUsers | index($admin) != null)
' <<<"$runtime_sudo_json" >/dev/null; then
  echo "❌ The bootstrap host lost the passwordless sudo grant or Nix daemon trust the deploy flow needs."
  jq . <<<"$runtime_sudo_json"
  exit 1
fi

# deploy.sh must refuse a restricted-policy deploy before anything is staged
# when the target has already activated that policy, and must pass the
# bootstrap policy through. The guard asks the target which policy it is
# running, so ssh is doubled with an explicit answer rather than reached.
source scripts/helpers/local-admin-sudo-guard.sh

guard_ssh_dir="$(mktemp -d)"
trap 'rm -rf "$guard_ssh_dir"' EXIT

mock_target_sudo_policy() {
  local answer="$1"
  mkdir -p "$guard_ssh_dir/$answer"
  cat >"$guard_ssh_dir/$answer/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$answer'
EOF
  make_test_executable "$guard_ssh_dir/$answer/ssh"
  printf '%s' "$guard_ssh_dir/$answer"
}

restricted_deploy_config='{"localAdminSudo":"password-authenticated","localAdminSudoDeployRequiresPasswordlessSudo":false,"localAdminSudoDeployBlockedReason":"sudo policy under test cannot authenticate deploy"}'

# An already-restricted target must be refused, with the console route in the
# message.
restricted_guard_output="$(
  PATH="$(mock_target_sudo_policy password-authenticated):$PATH" \
    target_host="local-admin@127.0.0.1" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && restricted_guard_status=0 || restricted_guard_status=$?
if [[ "$restricted_guard_status" -eq 0 ]] \
  || ! rg -Fq 'blocked: sudo policy under test cannot authenticate deploy' <<<"$restricted_guard_output"; then
  echo "❌ The deploy sudo guard did not refuse an already-restricted target."
  printf '%s\n' "$restricted_guard_output"
  exit 1
fi

# The transition deploy must be allowed: the host being replaced still carries
# the bootstrap grant, and it only disappears when the activation lands.
transition_guard_output="$(
  PATH="$(mock_target_sudo_policy bootstrap-nopasswd):$PATH" \
    target_host="local-admin@127.0.0.1" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && transition_guard_status=0 || transition_guard_status=$?
if [[ "$transition_guard_status" -ne 0 ]] \
  || ! rg -Fq 'target still runs bootstrap-nopasswd; this activation removes unattended passwordless sudo from local-admin@127.0.0.1' \
    <<<"$transition_guard_output"; then
  echo "❌ The deploy sudo guard blocked the documented bootstrap-to-restricted transition deploy."
  printf '%s\n' "$transition_guard_output"
  exit 1
fi

# An unreadable target must not be assumed able to authenticate sudo: fail
# closed rather than stage a deploy that breaks midway.
unreadable_guard_output="$(
  PATH="$(mock_target_sudo_policy unreadable):$PATH" \
    target_host="local-admin@127.0.0.1" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && unreadable_guard_status=0 || unreadable_guard_status=$?
if [[ "$unreadable_guard_status" -eq 0 ]] \
  || ! rg -Fq 'refusing to assume it can still authenticate non-interactive sudo' \
    <<<"$unreadable_guard_output"; then
  echo "❌ The deploy sudo guard assumed an unreadable target could still authenticate non-interactive sudo."
  printf '%s\n' "$unreadable_guard_output"
  exit 1
fi

# The console route: a deploy already running as root holds the authorization
# the guarded flow needs, so its downstream sudo needs no grant. Exercised by
# stubbing id rather than requiring the suite to run as root.
guard_id_dir="$guard_ssh_dir/root"
mkdir -p "$guard_id_dir"
cat >"$guard_id_dir/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF
make_test_executable "$guard_id_dir/id"
root_guard_output="$(
  PATH="$guard_id_dir:$(mock_target_sudo_policy password-authenticated):$PATH" \
    target_host="local-admin@127.0.0.1" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && root_guard_status=0 || root_guard_status=$?
if [[ "$root_guard_status" -ne 0 ]] \
  || ! rg -Fq 'deploy is running as root on local-admin@127.0.0.1; downstream sudo needs no grant' \
    <<<"$root_guard_output"; then
  echo "❌ The console route (deploy running as root) was blocked by the sudo guard."
  printf '%s\n' "$root_guard_output"
  exit 1
fi

# A non-root caller against an already-restricted target stays blocked, so the
# root exemption above cannot become a blanket bypass.
nonroot_guard_dir="$guard_ssh_dir/nonroot"
mkdir -p "$nonroot_guard_dir"
cat >"$nonroot_guard_dir/id" <<'EOF'
#!/usr/bin/env bash
printf '1000\n'
EOF
make_test_executable "$nonroot_guard_dir/id"
nonroot_guard_output="$(
  PATH="$nonroot_guard_dir:$(mock_target_sudo_policy password-authenticated):$PATH" \
    target_host="local-admin@127.0.0.1" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && nonroot_guard_status=0 || nonroot_guard_status=$?
if [[ "$nonroot_guard_status" -eq 0 ]] \
  || ! rg -Fq 'blocked: sudo policy under test cannot authenticate deploy' \
    <<<"$nonroot_guard_output"; then
  echo "❌ A non-root deploy against an already-restricted target was not blocked."
  printf '%s\n' "$nonroot_guard_output"
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

# The activation must record the policy it is running, or the guard has no way
# to tell a transition-capable target from an already-restricted one.
require_fixed modules/Core_Modules/base-system/default.nix \
  'environment.etc."nixhomeserver/local-admin-sudo-policy"' \
  "The running sudo policy must be recorded on the host for the deploy preflight."
require_fixed scripts/helpers/local-admin-sudo-guard.sh \
  'local_admin_sudo_policy_state_file="/etc/nixhomeserver/local-admin-sudo-policy"' \
  "The deploy preflight must read the policy the target host is actually running."

# The policy fields must not be gated behind the resolved target: with an
# explicit --target the target attrs are omitted, and a restricted policy would
# otherwise be invisible to the guard, which defaults to needs_passwordless and
# would let the host be staged only to fail midway on non-interactive sudo.
# Require the fields to sit inside the always-emitted attrsets, outside any
# NIXHOMESERVER_DEPLOY_NEED_TARGET block.
deploy_policy_block="$(awk '
  /^  nix_flake_json/ { in_block = 1 }
  in_block && /^'"'"'\)/ { in_block = 0 }
  in_block { print }
' scripts/deploy.sh)"
for policy_field in \
  'localAdminSudo = vars.localAdminSudo;' \
  'localAdminSudoDeployRequiresPasswordlessSudo = vars.localAdminSudoPolicy.deployRequiresPasswordlessSudo;' \
  'localAdminSudoDeployBlockedReason = vars.localAdminSudoPolicy.deployBlockedReason;'; do
  if [[ "$(grep -Fxc "    $policy_field" <<<"$deploy_policy_block")" -ne 1 ]]; then
    echo "❌ The deploy config must emit the local-admin sudo policy unconditionally, not only when the target is resolved: ${policy_field}"
    printf '%s\n' "$deploy_policy_block"
    exit 1
  fi
done

# Behavioural check: an explicit --target run must still carry the policy
# through to the guard.
target_guard_output="$(
  DEPLOY_DRY_RUN=1 bash scripts/deploy.sh --target "local-admin@127.0.0.1" --action test 2>&1
)" && target_guard_status=0 || target_guard_status=$?
if [[ "$target_guard_status" -ne 0 ]] \
  || ! rg -Fq "local admin sudo policy=bootstrap-nopasswd" <<<"$target_guard_output"; then
  echo "❌ An explicit --target deploy did not evaluate and report the sudo policy."
  printf '%s\n' "$target_guard_output"
  exit 1
fi

# vars.nix is merge=ours and never updated from upstream, so an existing host's
# file predates identity.localAdminSudo. It must still evaluate, defaulting to
# the pre-change behaviour, rather than failing with a bare missing-attribute.
legacy_vars_json="$(nix eval --json --impure --expr "
  let
    lib = (import <nixpkgs> {}).lib;
    base = import ./vars.nix { inherit lib; };
    legacyIdentity = builtins.removeAttrs base.identity [ \"localAdminSudo\" ];
    legacy = base // { identity = legacyIdentity; };
  in
    (import ./lib/derive-vars.nix {
      inherit lib;
      settings = legacy;
    }).localAdminSudoPolicy
" 2>/dev/null || true)"
if ! jq -e '
  .policy == "bootstrap-nopasswd"
  and .deployRequiresPasswordlessSudo
  and .recoveryViaConsoleCredential
' <<<"$legacy_vars_json" >/dev/null 2>&1; then
  echo "❌ A vars.nix without identity.localAdminSudo must still evaluate with the pre-change policy."
  printf '%s\n' "$legacy_vars_json"
  exit 1
fi

require_fixed modules/Core_Modules/homepage/services.nix \
  'Bypasses every guarded deploy check and changes the boot profile' \
  "The emergency rollback guide must state that it bypasses guarded deploy checks."

require_fixed documentation/operations.md '## Local-Admin Sudo Policy' \
  "Operations must document the selectable local-admin sudo policy."

require_match documentation/operations.md \
  'password and keyboard-interactive authentication remain disabled in both sudo\s+policies' \
  "The sudo policy contract must state that console recovery is not a network path."

# The transition and console route must be documented with concrete commands,
# not just described: an operator must be able to harden the account and still
# deploy and recover without guessing.
require_match documentation/operations.md \
  'sudo \./scripts/deploy\.sh --action test\s*\n\s*sudo \./scripts/deploy\.sh --action switch' \
  "The restricted-policy console deploy must be documented as exact commands."

require_match documentation/operations.md \
  'is dropped from `nix\.settings\.trusted-users`' \
  "The sudo policy contract must state that Nix daemon trust is gated too."

require_match documentation/operations.md \
  'sudo nixos-rebuild switch --rollback' \
  "Emergency recovery under the restricted policy must be documented."

echo "✅ Local-admin sudo policy selection and recovery contract passed."