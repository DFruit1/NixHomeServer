# FreshRSS Guide

FreshRSS is available at `https://rss.sydneybasiniot.org` on LAN and NetBird paths. It is
private-DNS-only and has no Cloudflare ingress. Browser access uses the shared
Kanidm OIDC gateway and requires membership in `freshrss-users`.

## Access and first login

The configured `identity.appUsers`, application administrators, server
operator, and synthetic canary receive `freshrss-users` through declarative
provisioning. Membership is authoritative: edit `identity.appUsers` or
`identity.appAdminUsers` in `vars.nix`, validate, and use the guarded deployment
workflow. A direct Kanidm membership edit is temporary and will be replaced by
the next provisioning run. To inspect the effective group:

```bash
kanidm group get freshrss-users
```

Removing a user from `freshrss-users` immediately blocks browser OIDC access,
but it does not erase an API password already stored in that user's FreshRSS
account. As part of offboarding, also delete that account under **Administration
→ Manage users** (after confirming its feeds are backed up), or rotate its API
password to an unknown random value. Account deletion is destructive; the
central backup remains the recovery path.

Open `https://rss.<domain>`. The shared gateway redirects an unauthenticated
browser to Kanidm, then supplies Kanidm's validated `preferred_username` to
FreshRSS. The email claim is not used as the FreshRSS account name.
FreshRSS creates that per-user account on first login. The configured
`identity.adminUser` is FreshRSS's `default_user`; FreshRSS grants that account
administrator access when it auto-registers on first login. Sign in with that
identity before performing application administration.

Each deployment reconciles the persisted FreshRSS configuration after the
upstream configuration step so restores and older state cannot silently turn
off HTTP-auth auto-registration or switch account naming to an email field.

FreshRSS form passwords are not used for browser login. To switch accounts or
fully sign out, open `https://rss.<domain>/oauth2/sign_out`. This clears the
shared gateway cookie and continues through the Kanidm logout flow.

## Feeds and clients

Add individual RSS or Atom URLs from the FreshRSS subscription page, or import
an OPML file from FreshRSS settings. Each Kanidm identity receives an isolated
FreshRSS feed library.

The native API is enabled for clients on LAN or NetBird. Sign in through the
browser first, open **Settings → Profile**, and set a strong, unique **API
password**. FreshRSS 1.29.1 accepts any non-empty value here, so generate at
least 20 random characters; do not reuse the Kanidm password. Configure clients
with:

- Server: `https://rss.sydneybasiniot.org/api/greader.php`
- Username: the Kanidm short username used by FreshRSS
- Password: the per-user FreshRSS API password

Google Reader API is preferred over Fever because it is more complete and does
not derive its API key with MD5. Every user must set their own API password.
Only `/api/greader.php` and its PATH_INFO form bypass browser OIDC so FreshRSS
can perform its native API-password authentication; those requests receive no
`REMOTE_USER`, email, or trusted gateway identity headers. Other files in
FreshRSS's `/api` directory use different authentication contracts and remain
behind OIDC. The API remains private-DNS-only and is not published through
Cloudflare.

Only grant access to trusted users. FreshRSS fetches subscriptions from the
server and therefore permits a user to request URLs reachable from the server,
including private-network endpoints. The private route and dedicated access
group reduce exposure but do not turn untrusted feed URLs into a safe
multi-tenant boundary. See FreshRSS's official
[access-control guidance](https://freshrss.github.io/FreshRSS/en/admins/09_AccessControl.html).

## Service checks

```bash
systemctl status freshrss-config.service freshrss-updater.timer caddy.service phpfpm-freshrss.service
journalctl -u freshrss-config.service -u freshrss-updater.service -u phpfpm-freshrss.service -n 100 --no-pager
curl -kI --resolve rss.sydneybasiniot.org:443:<server-lan-ip> https://rss.sydneybasiniot.org/
```

An unauthenticated request should redirect to the shared OIDC flow. FreshRSS has
no HTTP origin port: the existing public Caddy process serves it directly over
PHP-FPM's `0600`, Caddy-owned Unix socket after OIDC and group authorization.
Do not loosen that socket or forward identity headers around the shared gateway.
The exception is the exact Google Reader API endpoint family described above,
where FreshRSS's own API password is the authentication boundary. Caddy adds
HSTS, MIME-sniffing, clickjacking, referrer, and browser-permission protections
without replacing FreshRSS's built-in Content Security Policy, and API
responses are marked `Cache-Control: no-store`.

## Persistence, backup, and recovery

FreshRSS is explicitly configured to store each user's feed data in SQLite. It
stores its system configuration, per-user settings, subscriptions, and SQLite
databases under `/var/lib/freshrss`. Impermanence retains that directory
under `/persist` even when the application is disabled or its module is removed,
and the central Kopia snapshot includes it. Before each snapshot, the backup
preparation service runs FreshRSS's online database-backup command and copies an
integrity-checked `freshrss-<username>.sqlite` file for every existing user into
the successful backup generation.

For recovery, follow the repository restore runbook and restore into a separate
path first. Inspect the recovered FreshRSS data before replacing live state.
Prefer the logical per-user SQLite copy when repairing a damaged live database;
the full application-state snapshot remains the recovery source for configuration
and user settings.
After restoration, run a guarded test deployment and verify both the operator
and a normal `freshrss-users` member can reach their expected, separate feed
libraries.
