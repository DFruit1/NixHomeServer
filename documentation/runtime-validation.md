# Runtime Validation

Use this after a deploy, after major auth or routing changes, or when
onboarding a new operator. It turns the current access model into a repeatable
validation run instead of relying on ad-hoc app checks.

This runbook is ordered so you prove the infrastructure first, then identity
bootstrap, then first-login and write-path behavior for each app.

## Validation order

1. infrastructure and routing baseline
2. delegated admin bootstrap in Kanidm
3. new-user onboarding
4. app-specific first-login and admin bootstrap behavior
5. file, document, and media write paths
6. cleanup of temporary test users and test content

## Fast automated baseline

On the server:

```bash
./scripts/runtime-readiness.sh
```

This validates:

- core service units
- public and private HTTPS entrypoints
- Unbound answers for private hostnames
- mergerfs mount presence
- SnapRAID status and pending drift

If you want a results scaffold before the manual pass, generate one with:

```bash
./scripts/runtime-validation-report.sh
```

## Test personas

Use these concrete personas during validation:

| Persona | Purpose | Expected groups |
|---|---|---|
| `admindsaw` | delegated operator, bootstrap and admin path | seeded admin-intent groups plus `users` |
| `dsaw` | normal day-to-day identity | no global admin groups by default |
| `test-basic` | baseline identity only | `users` |
| `test-files` | Files validation | `users`, `fileshare_users` |
| `test-app-user` | per-app login validation | `users`, one `*-users` or `kavita-login` group |
| `test-app-admin` | per-app admin validation | `users`, one `*-admin` group |
| `test-idm-admin` | delegated Kanidm admin validation | `users`, `idm_admins` |

Defaults:

- create temporary Kanidm users with unique names
- use small disposable files only
- delete the temporary users when the validation pass is complete

## Expected Behavior Matrix

| Service | User outside app group | User in login group | User in admin group | Notes |
|---|---|---|---|---|
| Files / Copyparty | denied by OAuth2 Proxy | allowed through proxy | same as login user | auth boundary is proxy-side |
| Immich | OIDC flow should not grant usable access | first OIDC login creates local account | should become intended app admin; verify app state after first login | local recovery admin may still be needed |
| Paperless | OIDC flow should not grant usable access | first OIDC login creates or links local account | should become intended app admin or be promoted through documented app-local step | keep local recovery superuser |
| Audiobookshelf | OIDC flow should not grant usable access | first OIDC login creates or links local account | verify admin promotion after first OIDC login | root bootstrap remains break-glass |
| Kavita | OIDC flow should not grant usable access | first OIDC login creates local account | OIDC role claim should map admin cleanly | best current reference implementation |
| Jellyfin | not applicable | local auth only | local auth only | no Kanidm OIDC here |
| Jellyseerr | not applicable | Jellyfin-backed | Jellyfin/Jellyseerr local | bootstrap through Jellyfin |

## 1. Infrastructure and routing baseline

Run `./scripts/runtime-readiness.sh` first and stop if it fails.

Then confirm manually:

- `https://id.<domain>` and `https://files.<domain>` are reachable over the
  public path
- `paperless`, `photos`, `audiobooks`, `books`, `video`, and `jellyseerr`
  require NetBird reachability
- private names resolve to the server NetBird IP
- public names do not resolve to the NetBird IP
- `/mnt/data` is mounted as `fuse.mergerfs`
- `/mnt/parity` is mounted

Success criteria:

- no failed units in the core path
- no unexpected public exposure of private apps
- storage is mounted before any write-path testing

## 2. Delegated Kanidm admin bootstrap

Validate `admindsaw` before creating any temporary users.

Steps:

1. log into Kanidm as `admindsaw`
2. run `kanidm reauth`
3. verify you can inspect a person, create a temporary person, and change group
   membership
4. verify this works through the CLI or `kanidm-user-tui`, not only the web UI

Success criteria:

- `admindsaw` can manage users and groups without using break-glass `admin` or
  `idm_admin`
- `admindsaw` is the normal operator path
- break-glass accounts stay unused for routine work

