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

# The guard must refuse a workstation deploy of the restricted policy before
# anything is staged, naming the console route, and must accept the console
# route itself. Where it needs the target's running policy, ssh is doubled with
# an explicit answer rather than reached.
source scripts/helpers/local-admin-sudo-guard.sh

guard_ssh_dir="$(mktemp -d)"
trap 'rm -rf "$guard_ssh_dir"' EXIT

mock_target_sudo_policy() {
  local answer="$1" marker="marked"
  mkdir -p "$guard_ssh_dir/$answer"
  # Record that the probe happened, so a guard that stops asking can be told
  # apart from one that asks and reads the answer.
  cat >"$guard_ssh_dir/$answer/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$marker' >>'$guard_ssh_dir/$answer/ssh.calls'
printf '%s\n' '$answer'
EOF
  make_test_executable "$guard_ssh_dir/$answer/ssh"
  printf '%s' "$guard_ssh_dir/$answer"
}

target_sudo_policy_probe_count() {
  local dir="$1"
  local file="$dir/ssh.calls"
  if [[ ! -f "$file" ]]; then
    printf '0\n'
    return 0
  fi
  grep -c . "$file" || true
}

restricted_deploy_config='{"localAdminSudo":"password-authenticated","localAdminSudoDeployRequiresPasswordlessSudo":false,"localAdminSudoDeployBlockedReason":"sudo policy under test cannot authenticate deploy"}'
bootstrap_deploy_config='{"localAdminSudo":"bootstrap-nopasswd","localAdminSudoDeployRequiresPasswordlessSudo":true,"localAdminSudoDeployBlockedReason":null}'

# A workstation deploy of the restricted policy must be refused: it reaches the
# target over SSH as an account with no passwordless grant, and the activation
# that would drop the grant also drops what its own post-activation steps need.
# The refusal must name the console route rather than only naming the problem.
restricted_guard_dir="$(mock_target_sudo_policy password-authenticated)"
restricted_guard_output="$(
  PATH="$restricted_guard_dir:$PATH" \
    target_host="local-admin@127.0.0.1" \
    console_mode="false" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && restricted_guard_status=0 || restricted_guard_status=$?
if [[ "$restricted_guard_status" -eq 0 ]] \
  || ! rg -Fq 'blocked: sudo policy under test cannot authenticate deploy' <<<"$restricted_guard_output" \
  || ! rg -Fq 'sudo ./scripts/deploy.sh --console --action test' <<<"$restricted_guard_output"; then
  echo "❌ The deploy sudo guard did not refuse a workstation deploy of the restricted policy with the console route."
  printf '%s\n' "$restricted_guard_output"
  exit 1
fi

# The console route is the supported implementation, not advice: with --console
# the flow runs as this machine's root identity, so the restricted policy is
# satisfied without any passwordless grant. Exercised by stubbing id rather than
# requiring the suite to run as root.
console_root_dir="$guard_ssh_dir/root-id"
mkdir -p "$console_root_dir"
cat >"$console_root_dir/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF
make_test_executable "$console_root_dir/id"
root_guard_output="$(
  PATH="$console_root_dir:$PATH" \
    target_host="local-admin@127.0.0.1" \
    console_mode="true" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && root_guard_status=0 || root_guard_status=$?
if [[ "$root_guard_status" -ne 0 ]] \
  || ! rg -Fq 'console deploy running as root on this host; downstream sudo needs no grant' \
    <<<"$root_guard_output"; then
  echo "❌ The console route (--console as root) was blocked by the sudo guard."
  printf '%s\n' "$root_guard_output"
  exit 1
fi

# --console must not be usable without root: without it the flow would fall back
# to reaching the target over SSH as the unprivileged local admin, which is
# exactly what the restricted policy forbids.
nonroot_guard_dir="$guard_ssh_dir/nonroot-id"
mkdir -p "$nonroot_guard_dir"
cat >"$nonroot_guard_dir/id" <<'EOF'
#!/usr/bin/env bash
printf '1000\n'
EOF
make_test_executable "$nonroot_guard_dir/id"
nonroot_guard_output="$(
  PATH="$nonroot_guard_dir:$PATH" \
    target_host="local-admin@127.0.0.1" \
    console_mode="true" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && nonroot_guard_status=0 || nonroot_guard_status=$?
