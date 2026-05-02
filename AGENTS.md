# NixHomeServer – Agent Guidelines

## Purpose

This repository defines a reproducible NixOS home-server focused on:

* Identity & SSO (Kanidm, OAuth2 Proxy)
* Self-hosted apps (Immich, Paperless, Audiobookshelf, Copyparty)
* Edge routing (Caddy, Cloudflared, Netbird, Unbound)

---

## Core Principles

* Keep service boundaries explicit (`modules/<service>/`)
* Use vars.nix for shared, operator-facing values that a new server owner is likely to change
* Avoid deprecated NixOS options
* The config should not only be efficient and reliable but also human readable for technical users and usable for non-technical users.
* Do not introduce implicit trust between services
* Core_modules are assumed to always be part of the config and therefore can be heavy dependent on each other. Modules outside of core modules may change and therefore should stay modular.

---

## Environment

* The only assumption about the local desktop workstation containing this repo should be that it is a linux desktop with nix, bash and the standard coreutils installed. All other assumptions should be avoided or verified.
* For commonly needed tools, prefer installing them as permanent nix system packages. Prioritise coverage rather than simplicity. If a tool is only needed as a one-off or is rarely needed, use a nix-shell to make it available for the process that needs it. 

---

## Testing

* Testing should be focussed on catching potential or actual runtime errors in the config during buildtime.
* Avoid duplication of testing efforts
* Where possible, declare shell scripts in nix rather than as ad-hoc shell scripts
* Tests should generalise to anyone's config and should not try to assert values specific to my individual config
* Tests for one-off migrations, checking legacy cleanup should be actively pruned away to keep the testing focussed and minimal as possible.
* Aggressively and regularly prune away unneeded tests to avoid bloat long term

---

## Git Tracking

* Ensure all new git files (except for those in .gitignore) are tracked as soon as they are created to avoid visibility issues during nix rebuilds
* Avoid tracking huge files and directories that do not need to be tracked, such as build directories or caches
* Do not track plaintext secrets or other sensitive information

---

## Rebuild Command

* Prefer the guarded deploy helper for rebuild. 
* Rebuilds including nix drv and rust build artifacts should be done on the remote server when possible.
* The deployed bootstrap sudo password is stored as the root-only agenix
secret `serverBootstrapSudoPassword`, which materializes at
`/run/agenix/serverBootstrapSudoPassword` on the server. If an interactive sudo
prompt is unavoidable, refer to that secret rather than relying on memory.

---

## Management of Storage Space

* When storage space is almost full on the main internal SSD, run nix garbage collection to maintain free space
* If storage space is still near to being full after nix garbage collection, look through the file system and suggest to the user in chat what to clean up (e.g. log or tmp files) along with commands they can run themselves.
* Do not attempt to clean up files yourself to free up storage space, always get the user to do it. Never delete files off the data storage disks or volumes.
* Treat `disko` as a blank-machine bootstrap tool only.
* Never use `disko` or disk formatting commands to manage an existing server or an in-place storage migration.
* For existing servers, guide the user through non-destructive ZFS or filesystem maintenance steps instead of reprovisioning disks.
