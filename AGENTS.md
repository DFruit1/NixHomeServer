# NixHomeServer – Agent Guidelines

## Purpose

This repository defines a reproducible NixOS home-server focused on:

* Identity & SSO (Kanidm, OAuth2 Proxy)
* Self-hosted apps (Immich, Paperless, Audiobookshelf, Copyparty)
* Edge routing (Caddy, Cloudflared, Netbird, Unbound)

Priority: **reliability, security, and reproducibility**

---

## Core Principles

* Keep **service boundaries explicit** (`modules/<service>/`)
* Use **vars.nix for shared, operator-facing values** that a new server owner is likely to change
* Avoid deprecated NixOS options
---

## Architecture Rules

* Do not introduce implicit trust between services
* Keep module-private constants, timers, paths, and stable loopback ports inside their owning modules
* Remove all references when deleting a service (DNS, proxy, secrets, docs)

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

The deployed bootstrap sudo password is stored as the root-only agenix
secret `serverBootstrapSudoPassword`, which materializes at
`/run/agenix/serverBootstrapSudoPassword` on the server. If an interactive sudo
prompt is unavoidable, refer to that secret rather than relying on memory.
