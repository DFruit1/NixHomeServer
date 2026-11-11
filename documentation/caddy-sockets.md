# Caddy control and authenticated routing sockets

The main Caddy admin API listens on `/run/caddy-admin/admin.sock` with mode
`0600`, inside a Caddy-owned directory with mode `0700`. Only Caddy's Unix
identity and root can access it. It does not listen on TCP port 2019.

The shared authenticated router listens on
`/run/auth-gateway-router/router.sock` with mode `0660`, inside a directory
with mode `0750`. A dedicated `auth-gateway-router` user and group own both.
Only `caddy.service` receives that supplementary group; unrelated services
cannot connect and supply trusted identity headers. The router receives no
membership in Caddy's group and cannot access Caddy's admin socket.

The legacy `repo.authGateway.internalPort` option remains accepted for
configuration compatibility, but no longer controls a TCP listener. Legacy
sidecar mode does not create the router account or grant its group to Caddy.

## Deployment and reloads

Use the normal guarded test/switch deployment. The first deployment changes
both service units, so they restart to establish the new listeners and group
membership. Expect a brief interruption to Caddy connections during this
migration. Caddy starts after the router; a router failure does not stop
unrelated Caddy hosts.

Subsequent Caddy configuration and certificate reloads continue through the
existing `ExecReload` command. Caddy reads the admin socket address from the
configuration; no TCP fallback is configured. Runtime directories are managed
by systemd and recreated after a reboot or service restart. A guarded rollback
to the previous units also restarts them to restore their previous listeners.

After an authorised deployment, inspect `systemctl status caddy
auth-gateway-router`, the socket ownership and modes with `stat`, and an
authenticated application request. An administrator can inspect the API with
`sudo curl --unix-socket /run/caddy-admin/admin.sock http://localhost/config/`.
Treat the returned configuration as operational information.

Upstream references: [admin API](https://caddyserver.com/docs/caddyfile/options#admin),
[Unix socket permissions](https://caddyserver.com/docs/conventions#network-addresses),
and [configuration reloads](https://caddyserver.com/docs/command-line#caddy-reload).
