# Runtime Validation Report Template

Use this to record a real validation run after a deploy, after auth changes, or
before handing the system to a new operator.

If you want a scaffold with the current hostnames already filled in, generate
one with:

```bash
./scripts/runtime-validation-report.sh
```

## Run metadata

- Date:
- Operator:
- Environment:
- NetBird client used:
- Build or generation tested:
- Notes:

## Baseline readiness

- `./scripts/runtime-readiness.sh`:
- Public path reachable:
- Private NetBird path reachable:
- DNS answers correct:
- `/mnt/data` mounted:
- `/mnt/parity` mounted:
- `snapraid status`:
- `snapraid diff`:

## Personas used

| Persona | Username | Groups | Notes |
|---|---|---|---|
| Delegated operator | `admindsaw` |  |  |
| Daily-use user | `dsaw` |  |  |
| Baseline test user | `test-basic` | `users` |  |
| Files test user | `test-files` | `users`, `fileshare_users` |  |
| App login test user | `test-app-user` | `users`, app-specific login group |  |
| App admin test user | `test-app-admin` | `users`, app-specific admin group |  |
| Optional delegated admin test user | `test-idm-admin` | `users`, `idm_admins` |  |

## Kanidm delegated admin bootstrap

- `admindsaw` login:
- `kanidm reauth`:
- Person inspection works:
- User creation works:
- Group membership change works:
- Break-glass accounts avoided:
- Notes:

## Service results

### Files / Copyparty

- URL: `https://files.<domain>`
- Logged-out behavior:
- `test-basic` denied:
- `test-files` allowed:
- `/my-files` private path:
- `/shared/exchange` shared path:
- `/shared/public` shared path:
- `/shared/photos` ingest path:
- `/shared/documents` ingest path:
- Upload:
- Download:
- Rename:
- Delete:
- Any proxy loop or callback error:
- Notes:

### Immich

- URL: `https://photos.<domain>`
- `test-basic` denied or unusable:
- `immich-users` login works:
- First-login user row created:
- Photo upload works:
- Thumbnail and metadata visible:
- `immich-admin` admin automatic:
- `admindsaw` still admin:
- Notes:

### Paperless

- URL: `https://paperless.<domain>`
- `test-basic` denied or unusable:
- `paperless-users` login works:
- First-login user row created or linked:
- Document upload works:
- Document processing behaves normally:
- `paperless-admin` admin automatic:
- Local recovery superuser still present:
- Notes:

### Audiobookshelf

- URL: `https://audiobooks.<domain>/audiobookshelf/`
- `test-basic` denied or unusable:
- `audiobookshelf-users` login works:
- First-login user row created or linked:
- OIDC redirect path works:
- `audiobookshelf-admin` admin automatic:
- `admindsaw` root bootstrap still works:
- Playback or browse test:
- Notes:

### Kavita

- URL: `https://books.<domain>`
- `test-basic` denied or unusable:
- `kavita-login` login works:
- First-login user row created:
- `kavita-admin` admin automatic:
- Browse or open works:
- Admin library-management test:
- Notes:

### Jellyfin

- URL: `https://videos.<domain>`
- Local admin login:
- Local user login:
- Browse or playback test:
- Notes:

### Jellyseerr

- URL: `https://jellyseerr.<domain>`
- Public settings show `applicationUrl=https://jellyseerr.<domain>`:
- Internal Jellyfin target is `127.0.0.1:8096`:
- Jellyfin-backed sign-in:
- Request creation:
- Admin or settings access:
- Notes:

### SMB over NetBird

- SMB only reachable on NetBird:
- `homes` share works:
- `exchange` share works:
- `public` share works:
- `photos-upload` share works:
- `documents-upload` share works:
- Notes:

## Access-control regression summary

| Service | `users` only denied | Wrong app group denied | Login group works | Admin group works | Admin needed local follow-up | Notes |
|---|---:|---:|---:|---:|---:|---|
| Files / Copyparty |  |  |  |  | n/a |  |
| Immich |  |  |  |  |  |  |
| Paperless |  |  |  |  |  |  |
| Audiobookshelf |  |  |  |  |  |  |
| Kavita |  |  |  |  |  |  |
| Jellyfin | n/a | n/a | n/a | n/a | n/a |  |
| Jellyseerr | n/a | n/a | n/a | n/a | n/a |  |

## Storage and write-path validation

- Copyparty path:
- Immich managed path:
- Immich external path:
- Paperless consume path:
- Paperless archive path:
- Paperless export path:
- Audiobookshelf appdata path:
- Kavita appdata path:
- Jellyfin appdata path:
- Any permission anomaly:
- Any unexpected `snapraid diff` entries:

## Cleanup

- Temporary Kanidm users removed:
- Temporary app-local content removed:
- Persistent local rows intentionally left behind:
- Apps needing app-local admin promotion:
- Follow-up documentation updates needed:

## Final outcome

- Overall status:
- Blockers:
- Residual risk:
- Next action:
