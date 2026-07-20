# Kanidm Guide

The old custom helper package named `kanidm-admin` was archived and removed
from active deployment. That package is not the Kanidm operator account: an
installation may still choose `kanidm-admin` as the value of
`identity.adminUser`. Active procedures use the native `kanidm` CLI and the
homepage "For Admins" page for configuration-aware commands.

Use this as the operator guide for:
- checking people and groups during onboarding
- granting/removing app access through Kanidm group membership
- issuing short-lived password-reset tokens for first sign-in
- post-login access troubleshooting
- Vaultwarden self-signup handoff coordination

Guarded deploys, service health, and DNS checks live in [Operations](./operations.md).

## Important Note

The homepage shows the groups declared by the evaluated Nix configuration and the signed-in operator's own group claims. It does not query another person's live memberships. Verify a target person with the native `kanidm` CLI before changing access; the generated commands provide configuration-aware context, not a replacement for that check.

## Conventions

- Placeholders such as `<USER>`, `<GROUP>`, and `<EMAIL>` are examples.
- Use the execution location shown beside each homepage command. Repository commands run from the repository checkout; service and Kanidm commands run on the server unless stated otherwise.
- References to the archived `kanidm-admin` helper mean the old package, never
  the account configured by `identity.adminUser`.

## First Operator Credential And Recovery

Declarative provisioning creates the dedicated operator person and delegated
group memberships, but it deliberately does not place a password or reset URL
in the Nix store. On the server, inspect the live credential state first:

```bash
sudo kanidm-operator-bootstrap status
```

For a new operator with no credential, issue a one-hour reset URL:

```bash
sudo kanidm-operator-bootstrap issue
```

The URL is printed once and is an active secret. Open it on a trusted device,
set the operator credential, enroll MFA, and do not copy it into chat, tickets,
or shell transcripts. The helper uses the root-only managed `idm_admin`
credential internally; do not use `idm_admin` for day-to-day administration.

After completing the reset, establish and verify the delegated operator's own
native CLI session:

```bash
kanidm login -D <identity.adminUser>
kanidm self whoami
```

If an existing operator intentionally needs account recovery, confirm the
current state and require the explicit recovery flag:

```bash
sudo kanidm-operator-bootstrap status
sudo kanidm-operator-bootstrap issue --recovery
```

Do not issue recovery URLs speculatively. The helper refuses to replace an
existing credential flow unless `--recovery` is present.

## Native CLI Task Snippets

The snippets below assume `kanidm self whoami` identifies the configured
delegated operator. Run the login sequence above first in a fresh shell.

Create a user:

```bash
kanidm person create "$NEW_USER" "$DISPLAY_NAME"
kanidm person update "$NEW_USER" --mail "$EMAIL"
```

Inspect a user:

```bash
kanidm person get "$USER"
```

Grant baseline and app access:

```bash
kanidm group add-members users "$USER"
kanidm group add-members files-sftp-users "$USER"
kanidm group add-members files-shared-users "$USER"
```

Grant and remove access to manual/additive groups:

```bash
kanidm group add-members "$GROUP" "$USER"
kanidm group remove-members "$GROUP" "$USER"
```

Use those live commands only for groups whose Homepage admin catalog labels as
`manual`. Default application groups and both backup roles are reconciled from
`vars.nix`; edit `identity.appUsers`, `identity.appAdminUsers`,
`backupAccess.adminUsers`, or `backupAccess.storageUsers` as appropriate and run
a guarded deploy. A live-only change to a repository-managed group will be
restored by reconciliation.

Inspect group membership state:

```bash
kanidm group get "$GROUP"
```

Issue a short-lived reset token for first sign-in:

```bash
OPERATOR="<identity.adminUser>"
kanidm person credential create-reset-token "$USER" --name "$OPERATOR"
```

Replace `<identity.adminUser>` with the configured Kanidm operator username. If
a token is shared, send it through a secure channel and treat it as an active
secret.

## File Access Baseline

- `users` enables the identity baseline for normal day-to-day sign-in.
- `identity.appUsers` is the declarative default-app bundle. People in
  `identity.appAdminUsers` inherit that normal bundle automatically, so do not
  repeat them in both lists; a manual `app-admin` grant still needs the user
  added to `identity.appUsers` and deployed.
- `files-personal-users` grants browser file access through Filestash and personal file-root provisioning.
- `files-sftp-users` enables SFTP access on the dedicated SFTP endpoint.
- `files-shared-users` adds `_Shared` inside each user personal root.
- `usb-access` adds `_USB` view from the mounted external USB storage path.
- `backup-admin` grants Kopia backup-management access and automatically inherits
  the separate `backup-storage-users` membership.
- `backup-storage-users` grants the read-only `_Backups` view without granting
  access to the Kopia administration UI. Configure storage-only people through
  `backupAccess.storageUsers`, never by adding them to `backupAccess.adminUsers`.
- `kiwix-users` grants access to the Kiwix offline wiki service.
- Keep protected groups like `system_admins`, `domain_admins`, and `idm_*` from routine selection unless a hard admin procedure is being executed.

## Vaultwarden Onboarding Coordination

Vaultwarden is self-service in this stack:

- users create accounts themselves at `https://passwords.<domain>/#/signup`
- operators do not need to generate or send Vaultwarden invite flows
- ensure users register with the Kanidm primary email (or chosen recovery email) so their Vaultwarden vault and Kanidm credential item stay aligned

For break-glass operations, the delegated operator should maintain a local Vaultwarden account manually.

## Troubleshooting

If access is denied but credentials are valid:
1. confirm group membership for the target app:

```bash
kanidm person get "$USER"
kanidm group get "$GROUP"
```

2. confirm DNS/identity service health in [Operations](./operations.md).
3. confirm the user can log in with local app credentials when applicable.

If the problem looks like stale grants:
- adjust app membership and wait for first-login provisioning in the target app.
- verify the user opened the app at least once after access was granted.

## Safe-to-avoid Guidance

- do not reintroduce the archived custom `kanidm-admin` helper package; use the
  native `kanidm` CLI
- prefer the homepage command snippets for the configured group catalog and evaluated host context, then verify live membership with the native CLI
- keep all sensitive reset tokens and credential artifacts out of long-lived logs
