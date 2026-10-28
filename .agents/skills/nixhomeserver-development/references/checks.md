# Focused local checks

Run from the repository root unless a recipe changes directory. Read the
actual manifest/script first: wrappers and lifecycle hooks can broaden a run.
These are command shapes; replace angle-bracket arguments with real targets.

Test creation and execution are separate decisions. Under AGENTS.md, new or
expanded automated tests need demonstrated repeated regressions or a concrete
catastrophic risk. Existing focused tests, syntax checks, direct reproductions,
and rendered inspections remain available without inventing new suites.

- Rust: `cargo test --manifest-path custom_apps/Cargo.toml -p <package> <test-filter>`.
  Use the existing development environment and package name from its manifest.
  This can compile dependencies; use the authorized offload workflow only when
  remote work is explicitly in scope.
- Node: in the owning app, inspect `package.json`. For Vitest,
  `pnpm exec vitest run <test-file> -t <test-name>` selects one behavior.
  Run the app's typecheck when types change. Do not assume `pnpm check` is
  focused: Homepage's check also runs its entire application test suite.
  Preserve any setup required by the package's existing pretest hook.
- Shell: `bash -n <changed-script>`, then the individual regression script
  covering the changed behavior. Inspect that test before running it.
- Python operations glue: use its existing focused tests. A syntax-only check
  can use `ast.parse` without creating bytecode or importing live integrations.
- Nix: `nix-instantiate --parse <changed-file>` checks syntax only.
  Settings-level evaluation can stay local. For application disable/removal
  evidence, use the module skill's bounded recipe. Full-system evaluation and
  remote execution follow safe-change and existing explicit test scope.
- Documentation/skills: inspect the diff, metadata, linked paths, command scope,
  and instruction consistency. No application build is implied.
- Frontend: inspect the changed rendered route and interaction under
  frontend-design; a mocked test or successful build is not visual evidence.

Do not automatically run `cargo test --workspace`, all-app tests,
`scripts/tests/run-script-tests.sh`, `scripts/validate-repo.sh` (even lean),
full flake checks, broad builds, or end-to-end/VM suites. `AGENTS.md` owns test
scope. Keep integral checks of an explicitly requested deploy/release intact.

Report the command, actual result, and covered behavior. Skipped tools, zero
matched tests, interrupted runs, and zero inspected elements are unverified.
