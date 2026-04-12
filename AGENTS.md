# NixHomeServer – Agent Guidelines

## Purpose

This repository defines a reproducible NixOS home-server focused on:

* Identity & SSO (Kanidm, OAuth2 Proxy)
* Self-hosted apps (Immich, Paperless, Audiobookshelf, Copyparty)
* Edge routing (Caddy, Cloudflared)

Priority: **reliability, security, and reproducibility**

---

## Core Principles

* Prefer **clarity over cleverness**
* Keep **service boundaries explicit** (`modules/<service>/`)
* Keep **auth and networking paths auditable**
* Use **vars.nix for all shared constants** (domains, ports, hostnames)

---

## Architecture Rules

* Public traffic must flow through **Caddy (policy boundary)**
* Do not introduce implicit trust between services
* Avoid hardcoded values — reuse `vars.nix`
* Remove all references when deleting a service (DNS, proxy, secrets, docs)

---

## Security Rules

* Never commit plaintext secrets
* Treat `secrets/*.age` as sensitive
* Keep TLS configuration consistent across services
* Clearly mark any temporary or bootstrap-level insecure settings

---

## Config Change Requirements

For any `.nix` change:

1. Run:

   ```sh
   nix flake check --no-build
   ```

2. Run:

   ```sh
   scripts/check-repo.sh
   ```

3. Include results in summary

---

## Documentation Review

After significant changes:

* Run doc reviewer: `.codex/agents/doc-reviewer.md`
* Apply any required documentation updates before finalizing

---

## Operational Notes

* Keep modules focused (one concern per file)
* Prefer minimal systemd + firewall config
* Avoid deprecated NixOS options

---

## Rebuild Command

Use this command, password for sudo is 'changeme'

```sh
nix run nixpkgs#nixos-rebuild -- test \
  --flake .#server \
  --target-host dsaw@192.168.0.144 \
  --build-host dsaw@192.168.0.144 \
  --sudo \
  --ask-sudo-password \
  --no-reexec
```
