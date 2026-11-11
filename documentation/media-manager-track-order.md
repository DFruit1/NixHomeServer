# Authoritative track order

In Library health, choose **Renumber tracks…**, arrange the complete album or
book, then **Preview track order**. Confirm the server preview to submit one
album plan. Nothing in the live library changes during preview.

Confirmation writes the same chosen order in these forms:

- Native embedded track number and total (`1/N` through `N/N`), with disc number
  and total `1/1`. This deliberately flattens the selected folder into one
  continuous sequence; retaining old disc numbers could override its order.
  Existing secondary tags are updated too. MP3 uses ID3v2.3 for older players;
  FLAC/Ogg/Opus use Vorbis comments and M4A/M4B use MP4 tags.
- Matching zero-padded filename prefixes (`01`, `02`, …).
- `playlist.m3u`, `playlist.m3u8`, `playlist.pls`, `playlist.xspf` and any existing
  playlists with those extensions in the folder, rewritten in the same order.
  XSPF uses escaped relative file URIs; the other playlists use local filenames.
- `track-order.json`, recording each source/final path, track number/total and
  disc number/total. This is a portable recovery/inspection manifest, not a
  claim that arbitrary players understand this JSON format.

The supported rewrite formats are MP3, FLAC, M4A, M4B, Ogg Vorbis and Opus.
Unsupported audio siblings, changed catalog fingerprints, missing/duplicate
tracks, unreadable files or occupied destinations block preparation. The whole
folder must be selected. Limits are 500 tracks, 512 MiB per file and 2 GiB total
source audio per preview. No new audio encoding is performed.

[Jellyfin reads music ordering from audio metadata](https://jellyfin.org/docs/general/server/media/music/).
[Audiobookshelf reads disc/track values from filenames and audio tags](https://audiobookshelf.org/docs/documentation/libraries/book-library/directory-structure/).
Tags, filenames and ordered playlists therefore agree; sidecars alone cannot
make every player obey an order. Refresh/rescan other players after completion.
Their existing library caches, shuffle, manual playlists or queues may still
need to be cleared or disabled. This operation does not edit an external
player's database or change unrelated album/title/artist/artwork fields.

## Preservation and recovery

Media Manager copies each audio file to staging, updates its tags and reopens it
to verify all written ordering tags. Tests cover the risk of losing irreplaceable
media during a rewrite: original bytes, encoded audio, unrelated tags and artwork
must survive. Staged copies are discarded if preparation fails or the unconfirmed
plan expires; a durable plan owns staging after insertion.

The existing owner/digest-bound confirmation and serialized broker journal apply.
Each original remains under the album's `superseded/` directory with its original
format followed by `.backup` so scanners do not find a second playable copy.
Replaced playlists/manifests are also archived. The plan preserves existing
file-specific `.nfo`/`.opf` overrides and carries them to the final audio name.
Folder-level album metadata remains unchanged.

Filename cycles move through unique non-playable `.pending` paths before final
installation. Filesystem operations retain containment, fingerprint checks and
no-overwrite semantics. The multi-file plan is recoverable, not a filesystem
transaction: failure can leave a partially applied sequence. Inspect **Activity**,
resolve its reported conflict and retry that plan before rescanning or starting
another sequence. Do not delete archived originals or move intermediate paths
while a plan is unfinished. Completed action ordinals are not reapplied.
