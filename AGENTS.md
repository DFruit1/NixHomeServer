# NixHomeServer – Agent Guidance

## Project goal
This repository defines a reproducible NixOS home-server stack focused on:
- secure identity and SSO (Kanidm + OAuth2 Proxy),
- self-hosted apps (Immich, Paperless, Audiobookshelf, Copyparty),
- reverse proxy and edge routing (Caddy + Cloudflared),
- deterministic provisioning via flakes and module composition.

The primary objective is **reliability-first infrastructure** that can be rebuilt consistently from source control.

## Scope and architecture constraints
- Keep service boundaries explicit (`modules/<service>/default.nix`).
- Keep public traffic routed through the intended policy boundary (normally Caddy).
- Keep identity and auth paths auditable; avoid implicit trust chains.
- Prefer explicit hostnames/ports in `vars.nix` and reuse constants from there.

## Review and change expectations
- Prefer correctness and operational safety over cleverness.
- Keep networking and auth changes explicit and easy to audit.
- For security-sensitive defaults, avoid broad allowances and call out trade-offs.
- Ensure options match current NixOS naming (avoid deprecated aliases).
- If removing a service, remove all residual references (DNS, reverse-proxy, secrets, docs, and checks).

## Tooling expectations
Before running checks or scripts, ensure required tooling is present on PATH:
- `nix` (with flakes/nix-command enabled),
- `age`, `openssl`, `jq` (for secret workflows),
- `rg` (for repository checks).

## Mandatory validation for config changes
When changing `.nix` files or module wiring:
1. Run `NIX_CONFIG='experimental-features = nix-command flakes' nix flake check --no-build`.
2. Run `NIX_CONFIG='experimental-features = nix-command flakes' scripts/check-repo.sh`.
3. Include commands and outcomes in the final summary.

## Style conventions
- Keep module files focused: one service/domain concern per file.
- Reuse `vars.nix` for host/domain/port constants; avoid hardcoded duplicates.
- Prefer minimal, explicit systemd and firewall settings.
- Keep AppArmor profile names aligned with actual systemd unit names.
- Use `complain` mode first for newly generated AppArmor profiles; move to `enforce` only after observed policy coverage.

## Safety notes for contributors
- Bootstrap settings (e.g., permissive SSH auth) must be clearly marked and later hardened.
- TLS paths must be consistent across services that share certificates.
- Never commit clear-text secrets from `secrets/top/`.
- Treat tracked `secrets/*.age` as sensitive artifacts; avoid accidental regeneration in unrelated changes.

## Codex command safety
- Repository command policy is defined in `rules.toml`.
- Keep destructive/system-wide commands blocked or approval-gated.
- Prefer read-only inspection commands before mutation.