## 3. New-user onboarding

Use one fresh temporary account to prove the baseline identity model.

Steps:

1. create `test-basic`
2. add only `users`
3. verify the person can authenticate to Kanidm
4. verify they cannot use Files, Immich, Paperless, Audiobookshelf, or Kavita
5. add one app login group
6. verify only that app becomes accessible
7. remove the group again and verify access is lost

Success criteria:

- `users` alone does not grant app access
- app access is controlled only by app-specific groups
- group removal revokes access cleanly

## 4. Files / Copyparty

This is the highest-priority public app validation because it is the only
internet-facing file-write surface besides Kanidm.

Steps:

1. log out of any existing session
2. visit `https://files.<domain>`
3. verify you are forced through OAuth2 Proxy before reaching Copyparty
4. sign in as `test-basic` and confirm access is denied before a usable file UI
5. sign in as `test-files` and confirm access succeeds
6. upload a small disposable file
7. download the same file
8. rename it
9. delete it
10. confirm it disappears from the UI or backing path

Success criteria:

- only `fileshare_users` can pass the proxy
- authenticated Files users can upload, download, rename, and delete
- no redirect loop between Caddy, OAuth2 Proxy, and Kanidm

Current implementation detail to verify:

- [`modules/copyparty/default.nix`](/home/dsaw/Projects/NixOS/modules/copyparty/default.nix)
  now exposes per-user, shared, and ingest-specific paths. Verify:
  - `/me/<username>` stays scoped to the authenticated user
  - `/shared/exchange` and `/shared/public` behave as intended for shared use
  - `/incoming/photos` feeds the Immich external-library root
  - `/incoming/documents` feeds the Paperless consume directory

## 5. Immich

Test with `test-basic`, `test-app-user`, `test-app-admin`, then `admindsaw`.

Steps:

1. `test-basic` attempts `https://photos.<domain>`
2. confirm login does not result in usable app access
3. add `immich-users` to `test-app-user`
4. sign in and verify the first successful OIDC login creates the local user
   row
5. upload a small photo
6. verify thumbnail generation, metadata, and library visibility
7. add `immich-admin` to `test-app-admin`
8. sign in and verify intended admin behavior
9. confirm whether admin is automatic or still needs local follow-up
10. confirm `admindsaw` still retains admin access

Success criteria:

- first successful OIDC login creates the user
- normal users can upload media
- admin behavior works or is explicitly recorded as needing local promotion

Storage expectation to verify:

- native uploads stay under `/mnt/data/media/photos/managed`
- externally staged imports land under `/mnt/data/media/photos/external`
- Copyparty and SMB do not write into the managed Immich root

Current observed state:

- `admindsaw` exists in the Immich database
- `admindsaw` is currently marked as an Immich admin

## 6. Paperless

Test with `test-basic`, `test-app-user`, `test-app-admin`, then `admindsaw`.

Steps:

1. `test-basic` attempts `https://paperless.<domain>`
2. confirm no usable access
3. add `paperless-users` to `test-app-user`
4. sign in and verify the local Paperless row is created or linked
5. upload a small PDF or image document
6. verify it lands in the UI and begins processing
7. confirm metadata or OCR behavior is normal for the sample
8. add `paperless-admin` to `test-app-admin`
9. verify admin behavior
10. verify the local recovery superuser still exists and is not the normal path

Success criteria:

- first OIDC login provisions the user
- document ingestion works end to end
- admin intent is honored or any app-local promotion gap is recorded

Storage expectation to verify:

- incoming files land under `/mnt/data/media/documents/consume`
- Paperless archives into `/mnt/data/media/documents/archive`
- exports land in `/mnt/data/media/documents/export`

Current observed state:

- `admindsaw` exists in the Paperless database
- `admindsaw` is currently `is_superuser=1` and `is_staff=1`

## 7. Audiobookshelf

Test with `test-basic`, `test-app-user`, `test-app-admin`, then `admindsaw`.

Steps:

