# FreshRSS OIDC authentication boundary

- Status: accepted
- Date: 2026-08-22

## Context

FreshRSS supports OpenID Connect through Apache `mod_auth_openidc` in its
official Debian image or an Apache deployment. The pinned NixOS module supports
either Caddy or Nginx with PHP-FPM. This server already has an always-present
Caddy and shared OAuth2 Proxy gateway backed by Kanidm, with one domain cookie,
group authorization, spoofable-header removal, logout behavior, and an
authenticated canary.

Adding Apache and a second OIDC client would duplicate an established trust
boundary. Using ordinary FreshRSS form authentication would also create a
second password for a browser-only application and would not satisfy the shared
login requirement.

## Decision

FreshRSS uses its supported `http_auth` mode behind the shared Kanidm OIDC
gateway. The app registers a private `rss.<domain>` route and a dedicated
`freshrss-users` access group. There is no Cloudflare ingress.

Public Caddy removes caller-supplied identity headers, performs OIDC
authentication, and authorizes `freshrss-users`. It then serves FreshRSS
directly through PHP-FPM's Caddy-owned `0600` Unix socket. At that FastCGI
boundary, Caddy maps Kanidm's validated `preferred_username` to `REMOTE_USER`,
which FreshRSS consumes through its HTTP-auth contract. There is no separately
reachable FreshRSS HTTP origin. Unknown allowed identities are auto-registered
on first login. FreshRSS treats its configured `default_user` as an
administrator, so the Kanidm operator gains administration when that exact
account auto-registers. Because `config.php` is persisted and can outlive
package defaults, the configuration service reconciles HTTP-auth
auto-registration after the upstream configuration step on every deployment.

FreshRSS's Google Reader mobile API is enabled only on the private route. Exact
`/api/greader.php` and `/api/greader.php/*` requests bypass browser OIDC and
receive no trusted identity variables; FreshRSS authenticates them with each
user's separate API password. Other endpoints in `/api` retain OIDC because
they use different authentication contracts. All other requests retain OIDC
and `freshrss-users` authorization. Shared logout remains
`/oauth2/sign_out`, which clears the common gateway session and the parent
Kanidm session. Application state remains under `/var/lib/freshrss`, is
centrally persisted across module removal, and is registered with the backup
inventory. Backup preparation uses FreshRSS's online backup command to create
and integrity-check one logical SQLite copy per existing user before the Kopia
snapshot.

## Consequences

- FreshRSS does not own an OIDC client or application secret; the shared gateway
  remains the only browser authentication boundary.
- Unrelated local services cannot reach FreshRSS's FastCGI boundary because the
  PHP-FPM socket is accessible only to Caddy.
- Each allowed Kanidm short username receives an isolated FreshRSS account on
  first visit, while the configured operator retains the one default-admin role.
- Native RSS clients use the Google Reader API with a separate per-user API
  password and require LAN or NetBird reachability.
- Kanidm group removal cannot revoke a password stored locally by FreshRSS, so
  a timer retires the local account (moving `users/<username>` to
  `.retired-users/<username>`) once the owner leaves `freshrss-users`, stopping
  browser login and API authentication while retaining the data for restore.
- Feed fetching is server-side, so an nftables egress policy blocks the
  `freshrss` user from private, local, and link-local destinations while DNS
  still resolves through the local resolver; `freshrss-users` must remain
  limited to trusted users because feed URLs can still redirect fetches to
  arbitrary public destinations.

## Rejected alternatives

- Adding Apache and `mod_auth_openidc` solely for FreshRSS.
- Adding Nginx and a spoofable loopback HTTP origin solely for FreshRSS.
- Creating a legacy per-application OAuth2 Proxy sidecar and duplicate secrets.
- Exposing FreshRSS with form authentication or without application
  authentication.
- Trusting a public `Remote-User` or `X-WebAuth-User` request header.

## References

- [FreshRSS access-control and trusted-proxy guidance](https://freshrss.github.io/FreshRSS/en/admins/09_AccessControl.html)
- [FreshRSS OpenID Connect guidance](https://freshrss.github.io/FreshRSS/en/admins/16_OpenID-Connect.html)
- [NixOS FreshRSS service options](https://search.nixos.org/options?channel=unstable&query=services.freshrss)
