# NixHomeServer – Agent Guidance

## Project goal
This repository defines a reproducible NixOS home-server stack focused on:
- secure identity and SSO (Kanidm + OAuth2 Proxy),
- self-hosted apps (Immich, Paperless, Audiobookshelf, Vaultwarden, Copyparty),
- reverse proxy and edge routing (Caddy + Cloudflared),
- deterministic provisioning via flakes and module composition.

The main objective is reliability-first infrastructure that can be rebuilt consistently from source control.

## Review and change expectations
- Prefer correctness and operational safety over cleverness.
- Keep networking and auth changes explicit and easy to audit.
- For security-sensitive defaults, avoid broad allowances and call out trade-offs.
- Ensure new config is compatible with current NixOS option names (avoid deprecated aliases).

## Mandatory validation for config changes
When changing `.nix` files or module wiring:
1. Run `nix flake check --no-build`.
2. Run `scripts/check-repo.sh`.
3. Include commands and outcomes in the final summary.

## Style conventions
- Keep module files focused: one service/domain concern per file.
- Reuse `vars.nix` for host/domain/port constants; avoid hardcoding duplicates.
- Prefer minimal, explicit systemd and firewall settings.
- Keep AppArmor profile names aligned with actual service unit names.

## Safety notes for contributors
- Bootstrap settings (e.g., permissive SSH auth) must be clearly marked and later hardened.
- TLS paths must be consistent across services that share certificates.
- Route public hostnames through the intended policy boundary (typically Caddy) unless there is a clear reason not to.
