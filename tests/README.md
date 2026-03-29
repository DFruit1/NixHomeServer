# Tests

This directory holds repository-level validation that is more specific than a plain flake evaluation.

Current coverage:

- `networking.sh`: checks the intended networking policy and service boundary assumptions:
  - Cloudflare Tunnel only exposes the public subset.
  - Caddy keeps the HTTP/TLS boundary in front of public entrypoints.
  - Kanidm and Caddy share the ACME certificate paths consistently.
  - Unbound, dnscrypt-proxy, and NetBird wiring stay aligned with `vars.nix`.
  - DietPi companion networking guidance stays present when that architecture is documented.
- `secrets.sh`: checks that agenix secret definitions, owners, and consumers remain aligned.
- `auth-routing.sh`: checks OIDC client IDs, fileshare auth flow, reverse-proxy routing, and the documented public/private app boundary.
- `apparmor.sh`: checks that every referenced generated AppArmor profile has a matching policy key and that critical unit names stay aligned.
- `run-all.sh`: runs the repository policy suite together from one entrypoint.
- `dietpi.sh`: runs live DietPi companion checks over SSH using `vars.piLanIP` and `DIETPI_SSH_TARGET` when needed.
- `lib.sh`: shared helper functions used by the test scripts.

Run manually from the repository root:

```bash
tests/run-all.sh
tests/run-all.sh --with-runtime
tests/dietpi.sh
DIETPI_SSH_TARGET=dietpi@192.168.0.123 tests/dietpi.sh
```

Prerequisites:

- `nix`
- `rg`

The test scripts use `nix eval` where host-specific values from `vars.nix` should remain authoritative, and `rg` for source assertions.

`tests/run-all.sh` runs the static repository policy suite.
`tests/run-all.sh --with-runtime` also runs the live DietPi companion check.
`scripts/check-repo.sh` uses `tests/run-all.sh`, so the normal repository validation path stays static and deterministic.
`tests/dietpi.sh` defaults to `root@<piLanIP>` using the `piLanIP` value from `vars.nix`. Set `DIETPI_SSH_TARGET` if the DietPi SSH login user is different or root SSH login is disabled.
DietPi-specific checks are skipped unless `enableDietPiCompanion = true` in `vars.nix`.
