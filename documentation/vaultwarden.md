# Vaultwarden Guide

Use this as the operator guide for:
- first deploy validation of the private Vaultwarden service
- break-glass local admin handling
- local Vaultwarden onboarding and user self-service signup
- the standard Kanidm credential-item workflow for end users

Guarded deploys, service health, and DNS checks live in [Operations](./operations.md). Kanidm session and user lookup details live in [Kanidm Guide](./kanidm.md).

## Service Model

Vaultwarden is intentionally private-only in this stack:
- private hostname: `passwords.<domain>` from the imported Vaultwarden module, or `nix run .#show-config-summary -- --host <host>`
- reachable on LAN and NetBird
- not published through Cloudflare Tunnel
- all users sign in with Vaultwarden local credentials
- no SMTP is required for account onboarding
- the delegated operator keeps a local Vaultwarden login for break-glass access

Operational rule:
- normal users should self-register at `/#/signup` from trusted LAN/NetBird
- Vaultwarden access is not granted by a Kanidm group or OAuth2 client
- the local operator account remains the recovery path for service administration

## Before First Live Deploy

Refresh the repo-managed secrets:

```bash
./scripts/generate-all-secrets.sh
```

Vaultwarden does not need SMTP in this stack. Users create local accounts directly on the Vaultwarden signup page.

## SSO Removal Migration

Before deploying the local-login-only config:
1. Open the Vaultwarden admin panel and list current users.
2. For every non-break-glass user who has used SSO, confirm they can sign in locally or complete a Vaultwarden password setup/reset.
3. Confirm each user can unlock their vault on at least one intended device with local Vaultwarden credentials.
4. Deploy the config change.
5. After deploy, verify the SSO button/path is gone and normal login requires Vaultwarden-local credentials.
6. Keep the delegated operator's local login as the break-glass account.

If live Kanidm retains orphaned objects after provisioning converges, delete or disable OAuth2 client `vaultwarden-web`, then delete group `vaultwarden-users` only after confirming no repo references remain.

## First Deploy Checks

After a guarded deploy or switch:

```bash
systemctl status vaultwarden vaultwarden-secret-materialize
sudo systemctl --failed --no-pager
curl -I https://<passwords-domain>/
curl -I http://127.0.0.1:8222/
```

Expected result:
- `vaultwarden.service` is active
- `vaultwarden-secret-materialize.service` completed successfully
- the private hostname resolves only on LAN and NetBird paths
- the edge and local upstream both answer with `200`, `302`, or `303`
- the login page offers local Vaultwarden login, not Kanidm SSO

If the hostname does not resolve from a workstation browser, test the private edge directly against the server LAN IP:

```bash
curl -kI --resolve <passwords-domain>:443:<server-lan-ip> https://<passwords-domain>/
```

If that returns a healthy response while normal DNS still fails, Vaultwarden itself is up and the problem is the workstation path to the private hostname. Check local DNS, Unbound reachability, or NetBird routing before changing the Vaultwarden service config.

## First Admin Access

The Vaultwarden admin backend is protected by the agenix secret `vaultwardenAdminToken`.

Check the secret path on the server:

```bash
echo "$KANIDM_ADMIN_VAULTWARDEN_ADMIN_TOKEN_FILE"
```

Use the local break-glass account path for initial admin setup:
1. Open `https://<passwords-domain>`.
2. Open `https://<passwords-domain>/#/signup`.
3. Create and keep a local Vaultwarden account for the delegated operator.
4. Keep that local login available for break-glass use.

Do not treat the Vaultwarden admin token as a day-to-day user login secret. It is only for the admin backend and operator helpers.

## User Onboarding

Preferred onboarding path:
- users create their account on `https://<passwords-domain>/#/signup` with the same email as their Kanidm primary email when trusted on LAN/NetBird.
- no operator invite is required.

If an operator must guide a specific person:
1. Confirm Kanidm identity and email for that person.
2. Point them to `https://<passwords-domain>/#/signup`.
3. Instruct them to register with the exact email that will be used for credential storage and recovery.
4. Confirm the account appears in Vaultwarden and works from at least one target device.

Expected result:
- the user creates local Vaultwarden credentials
- the user stores shared Kanidm credentials in Vaultwarden via one predictable item

## Break-Glass Admin Pattern

Keep the delegated operator Vaultwarden account maintained manually.

Break-glass categories that the delegated operator should create manually in Vaultwarden include:
- Kanidm admin and recovery credentials
- `idm_admin` and similar emergency identities
- NetBird administrative credentials or recovery notes
- Cloudflare administrative credentials or recovery notes
- any other service that would be required to recover identity, routing, or remote access

Do not try to declaratively seed these items into user vaults.

## Standard User Item Pattern

Each user should create one Vaultwarden login item for Kanidm and keep these together:
- username or primary email
- current Kanidm password
- Kanidm TOTP seed or active TOTP secret
- synced passkey for the same identity

That gives less technical users one predictable place to manage all three credential types.

Suggested operator guidance for users:
1. Open `https://<passwords-domain>/#/signup`.
2. Register with the email used in Kanidm.
3. Create or confirm local Vaultwarden credentials.
4. Create the initial Kanidm login item in Vaultwarden.
5. Store the password, TOTP, and passkey under that one item.
6. Test that the item syncs to their intended devices before relying on it.

## Troubleshooting

If signup fails:
- check `journalctl -u vaultwarden -n 100 --no-pager`
- verify `vaultwarden-secret-materialize.service` wrote the runtime env file
- verify the account is not already active in the Vaultwarden admin UI

If local login fails:
- confirm the user registered at `/#/signup` with the expected email
- confirm the user is trying Vaultwarden local credentials, not Kanidm credentials directly
- verify the private hostname resolves correctly through Unbound

If the private hostname is unreachable:
- start with [Operations](./operations.md#service-validation)
- verify Caddy, Unbound, and Vaultwarden are all healthy
- confirm the hostname is expected to stay private-only and should not resolve on public DNS
- compare a normal browser or `curl` lookup with the forced-resolution `curl --resolve ...` check above
