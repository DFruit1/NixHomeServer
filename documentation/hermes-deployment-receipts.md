# Hermes deployment receipts

`deployment-receipt.py` checks that whole-set review, coordinator decision,
current source and the supplied guarded-test stamp agree. It reads existing
native records and reuses the repository's archive and version=2 stamp helpers.
Archive, verdict-validator and stamp helpers come from the reviewed `--repo`
checkout, so an installed sibling validator cannot override that source's checks.
It never deploys, writes cards or grants permission. The deploy gate remains a
workflow convention; `deploy.sh` does not enforce this checker.

## Prepare and review

Commit the completed source before review. Identify the full last-deployed
revision from existing deployment evidence. This helper cannot reconstruct that
historical baseline: record the evidence reference and resolve uncertainty
through the existing coordinator path. Confirm the intended hostname and SSH
target against the guarded deployment configuration.

From the reviewed checkout, capture a scope:

```bash
python3 ~/.hermes/scripts/deployment-receipt.py snapshot \
  --repo "$PWD" --base FULL_LAST_DEPLOYED_COMMIT \
  --baseline-evidence 'Existing deployment record/card reference' \
  --hostname HOSTNAME --target USER@HOST --actions test switch
```

The snapshot requires a clean Git checkout, including no non-ignored untracked
files or hidden assume-unchanged/skip-worktree index flags, and an ancestor
baseline. It hashes the **extracted canonical deployment
archive** with `nix hash path`, excluding Git metadata and ignored files exactly
as deployment does. The reviewed scope has these exact fields:

```json
{
  "schema_version": 1,
  "kind": "nixos-whole-set",
  "base_revision": "FULL_LAST_DEPLOYED_COMMIT",
  "head_revision": "FULL_REVIEWED_COMMIT",
  "baseline_evidence": "Existing deployment record/card reference",
  "source_hash": "sha256-BASE64_NAR_HASH",
  "hostname": "HOSTNAME",
  "target": "USER@HOST",
  "actions": ["test", "switch"],
  "inputs": {}
}
```

Declare every relevant non-secret mutable file with repeatable
`--input NAME=PATH`. Names map to SHA-256 digests; paths and contents are not
included in the scope. Supply the complete manifest on every check. Each file
must be regular, stable and at most 8 MiB; at most 16 inputs are supported.
Symlinks are resolved before known credential/secret paths are rejected. The
caller must classify contents: a filename check cannot detect every secret.
Never supply credentials or stage plaintext secrets. Freeze relevant writers;
the checker cannot discover an undeclared external input or prevent later edits.

Put the scope on the existing whole-set verification card and paired coordinator
decision; the decision depends on the verification. The reviewer independently
reproduces the snapshot, reviews the actual baseline..HEAD range and runs the
required gate. Its native completion metadata retains `verdict`, `revision` and
`checks`, and adds the complete snapshot as `deployment_scope`. A rejected review
does not release deployment. Use a fresh accepted review after fixes.

## Record the coordinator decision

After acceptance, `head-coordinator` uses its existing native comment tool on the
paired decision card. The entire comment is JSON with this exact shape:

```json
{
  "deployment_decision": {
    "schema_version": 1,
    "approved": true,
    "review_task": "t_REVIEW",
    "review_run_id": 123,
    "scope": {}
  }
}
```

Replace `scope` with the complete accepted snapshot and `review_run_id` with the
latest native verification run ID. Newer structured decisions supersede older
ones, including `approved: false`. New owner feedback after the decision requires
coordinator reconciliation and a fresh decision. Keep the decision open while
test/switch is pending; a final done decision cannot authorize another deployment.
No raw SQL writes or standalone state store are involved.

## Check before each guarded action

```bash
python3 ~/.hermes/scripts/deployment-receipt.py check \
  --repo "$PWD" --board BOARD --review t_REVIEW --decision t_DECISION \
  --hostname HOSTNAME --target USER@HOST --action test &&
nix run .#deploy -- --action test
```

Only the already-authorized coordinator/operator executes deployment. Preserve
the dashboard's allocation and existing health/rollback checks. If a relevant
mutable input was declared, repeat every `--input NAME=PATH` on the check.

After a green guarded test, obtain the target's root-only
`/var/lib/nixhomeserver-deploy/last-tested-HOSTNAME.stamp` through the existing
authorized operator path. Keep the non-secret evidence in the one task-named
temporary directory and clean it up. Then:

```bash
python3 ~/.hermes/scripts/deployment-receipt.py check \
  --repo "$PWD" --board BOARD --review t_REVIEW --decision t_DECISION \
  --hostname HOSTNAME --target USER@HOST --action switch \
  --tested-stamp "$TASK_DIRECTORY/tested.stamp" &&
nix run .#deploy -- --action switch
```

The check requires the latest run overall to be a completed feature-reviewer
acceptance, all decision prerequisites done, a matching latest coordinator
decision, exact current scope and, for switch, a valid v2 stamp for that source.
Both review and decision scopes must satisfy the schema, including exact types.
It checks board evidence again after source capture. Invalid/missing evidence,
changed target/source/manifest, failed checks and superseded decisions fail
closed. JSON receipts identify native run/comment IDs and evidence hashes; keep
them on the owning cards/jobs, not in standing instructions.

The supplied stamp is evidence, not authenticated live target state. The guarded
deployer still revalidates the live stamp and activates its exact tested closure.
A receipt is point-in-time consistency evidence, not a lock, a signature or proof
that an old baseline was correct. Source/inputs changing after a check require a
fresh review/test. Reviewers never test-activate or switch, and the steward never
collects privileged stamps or writes decisions.

Validation: `bash scripts/tests/test-hermes-deploy-receipt.sh` exercises accepted
and superseded records, wrong profile/author, failed checks, changed scope,
read-only transactions, canonical archive capture and strict existing stamp
parsing. No live activation is needed.
