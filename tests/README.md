# Tests

This directory contains repository-level validation that goes beyond a plain flake evaluation.

Current coverage:

- `bootstrap-readiness.sh`: checks first-deploy prerequisites, required files, critical secrets, and operator documentation coverage.
- `bootstrap-checklist.sh`: checks that the operator-facing first-bootstrap checklist exists and covers Cloudflare Tunnel, NetBird, Kanidm, Caddy, DNS, and repo validation commands.
- `bootstrap-audit.sh`: runs first-bootstrap live runtime checks in a non-blocking way and reports all failing checks together.
- `networking.sh`: checks the intended networking policy and service boundary assumptions:
  - Cloudflare Tunnel only exposes the public subset.
  - Caddy keeps the HTTP/TLS boundary in front of public entrypoints.
  - Kanidm and Caddy share the ACME certificate paths consistently.
  - Unbound, dnscrypt-proxy, and NetBird wiring stay aligned with `vars.nix`.
  - DietPi companion networking guidance stays present when that architecture is documented.
- `secrets.sh`: checks that agenix secret definitions, owners, and consumers remain aligned.
- `auth-routing.sh`: checks OIDC client IDs, fileshare auth flow, reverse-proxy routing, and the documented public/private app boundary.
- `apparmor.sh`: checks that every referenced generated AppArmor profile has a matching policy key and that critical unit names stay aligned.
- `firewall.sh`: checks evaluated firewall exposure so only the intended global and NetBird interface ports stay open.
- `runtime-contracts.sh`: checks evaluated NixOS service, hostname, tunnel, secret-path, and interface contracts directly from `config`.
- `run-all.sh`: runs the repository policy suite together from one entrypoint.
- `dietpi.sh`: runs live DietPi companion checks over SSH using `vars.piLanIP` and `DIETPI_SSH_TARGET` when needed.
- `lib.sh`: shared helper functions used by the test scripts.

Run manually from the repository root:

```bash
tests/run-all.sh
tests/run-all.sh --with-runtime
tests/bootstrap-audit.sh
tests/dietpi.sh
DIETPI_SSH_TARGET=dietpi@192.168.0.123 tests/dietpi.sh
```

Prerequisites:

- `nix`
- `jq`
- `rg`

The scripts use `nix eval` so host-specific values from `vars.nix` and the evaluated NixOS configuration remain authoritative. They use `jq` for JSON assertions and `rg` for source assertions.

To avoid overlap, keep documentation/readiness assertions in `bootstrap-readiness.sh` and `bootstrap-checklist.sh`. Keep policy-specific scripts (for example `auth-routing.sh` and `networking.sh`) focused on service and wiring contracts.

## How broad is the coverage?

- **Repository static policy coverage (`tests/run-all.sh`)**
  - Bootstrap files + docs + required secret declarations
  - Auth/routing policy and OIDC wiring
  - Firewall and network exposure intent
  - Evaluated runtime contracts from the composed NixOS config
  - Secret ownership/consumer alignment
- **Live runtime coverage**
  - `tests/bootstrap-audit.sh`: non-blocking first-boot runtime checks on the server itself (service health, listener ports, and local endpoint probes).
  - `tests/dietpi.sh`: optional live DietPi companion checks over SSH when the companion is enabled.

In short: `tests/run-all.sh` validates what the repository *declares*, while `tests/bootstrap-audit.sh` validates what a running host is *actually doing* after bootstrap.

`tests/run-all.sh` runs the static repository policy suite.
`tests/run-all.sh --with-runtime` also runs the live DietPi companion check.
`scripts/check-repo.sh` uses `tests/run-all.sh`, so the normal repository validation path stays static and deterministic.
`tests/dietpi.sh` defaults to `root@<piLanIP>` using the `piLanIP` value from `vars.nix`. Set `DIETPI_SSH_TARGET` if the DietPi SSH login user is different or root SSH login is disabled.
DietPi-specific checks are skipped unless `enableDietPiCompanion = true` in `vars.nix`.
