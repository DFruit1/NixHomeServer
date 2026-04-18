# Tests

This directory now keeps only the slim active validation suite.

Active tests:

- `bootstrap-readiness.sh`: checks that active bootstrap files, archive paths, docs, and validation entrypoints are present and aligned with the simplified repo layout.
- `module-imports.sh`: checks that every active module directory with a `default.nix` is explicitly imported by `configuration.nix`.
- `deploy-wrapper.sh`: checks the guarded deploy helper contract.
- `secrets.sh`: checks agenix definitions, secret consumers, and secret-generation helper wiring.
- `core-config.sh`: checks the evaluated core service graph, data-disk stack, backup/mail-archive/power-management essentials, and confirms archived DietPi and rust-scaffold paths are gone from the active tree.
- `run-all.sh`: runs the active suite from one entrypoint.
- `lib.sh`: shared helper functions used by the test scripts.

Archived policy coverage lives under `_archive/tests/`.

Run manually from the repository root:

```bash
tests/run-all.sh
tests/core-config.sh
```

Prerequisites:

- `nix`
- `jq`
- `rg`

`tests/run-all.sh` is the canonical repo-local validation entrypoint used by `scripts/check-repo.sh`.
