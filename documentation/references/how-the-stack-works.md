# How The Stack Works

This guide explains request flow and bootstrap flow in plain language.

## 1) Public identity flow (`id.<domain>`)
1. Browser calls `https://id.<domain>`.
2. Cloudflare Tunnel forwards to local Caddy.
3. Caddy proxies to Kanidm.
4. Kanidm handles login/session and OIDC grants.

Why this matters:
- Identity stays centralized.
- Public identity endpoint is required for browser-based OIDC redirects.

## 2) Public files flow (`files.<domain>`)
1. Browser calls `https://files.<domain>`.
2. Cloudflare Tunnel forwards to local Caddy.
3. Caddy sends traffic to OAuth2 Proxy.
4. OAuth2 Proxy redirects user to Kanidm for login.
5. After successful login, OAuth2 Proxy forwards to Copyparty.

Why this matters:
- Copyparty does not need direct public auth logic.
- Access policy is controlled through Kanidm group membership (`fileshare_users`).

## 3) Private app flow (`paperless/photos/audiobooks/books/video/jellyseerr`)
1. NetBird client queries DNS for app hostname.
2. Unbound returns server NetBird IP.
3. Client connects over NetBird to Caddy on the server.
4. Caddy routes to app service.
5. OIDC-enabled apps redirect auth to `id.<domain>` when required.

Why this matters:
- Private apps are not published on the public internet.
- Same hostnames work on and off the LAN for enrolled NetBird clients.

## 4) Certificates and TLS
- ACME uses DNS-01 with Cloudflare API token.
- Caddy serves certificates for app domains and `id.<domain>`.
- No direct public `80/443` port-forwarding is required for certificate issuance.

## 5) Secrets lifecycle
1. Operator stages required cleartext files in `secrets/top/`.
2. `scripts/gen-all-secrets.sh` validates and encrypts into `secrets/*.age`.
3. Host decrypts at runtime using `/etc/agenix/age.key`.
4. Services consume decrypted files from `/run/agenix`.

Why this matters:
- Secrets can live in Git history only as encrypted blobs.
- Runtime services get least-privilege file access via ownership/mode.

## 6) Deploy lifecycle
1. Change config in repo.
2. Run `nix flake check --no-build` and `scripts/check-repo.sh`.
3. Run `nixos-rebuild test` before `switch`.
4. Verify services, exposure boundaries, DNS, and auth flow.

This loop keeps changes reproducible and auditable.
