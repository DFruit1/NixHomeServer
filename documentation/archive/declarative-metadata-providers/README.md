# Archived declarative metadata-provider setup

Archived on 2026-11-17. Media Manager's metadata providers (TMDB,
OpenSubtitles, AcoustID, Google Books and the rest) are set by each person in
Media Manager → Online services. The provider broker encrypts each account in
`/var/lib/media-manager-provider/provider-accounts.sqlite3`
([ADR 0005](../../decisions/0005-media-provider-accounts-and-lookup.md)).
Nothing here is active configuration or a source of permissions.

The last revision with the declarative setup in place is `13ae0fd`. It held:

| Removed | What it did | Live use when archived |
| --- | --- | --- |
| `age.secrets.openSubtitlesCredentials` and `secrets/openSubtitlesCredentials.age` | Decrypted a server-wide OpenSubtitles login to `/run/agenix/openSubtitlesCredentials` | None: no service was given the file |
| `age.secrets.acoustidApiKey` and `secrets/acoustidApiKey.age` | Decrypted a server-wide AcoustID key to `/run/agenix/acoustidApiKey` | None |
| `secrets/manifest.nix` entries and the `opensubtitles-credentials-json` / `acoustid-credentials-json` validators | Let `generate-secrets` stage and check those two inputs | None |
| Media Manager web `MEDIA_MANAGER_OPENSUBTITLES_CREDENTIALS_FILE`, `MEDIA_MANAGER_ACOUSTID_API_KEY_FILE` and `MEDIA_MANAGER_TMDB_API_KEY_FILE` | Host-key fallbacks used only when no provider broker was configured | None: NixOS always configures the broker, and Nix never set these variables |
| Media Manager web `POST /api/v1/metadata/tmdb/search` and `/details` | TMDB search with the host key | None: the app uses `/api/v1/provider-lookups/tmdb/*` with the caller's account |

`secrets/` here holds the two ciphertexts unchanged, encrypted to the server's
age key. Their SHA256 sums are:

```text
97ab469f526a79da5b8ecfba1fa4ee2b10b2a9cb0bd728b9bf5b111c217aa81b  acoustidApiKey.age
f3837db01220459471be47622d44ccd68adf233d8267a735dce34c77e018c527  openSubtitlesCredentials.age
```

The provider broker's host TMDB key, `repo.mediaManager.tmdbApiKeyFile`
(never set), was removed on 2026-11-19, the last declarative piece. The DVD
identifier's TMDB episode-numbering check (`POST /system/v1/tmdb/tv-episodes`
on the broker's system socket) now uses the uploader's saved TMDB account.

To restore any of it, revert the archiving commits or copy the pieces back from
`13ae0fd`.