if [[ "$nonroot_guard_status" -eq 0 ]] \
  || ! rg -Fq 'blocked: --console must run as root on this host' <<<"$nonroot_guard_output"; then
  echo "❌ A non-root --console deploy was accepted by the sudo guard."
  printf '%s\n' "$nonroot_guard_output"
  exit 1
fi

# A root workstation is not by itself authorization. Without --console the
# deploy still reaches the target over SSH as the local admin, so root must not
# become a blanket exemption for the restricted policy.
root_workstation_output="$(
  PATH="$console_root_dir:$(mock_target_sudo_policy password-authenticated):$PATH" \
    target_host="local-admin@127.0.0.1" \
    console_mode="false" \
    deploy_config_json="$restricted_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && root_workstation_status=0 || root_workstation_status=$?
if [[ "$root_workstation_status" -eq 0 ]] \
  || ! rg -Fq 'blocked: sudo policy under test cannot authenticate deploy' \
    <<<"$root_workstation_output"; then
  echo "❌ A root workstation deploy bypassed the restricted-policy refusal without --console."
  printf '%s\n' "$root_workstation_output"
  exit 1
fi

# Restoring the bootstrap policy from a workstation is refused once the host has
# actually activated the restricted one: the desired grant does not exist on the
# running host, so the deploy would stage and then fail on non-interactive sudo.
# The message must name the console route.
restore_guard_dir="$(mock_target_sudo_policy password-authenticated)"
restore_guard_output="$(
  PATH="$restore_guard_dir:$PATH" \
    target_host="local-admin@127.0.0.1" \
    console_mode="false" \
    deploy_config_json="$bootstrap_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && restore_guard_status=0 || restore_guard_status=$?
if [[ "$restore_guard_status" -eq 0 ]] \
  || ! rg -Fq 'is already running the password-authenticated policy' <<<"$restore_guard_output" \
  || ! rg -Fq 'sudo ./scripts/deploy.sh --console --action test' <<<"$restore_guard_output" \
  || [[ "$(target_sudo_policy_probe_count "$restore_guard_dir")" -lt 1 ]]; then
  echo "❌ A workstation restore of bootstrap-nopasswd against an already-restricted host was accepted or did not name the console route."
  printf '%s\n' "$restore_guard_output"
  exit 1
fi

# While the host still runs the bootstrap grant, the same workstation restore is
# the ordinary unattended path and must not be blocked.
bootstrap_restore_dir="$(mock_target_sudo_policy bootstrap-nopasswd)"
bootstrap_restore_output="$(
  PATH="$bootstrap_restore_dir:$PATH" \
    target_host="local-admin@127.0.0.1" \
    console_mode="false" \
    deploy_config_json="$bootstrap_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && bootstrap_restore_status=0 || bootstrap_restore_status=$?
if [[ "$bootstrap_restore_status" -ne 0 ]] \
  || ! rg -Fq 'local admin sudo policy=bootstrap-nopasswd' <<<"$bootstrap_restore_output"; then
  echo "❌ The ordinary unattended bootstrap-policy deploy was blocked."
  printf '%s\n' "$bootstrap_restore_output"
  exit 1
fi

# A target that cannot be asked (an older host with no policy generation) must
# not block the unattended deploy: its own SSH reachability decides that, and the
# bootstrap policy is the pre-change contract.
unreadable_guard_dir="$(mock_target_sudo_policy unreadable)"
unreadable_guard_output="$(
  PATH="$unreadable_guard_dir:$PATH" \
    target_host="local-admin@127.0.0.1" \
    console_mode="false" \
    deploy_config_json="$bootstrap_deploy_config" \
    enforce_local_admin_sudo_policy 2>&1
)" && unreadable_guard_status=0 || unreadable_guard_status=$?
if [[ "$unreadable_guard_status" -ne 0 ]] \
  || ! rg -Fq 'local admin sudo policy=bootstrap-nopasswd' <<<"$unreadable_guard_output"; then
  echo "❌ The unattended bootstrap deploy was blocked against an unreadable target policy."
  printf '%s\n' "$unreadable_guard_output"
  exit 1
