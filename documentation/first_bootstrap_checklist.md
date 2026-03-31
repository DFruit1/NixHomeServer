# First Bootstrap Validation Checklist

Use this checklist after the first successful `nixos-rebuild switch` to confirm end-to-end server health.

> Scope: these are **operator runbook checks** for a newly bootstrapped node. Repository policy checks still run through `tests/run-all.sh` and `nix flake check --no-build`.
> Need a single command that reports **all** runtime failures (instead of stopping at the first one)? Run `tests/bootstrap-audit.sh`.

## 1) Baseline system + deploy status

- [ ] Host came up with the expected hostname.
  - Command: `hostnamectl --static`
- [ ] No failed units after bootstrapping.
  - Command: `systemctl --failed`
- [ ] Last deploy finished without service start failures.
  - Command: `journalctl -b -p warning --no-pager`

## 2) Edge ingress and reverse proxy

- [ ] Cloudflare Tunnel service is enabled and active.
  - Command: `systemctl status cloudflared --no-pager`
- [ ] Tunnel process reports connected edge sessions.
  - Command: `journalctl -u cloudflared -n 200 --no-pager | rg -i 'connected|registered|connection'`
- [ ] Caddy is active and bound to HTTP/HTTPS on the host.
  - Commands:
    - `systemctl status caddy --no-pager`
    - `ss -tulpn | rg ':(80|443)\\b'`
- [ ] Public host routing works through Caddy locally.
  - Commands:
    - `curl -kI --resolve "id.<domain>:443:127.0.0.1" https://id.<domain>/`
    - `curl -kI --resolve "fileshare.<domain>:443:127.0.0.1" https://fileshare.<domain>/`

## 3) Identity / auth plane

- [ ] Kanidm API is reachable on localhost and answering over TLS.
  - Command: `curl -kI https://127.0.0.1:8443/status`
- [ ] Kanidm service is active and has no recurring startup errors.
  - Commands:
    - `systemctl status kanidm --no-pager`
    - `journalctl -u kanidm -n 200 --no-pager`
- [ ] OAuth2 Proxy is active and can reach the configured issuer.
  - Commands:
    - `systemctl status oauth2-proxy --no-pager`
    - `journalctl -u oauth2-proxy -n 200 --no-pager`

## 4) Overlay and internal network

- [ ] NetBird daemon is active.
  - Command: `systemctl status netbird --no-pager`
- [ ] NetBird peer is connected and using the expected interface.
  - Commands:
    - `netbird status`
    - `ip addr show wt0`
- [ ] Internal DNS responder is active.
  - Commands:
    - `systemctl status unbound --no-pager`
    - `dig @127.0.0.1 id.<domain> +short`

## 5) App endpoints and trust boundary

- [ ] Public endpoints reachable from outside LAN/NetBird are only the intended hosts (`id.<domain>`, `fileshare.<domain>`).
- [ ] Internal app hostnames resolve on LAN/NetBird and are not tunnel-exposed (`paperless`, `immich`, `photoshare`, `audiobookshelf`).
  - Suggested checks:
    - `dig @127.0.0.1 paperless.<domain> +short`
    - `dig @127.0.0.1 photoshare.<domain> +short`

## 6) Validation suite + follow-up hardening

- [ ] Repository checks pass from the repo root.
  - Commands:
    - `NIX_CONFIG='experimental-features = nix-command flakes' nix flake check --no-build`
    - `NIX_CONFIG='experimental-features = nix-command flakes' scripts/check-repo.sh`
- [ ] Runtime policy checks pass.
  - Command: `tests/run-all.sh --with-runtime`
- [ ] Any bootstrap-only permissive settings (if temporarily enabled) are reverted.

## Sign-off

Record date/time, operator, and notable deviations before declaring bootstrap complete.
