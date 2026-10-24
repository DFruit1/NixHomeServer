Before source writes, claim feature directories yourself with
`python3 ~/.hermes/scripts/directory_claims.py claim <directory> [...]`.
Use an exclusive assigned worktree; broad aggregate directories are refused.
Ownership and requests live under the repository's shared Git directory, never
in card comments. Inspect `list`; use `request <directory> --reason "<change>"`
to ask the current holder directly. The holder makes the change or commits and
releases it; requests do not grant write permission. No coordinator is involved.
Use `release` after committing and stopping writable processes. Claims never
expire or transfer implicitly. Never edit claim records or remove their locks.
Native writes check ownership; terminals confine source writes to owned folders.
Run `git add -- <explicit files>` and `git commit -m "<message>"` as separate
terminal calls so the runtime can validate their scopes. Shared integration files
use the single `@shared-files` claim and native write/patch tools. Existing role,
approval, review and deploy limits still apply. Read
`~/.hermes/scripts/hermes-directory-claims.md` for recovery and supported commands.