fi

bootstrap_guard_output="$(
  console_mode="false" \
    deploy_config_json="$bootstrap_deploy_config"
  enforce_local_admin_sudo_policy
)"
require_json_equal "$bootstrap_guard_output" "local admin sudo policy=bootstrap-nopasswd" \
  "The deploy sudo guard must accept the bootstrap policy without blocking."

# A deploy archive predating this guard carries none of the policy fields and
# must not be blocked by their absence.
legacy_guard_output="$(
  console_mode="false" \
    deploy_config_json='{}'
  enforce_local_admin_sudo_policy
)"
require_json_equal "$legacy_guard_output" "local admin sudo policy=unknown" \
  "The deploy sudo guard must not block a deploy config without policy fields."

# deploy.sh must actually apply the guard before staging.
require_fixed scripts/deploy.sh 'enforce_local_admin_sudo_policy' \
  "deploy.sh must apply the local-admin sudo guard."

# The activation must record the policy it is running, or the guard cannot tell
# an unattended-capable host from an already-restricted one.
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
  'sudo \./scripts/deploy\.sh --console --action test\s*\n\s*sudo \./scripts/deploy\.sh --console --action switch' \
  "The restricted-policy console deploy must be documented as exact commands."

# The console route must be documented as the *only* transition: advertising a
# workstation transition would promise a deploy that cannot complete its own
# transaction, because the activation drops the grant its post-activation steps
# need.
require_match documentation/operations.md \
  'The transition is a \*\*console deploy\*\*, not a workstation deploy' \
  "The transition must be documented as a console deploy."

forbid_match documentation/operations.md \
  'Deploy that change \*\*from the workstation\*\*' \
  "Operations must not advertise the unimplementable workstation transition."

require_match documentation/operations.md \
  'is dropped from `nix\.settings\.trusted-users`' \
  "The sudo policy contract must state that Nix daemon trust is gated too."

require_match documentation/operations.md \
  'sudo nixos-rebuild switch --rollback' \
  "Emergency recovery under the restricted policy must be documented."

# --console must be wired end to end, not only in the guard: the flag has to
# reach deploy.sh's routing, the executor's local-target decision and the
# rebuild command, or the "implemented route" claim is false again.
require_fixed scripts/deploy.sh 'blocked: --console cannot be combined with --target' \
  "--console must refuse a remote target, which it cannot reach as root."
require_fixed scripts/deploy.sh 'blocked: --console only builds with --build-mode local' \
  "--console must refuse a remote or distributed build, which the restricted policy cannot run as the local admin."
require_fixed scripts/deploy.sh 'CONSOLE_MODE="$console_mode"' \
  "deploy.sh must pass console mode to the executor."
if [[ "${NIXHOMESERVER_SKIP_STATIC_ROUTING_ASSERT:-0}" != "1" ]]; then
require_fixed scripts/helpers/deploy-executor.sh \
  'if [[ "$CONSOLE_MODE" == "true" ]]; then' \
  "The executor must treat console mode as a local target, so no privileged step goes over SSH."
fi
require_fixed scripts/helpers/deploy-executor.sh \
  'blocked: --console deploys to this host as root' \
  "The executor must refuse console mode that is not actually running as root."
require_fixed scripts/helpers/deploy-command.sh \
  'local local_target="${7:-false}"' \
  "The rebuild command must be able to omit --target-host for a local-root console deploy."
require_fixed modules/Core_Modules/homepage/services.nix \
  'sudo ./scripts/deploy.sh --console --action test' \
  "The homepage admin guide must offer the implemented console route."

# Transaction-level coverage: the point of --console is that a deploy whose
# activation drops the passwordless grant can still finish, because every
# target step runs as root with no SSH hop. Exercise the executor's routing
# directly with a mocked target rather than asserting on the source shape.
executor_routing_dir="$(mktemp -d)"
mkdir -p "$executor_routing_dir/ssh" "$executor_routing_dir/root-id"
cat >"$executor_routing_dir/ssh/ssh" <<'EOF'
#!/usr/bin/env bash
# Any SSH hop in console mode is a routing bug: the target is this machine.
printf 'ssh was used in console mode: %s\n' "$*" >&2
exit 97
EOF
make_test_executable "$executor_routing_dir/ssh/ssh"
cat >"$executor_routing_dir/root-id/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF
make_test_executable "$executor_routing_dir/root-id/id"

