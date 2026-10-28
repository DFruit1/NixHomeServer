# Module verification

Read the scripts before executing them. These are coverage owners, not a command
list: `scripts/tests/test-module-structure.sh`,
`scripts/tests/test-canary-target-coverage.sh`, and the disable/removal matrices.
The structural script scans all modules; the shell matrix runners cover multiple
apps. They are not focused single-app checks.

Inspect the changed catalog entry and facet imports locally. For evaluation
limited to one removal case, the existing matrix supports a bounded variant.
Run only when that system evaluation is within the explicitly requested scope:

```bash
task_app="immich" # replace with the affected catalog app
NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$PWD" \
NIXHOMESERVER_MODULE_VARIANTS="without-$task_app" \
  nix eval --impure --json --file scripts/tests/module-removal-matrix.nix
```

Inspect the returned case's `valid`, `removedOwnedSecretsAbsent`,
`guardedServicesValid`, `removedGuardedServicesAbsent`, and registry/persistence
evidence relevant to the app; producing JSON alone does not prove the contract.

For disable behavior, `scripts/tests/module-disable-matrix.nix` takes
`flake`, `hostName`, and `requestedCaseNames = [ "<app>" ];`. Select the actual
host from settings and a case that exists in that expression; do not silently
substitute a different app. Assert absence of the affected runtime/routes/
identities/secrets and retention of its persistence.

Settings-level checks can stay local. Full-system evaluation uses the existing
batched remote-evaluation helper when remote work has explicit authority; the
recipe above does not itself grant it. Do not run repository-wide matrices or
full gates by default. After an explicitly authorized new-app deployment, run
the authenticated canary as specified by safe-change.
