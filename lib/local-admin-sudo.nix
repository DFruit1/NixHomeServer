# Local administrator sudo policy.
#
# The guarded deploy architecture invokes `sudo` non-interactively on the
# target host (scripts/helpers/deploy-executor.sh), including `sudo /bin/sh -c`
# for activation scripts. Any sudoers rule that keeps that flow working is
# therefore root-equivalent, so restricting the *command* list cannot create a
# real boundary. What this policy controls instead is the exposure the operator
# can declaratively turn off, plus the recovery consequences of doing so:
#
#   "bootstrap-nopasswd"    The local admin is a fully trusted root-equivalent
#                           operator: NOPASSWD ALL, wheel passwordless. This is
#                           the only mode the unattended deploy flow supports.
#   "password-authenticated" Post-bootstrap hardening: the local admin keeps
#                           sudo but must present the reconciled local-console
#                           password, and the wheel group no longer carries
#                           NOPASSWD. Recovery stays available at the physical
#                           or virtual console only, because SSH password and
#                           keyboard-interactive authentication stay disabled.
#                           Deploying then requires console-driven operation.
{ localAdminUser, policy }:

let
  supportedPolicies = [
    "bootstrap-nopasswd"
    "password-authenticated"
  ];
in
if !builtins.elem policy supportedPolicies then
  throw "identity.localAdminSudo must be one of: ${builtins.concatStringsSep ", " supportedPolicies}, got ${builtins.toJSON policy}"
else if policy == "bootstrap-nopasswd" then
  {
    policy = policy;
    # The guarded deploy and bootstrap scripts invoke ordinary sudo for
    # nixos-rebuild, systemd status and detached switch activation. This broad
    # contract is accepted admin-policy exposure, not a mechanically fixable
    # boundary; the operation wrappers do not contain it.
    wheelNeedsPassword = false;
    extraRules = [
      {
        users = [ localAdminUser ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
    # Set false once the local admin is no longer root-equivalent by design.
    deployRequiresPasswordlessSudo = true;
    # sudo is authorized by the reconciled local-console password.
    sudoUsesRecoveryCredential = false;
    # Console login with the reconciled recovery password remains the
    # authenticated recovery path in both modes.
    recoveryViaConsoleCredential = true;
    deployBlockedReason = null;
  }
else
  {
    policy = policy;
    # No rule is granted for the local admin, and the wheel group must not
    # reintroduce a passwordless ALL grant by default.
    wheelNeedsPassword = true;
    extraRules = [ ];
    deployRequiresPasswordlessSudo = false;
    sudoUsesRecoveryCredential = true;
    recoveryViaConsoleCredential = true;
    deployBlockedReason = "vars.identity.localAdminSudo is \"${policy}\", so the local admin has no passwordless sudo. The guarded deploy performs non-interactive sudo on this host and cannot authenticate under this policy. Restore \"bootstrap-nopasswd\", or run deploys from the server console as the local admin.";
  }