executor_routing_check() {
  local console_mode="$1" build_locally="$2" target="$3" build="$4" expected="$5"
  local output

  # The probe prints the resolved route; a remote route exits 97 so that any
  # accidental ssh hop inside the real helper would also surface, but that exit
  # is the expected answer here rather than a failure.
  output="$(
    PATH="$executor_routing_dir/ssh:$executor_routing_dir/root-id:$PATH" \
    TARGET_HOST="$target" \
      BUILD_HOST="$build" \
      ACTION="test" \
      HOSTNAME_ARG="routing-probe" \
      DEBUG_MODE="false" \
      BUILD_LOCALLY="$build_locally" \
      CONSOLE_MODE="$console_mode" \
      BUILD_MODE="local" \
      LOCAL_BUILD_SLOTS="1" \
      REMOTE_BUILD_SLOTS="0" \
      LOCAL_BUILD_CORES="1" \
      REMOTE_BUILD_CORES="0" \
      HOST_PLATFORM="x86_64-linux" \
      BUILDER_SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRoutingProbeOnlyNotARealKey" \
      bash -c '
        # Source the real executor rather than restating target_is_local, so
        # this probe fails if the executor routing itself regresses.
        source scripts/helpers/deploy-executor.sh
        if target_is_local; then
          printf "local\n"
        else
          printf "remote\n"
          exit 97
        fi
      ' 2>&1
  )" || true
  require_json_equal "$output" "$expected" \
    "Console mode routing (CONSOLE_MODE=${console_mode}, BUILD_LOCALLY=${build_locally}, target != build host) must resolve to '${expected}'."
}

# A console deploy resolves to the local root path even when the target is
# named like a remote host, which is what makes the post-activation sudo calls
# root.
executor_routing_check "true" "false" "local-admin@198.51.100.7" "build-box@198.51.100.9" "local"
executor_routing_check "true" "true" "local-admin@198.51.100.7" "build-box@198.51.100.9" "local"
# Without --console, a target that is not the build host still goes over SSH as
# the local admin — which is exactly the authorization the restricted policy
# removes, so root on the workstation must not change the routing.
executor_routing_check "false" "false" "local-admin@198.51.100.7" "build-box@198.51.100.9" "remote"
executor_routing_check "false" "true" "local-admin@198.51.100.7" "build-box@198.51.100.9" "remote"
# The pre-existing rule is untouched: a non-console deploy whose target IS the
# build host already runs locally, and must keep doing so.
executor_routing_check "false" "false" "local-admin@198.51.100.7" "local-admin@198.51.100.7" "local"
rm -rf "$executor_routing_dir"

# The rebuild command must omit --target-host in console mode: leaving it in
# would send nixos-rebuild back over SSH as the unprivileged local admin.
source scripts/helpers/deploy-command.sh
console_rebuild_command=()
build_nixos_rebuild_command console_rebuild_command \
  build "example-server" "true" "console" "" "true"
if printf '%s\n' "${console_rebuild_command[*]}" | rg -q -- '--target-host'; then
  echo "❌ The console rebuild command still passes --target-host, which sends the build over SSH as the local admin."
  printf '%s\n' "${console_rebuild_command[*]}"
  exit 1
fi

workstation_rebuild_command=()
build_nixos_rebuild_command workstation_rebuild_command \
  build "example-server" "true" "local-admin@198.51.100.7" "" "false"
if ! printf '%s\n' "${workstation_rebuild_command[*]}" | rg -q -- '--target-host local-admin@198\.51\.100\.7'; then
  echo "❌ A non-console rebuild lost its --target-host, so an ordinary workstation deploy would build on the wrong machine."
  printf '%s\n' "${workstation_rebuild_command[*]}"
  exit 1
fi

echo "✅ Local-admin sudo policy selection and recovery contract passed."