1. verify `https://audiobooks.<domain>/audiobookshelf/` loads correctly
2. `test-basic` attempts sign-in and does not get usable access
3. add `audiobookshelf-users` to `test-app-user`
4. sign in and verify user creation or linking
5. verify the OIDC button and redirect URLs work cleanly
6. add `audiobookshelf-admin` to `test-app-admin`
7. verify admin capabilities after first login
8. log in as `admindsaw`
9. confirm the pre-bootstrapped root account still works as break-glass only
10. if a library already exists, verify browse and playback against one known
    item

Success criteria:

- OIDC is usable
- the root bootstrap path exists only as fallback
- additional admins either map correctly or the local-promotion gap is recorded

Current observed state:

- the local Audiobookshelf user `admindsaw` exists
- that user is currently of type `root`

## 8. Kavita

This is the cleanest group-mapped admin case and should be your reference proof
that OIDC group-to-role mapping works end to end.

Steps:

1. `test-basic` attempts `https://books.<domain>`
2. confirm no usable access
3. add `kavita-login` to `test-app-user`
4. sign in and verify account provisioning on first login
5. add `kavita-admin` to `test-app-admin`
6. sign in again and verify admin role mapping from Kanidm groups
7. if a library already exists, verify browse and open work
8. if admin library management is in scope, verify an admin can trigger a scan
   or manage the library without local-only promotion

Success criteria:

- first login provisions the user
- `kavita-admin` maps to app admin through OIDC group claims
- no manual local admin step should be required here

Current observed state:

- the OIDC settings row is present in the Kavita database
- account provisioning is enabled
- no local user rows existed yet when this validation document was written

## 9. Jellyfin and Jellyseerr

These are not part of the Kanidm OIDC matrix and must be tested separately.

Jellyfin:

1. verify a local admin can sign in at `https://video.<domain>`
2. verify a normal local user can sign in if one exists
3. verify media browsing and playback of one known-good item

Jellyseerr:

1. open `https://jellyseerr.<domain>`
2. verify the app is wired to Jellyfin
3. sign in through the Jellyfin-backed flow
4. verify a request can be created
5. verify admin or settings access with the intended local admin path

Success criteria:

- Jellyfin remains local-auth only
- Jellyseerr uses Jellyfin-backed auth correctly
- bootstrap settings have not drifted

## 10. Access-control regression checks

For each app, explicitly test all four states:

- user in `users` only
- user in the wrong app group
- user in the correct login group
- user in the admin group

Record for each service:

- denied before app
- denied after login
- JIT user created or linked
- admin automatic
- admin required local follow-up

## 11. Storage and write-path validation

After app validation, run:

```bash
sudo findmnt /mnt/data /mnt/parity
sudo snapraid status
sudo snapraid diff
```

Then confirm:

- expected new files landed under the correct app data roots
- `snapraid diff` changed in a way consistent with app activity
- no mount or permission issue caused uploads to fail silently

Write paths that matter most:

- Copyparty: `${vars.dataRoot}/copyparty`
- Immich: `${vars.dataRoot}/immich`
- Paperless: `${vars.dataRoot}/paperless`
- Audiobookshelf: `${vars.dataRoot}/audiobookshelf`
- Kavita: `${vars.dataRoot}/kavita`
- Jellyfin: `${vars.dataRoot}/jellyfin`

## 12. Cleanup

After validation:

1. remove the temporary test users from Kanidm
2. remove temporary app-local content where appropriate
3. note any app that created a persistent local user row on first login
4. record any app where admin promotion was not purely group-driven

## Recording results

For each service, record:

- tested username
- Kanidm groups assigned
- URL used
- whether login succeeded
- whether access was correctly denied when expected
- whether first login created or linked a local user row
- whether upload, import, or playback worked
- whether admin rights were automatic or required local follow-up
- any redirect loop, callback mismatch, 403, or TLS error
- any storage or permission anomaly

Use [Runtime Validation Report Template](./runtime-validation-report-template.md)
or generate a fresh scaffold with `./scripts/runtime-validation-report.sh`.

If an app fails validation, update [Operations](./operations.md) with the
symptom and the fix path.
