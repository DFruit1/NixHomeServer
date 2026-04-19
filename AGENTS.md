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
* Use **vars.nix for shared, operator-facing values** that a new server owner is likely to change

---

## Architecture Rules

* Public traffic must flow through **Caddy (policy boundary)**
* Do not introduce implicit trust between services
* Keep module-private constants, timers, paths, and stable loopback ports inside their owning modules
* Remove all references when deleting a service (DNS, proxy, secrets, docs)
* Prefer one documented deploy path and one documented validation path

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

Prefer the guarded deploy helper. Derive the intended primary LAN address from
`vars.serverLanIP`, then allow a local override for the currently reachable SSH
endpoint during cutover.

```sh
export TARGET_SERVER_IP="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanIP')"
export CURRENT_SERVER_IP="${CURRENT_SERVER_IP:-$TARGET_SERVER_IP}"

./scripts/deploy-validated.sh \
  --target "dsaw@$CURRENT_SERVER_IP" \
  --build-host "dsaw@$CURRENT_SERVER_IP" \
  --action test \
  --hostname server
```

`vars.serverLanIP` remains the intended primary LAN address. During a
migration window, do not commit the temporary reachable IP into the repo; set
`CURRENT_SERVER_IP` locally instead.
