# Known Issues and Follow-Ups

Tracked follow-ups that are **pre-existing on `master`** (verified at
`24ef52f`) and are unrelated to the portability work. Each section is written
so it can be filed as a GitHub issue by copying its title and body into
`gh issue create` (or into the GitHub web UI).

## 1. `--full` validation fails on Rust formatting drift

**Component:** `custom_apps/rust/apps/mail-archive-ui`
**Severity:** medium (blocks the full validation gate; no runtime impact)

**Symptom**

`scripts/validate-repo.sh --full` fails while building
`.#checks.x86_64-linux.mail-archive-ui-fmt`:

```
Diff in /build/nixhomeserver-rust-workspace-src/rust/apps/mail-archive-ui/src/canary.rs:156:
-fn plain_message(
-    subject: &str,
-    from: &str,
-    date: &str,
-    message_id: &str,
-    body: &str,
-) -> String {
+fn plain_message(subject: &str, from: &str, date: &str, message_id: &str, body: &str) -> String {
```

**Cause**

`cargo fmt -- --check` (cargo 1.97.0 in the pinned toolchain) now collapses the
parameter list of `plain_message` at
`custom_apps/rust/apps/mail-archive-ui/src/canary.rs:159`. This looks like
rustfmt toolchain drift rather than a deliberate style change; the working tree
is otherwise clean.

**Reproduction**

```bash
nix build ".#checks.x86_64-linux.mail-archive-ui-fmt" --no-link
# or
scripts/validate-repo.sh --full
```

**Suggested fix**

Run `cargo fmt` in the Rust workspace and commit the result, then confirm
`.#checks.x86_64-linux.mail-archive-ui-fmt` builds.
