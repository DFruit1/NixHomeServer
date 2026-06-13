# Kanidm Guide

`kanidm-admin` was archived and removed from active deployment. Use this guide with the native `kanidm` CLI and the homepage "For Admins" page for live-generated commands.

Use this as the operator guide for:
- checking people and groups during onboarding
- granting/removing app access through Kanidm group membership
- issuing short-lived password-reset tokens for first sign-in
- post-login access troubleshooting
- Vaultwarden self-signup handoff coordination

Guarded deploys, service health, and DNS checks live in [Operations](./operations.md).

## Important Note

The homepage app now shows live groups from Kanidm and generates ready-to-copy commands for common admin actions. Use those as the primary source for environment flags and target host details.

## Conventions

- Placeholders such as `<USER>`, `<GROUP>`, and `<EMAIL>` are examples.
- Use the current server shell context when running commands (the homepage guide is generated with live context).
- This repository intentionally avoids `kanidm-admin` for production procedures.

## Native CLI Task Snippets

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

Grant and remove access to custom groups:

```bash
kanidm group add-members "$GROUP" "$USER"
kanidm group remove-members "$GROUP" "$USER"
```

Inspect group membership state:

```bash
kanidm group get "$GROUP"
```

Issue a short-lived reset token for first sign-in:

```bash
kanidm person credential create-reset-token "$USER" 3600
```

If a token is shared, send it through a secure channel and treat it as an active secret.

## File Access Baseline

- `users` enables the identity baseline for normal day-to-day sign-in.
- `files-personal-users` grants browser file access through Filestash and personal file-root provisioning.
- `files-sftp-users` enables SFTP access on the dedicated SFTP endpoint.
- `files-shared-users` adds `_Shared` inside each user personal root.
- `usb-access` adds `_USB` view from the mounted external USB storage path.
- `backup-admin` grants `_Backups` read access through the managed file structure.
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

- do not keep deprecated `kanidm-admin` in active workflows
- prefer the homepage command snippets (live group catalog + current context)
- keep all sensitive reset tokens and credential artifacts out of long-lived logs
