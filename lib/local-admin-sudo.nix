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
#                           password, the wheel group no longer carries
#                           NOPASSWD, and the local admin is no longer a
#                           trusted Nix user. Recovery stays available at the
#                           physical or virtual console only, because SSH
#                           password and keyboard-interactive authentication
#                           stay disabled. Deploying then requires console-
#                           driven operation, and after the transition even
#                           store and profile writes require root.
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
    # Trusted Nix daemon membership is root-equivalent in its own right: the
    # official nix.conf manual states that trusted users may import unsigned
    # NARs and act on the store, which is essentially root access. The local
    # admin needs it for unattended deploys and store maintenance, so the
    # bootstrap contract keeps it and the restricted policy removes it.
    trustLocalAdmin = true;
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
    # Drop the equivalent daemon trust rather than leaving the account a
    # passwordless root-equivalent path to the Nix store after sudo is gated.
    trustLocalAdmin = false;
    deployBlockedReason = "vars.identity.localAdminSudo is \"${policy}\", so the local admin has no passwordless sudo. The guarded deploy performs non-interactive sudo on this host and cannot authenticate under this policy. Restore \"bootstrap-nopasswd\" in vars.nix and redeploy from the workstation (the currently running host still holds the bootstrap grant until the activation lands), or keep this policy and run deploys from the server console as the local admin with the recovery password entered interactively: sudo ./scripts/deploy.sh --action test, then sudo ./scripts/deploy.sh --action switch. Both console commands enter the reconciled local-console password once at the sudo prompt and then serve sudo non-interactively for the whole deploy.";
  }