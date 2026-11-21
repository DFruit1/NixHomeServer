# disc-to-jellyfin

An interactive CLI that converts DVD ISO images into efficient H.264 MKV files
and organises them using Jellyfin's preferred movie and TV naming. NTSC and PAL
DVDs are detected automatically.

## Run it

From the directory containing the ISO files:

```sh
./disc-to-jellyfin
```

That launcher runs the package from the repository flake (`packages.<system>.mkvmaker`),
which provides known-compatible HandBrake and FFprobe binaries. Run it from a
checkout of the NixHomeServer repository. You do not need Cargo, a development
environment, or a manual `nix shell`. Subsequent runs reuse the Nix result.

Check the complete runtime at any time:

```sh
./disc-to-jellyfin --doctor
```

Optional permanent installation:

```sh
nix profile install /path/to/NixHomeServer#mkvmaker
disc-to-jellyfin
```

## Interactive workflow

The app guides you through:

1. ISO selection and disc ordering.
2. Main-feature extraction or a detailed title scan.
3. Movie versus TV-series organisation.
4. Jellyfin name, year, and optional provider ID.
5. Per-disc TV season/episode numbering or per-disc movie primary titles.
6. Audio compatibility and video quality presets.
7. A complete output plan and disk-space check before encoding.

Title scans show duration, resolution, frame rate, audio/subtitle counts,
chapters, detected main feature, and likely play-all compilations. Scans are
cached and automatically invalidated when an ISO or HandBrake version changes.

The last output directory and encode preferences are stored in
`$XDG_CONFIG_HOME/disc-to-jellyfin/config.json`, or
`~/.config/disc-to-jellyfin/config.json`.

## Jellyfin layouts

Movie and multi-disc movie:

```text
Movie Name (2000) [tmdbid-1234]/
├── Movie Name (2000) [tmdbid-1234]-disc1.mkv
└── Movie Name (2000) [tmdbid-1234]-disc2.mkv
```

With all movie titles selected, each ISO gets its own primary movie part and
the other titles go into `extras/`.

TV series:

```text
Series Name (1976) [tvdbid-1234]/
└── Season 01/
    ├── Series Name (1976) S01E01 - Pilot.mkv
    └── Series Name (1976) S01E02.mkv
```

The provider tag belongs to the series folder, where Jellyfin reads it to pick
the right show. Episode files name the series and numbers only; repeating the
tag in every file changes no Jellyfin match and only makes the library harder to
read. Movies keep the tag in both the folder and the file because Jellyfin
matches multi-version prefixes against the folder name.

HandBrake cannot retain interactive DVD menus. “All titles” means all video
titles you select after the scan.

## Video quality

The recommended `balanced` preset matches HandBrake's HQ DVD approach: software
x264 High Profile, RF 18, slow preset, selective comb detection/deinterlacing,
source cadence, anamorphic display ratio, and conservative crop detection.
There are also `compact`, `maximum`, and `fast` presets. These settings avoid
upscaling and preserve both NTSC and PAL timing for Jellyfin.

All modes preserve chapters, metadata, track names, and supported bitmap/text
subtitles as switchable MKV tracks—nothing is burned into the video.

Audio profiles:

- `standard` (recommended): AAC stereo first for broad Jellyfin Direct Play,
  followed by the original track. Unsupported lossless source audio falls back
  to lossless FLAC24.
- `compatible`: AAC stereo only, at 192 kbit/s per source track.
- `archive`: original audio passthrough, with lossless FLAC24 fallback.

## Automation

```sh
# Recursively discover ISOs and interactively plan them
./disc-to-jellyfin --recursive /media/dvd-isos

# Fully specified, non-interactive preview
./disc-to-jellyfin /media/show \
  --recursive --kind tv --name "Series Name" --year 1976 \
  --all-titles --min-duration 900 \
  --output /srv/jellyfin/shows \
  --profile standard --video-preset balanced \
  --dry-run --yes
```

Run `./disc-to-jellyfin --help` for every option.

## Episode identification (server)

The server's importer also ships `disc-identify`, which names TV episodes
before they reach Jellyfin:

```sh
disc-identify disc --iso DISC.iso --title 3:3047 --title 4:2952 \
  --name-hint "Allcreaturesgreatandsmall" --bonsai-url http://127.0.0.1:8094/v1
disc-identify content --context disc.json --video E1.mkv --title 3 \
  --parakeet parakeet-cli --parakeet-model parakeet.bin
```

`disc` uses the ripper's TheDiscDB sidecar or the episode titles printed on the
DVD menus, cross-checked against TVmaze. `content` compares a transcript of each
encoded title with TVmaze summaries and OpenSubtitles text. Both print one JSON
object, and `status` is `identified` only for consecutive episodes of one season.
See [the operations runbook](../../documentation/operations.md#identifying-tv-episodes)
for how held discs are confirmed.

### Measuring identification accuracy

`identify_eval.py` is an on-demand evaluation (not a CI check). It groups
correctly named library episodes into synthetic 1–4 title discs and runs
`disc-identify content` with four disc-stage contexts: series known without a
proposal (`a`), with the correct proposal (`b`), with a proposal shifted one
episode (`c`, must never be identified as proposed), and with a second
candidate series (`d`, for `--rival`). Episodes are compared by normalised
title, so a library layout that differs from TVmaze's numbering is not counted
as wrong. It writes `identify-eval.json` and a `.txt` summary under `--work`;
`identified-WRONG` is the number that matters.

Run it on the server as `mkvmaker`, at idle priority, read-only on the library,
with the deployed tool paths from `systemctl cat mkvmaker-import-worker`:

```sh
S=$(sudo mktemp -d /tmp/identify-eval.XXXXXX); sudo chown mkvmaker: "$S"
sudo cp identify_eval.py "$S/"
sudo systemd-run --wait --pipe --collect -p User=mkvmaker -p Group=mkvmaker \
  -p SupplementaryGroups=files-shared-users -p Nice=19 -p CPUWeight=idle \
  -p IOWeight=1 -p IOSchedulingClass=idle -p ProtectSystem=strict \
  -p ProtectHome=yes -p ReadWritePaths="$S" \
  python3 "$S/identify_eval.py" --work "$S" \
  --identifier …/bin/disc-identify --ffmpeg …/bin/ffmpeg \
  --parakeet …/bin/parakeet-cli --parakeet-model …/parakeet.bin \
  --bonsai-url http://127.0.0.1:8094/v1 \
  --show 'Sherlock Holmes (1984)=3255' --show 'Rumpole of the Bailey=12144' \
  --show 'All Creatures Great and Small (1978)=8090' --rival 8090=42836 \
  --episodes-per-show 5 --seed 3
sudo rm -rf "$S"   # holds transcripts and subtitle text
```

`--plan-only` lists the discs first. Subtitles are off by default; the
uploader's OpenSubtitles quota is small, so allow only a few requests with
`--subtitle-budget 6 --owner NAME --subtitle-socket
/run/media-manager-provider-system/system.sock`. With a `disc-identify` that has
`--replay-cache`, each MKV is transcribed once per excerpt window and Bonsai
answers are kept, so `--offline --variant 'name=--bonsai-min-confidence 0.7'`
re-runs the identifier's own rules under other thresholds without ASR, Bonsai,
subtitle or TMDB requests (a recorded subtitle counts as a free cache hit;
TVmaze lists come from the week-long `--cache-dir`). Titles run one at a time
because the Bonsai gate is shared.

## Audio CD import (server)

The package also ships `audio-import`, which publishes the desktop ripper's
audio CD and audiobook data-CD ISOs into Audiobookshelf:

```sh
audio-import --inbox /srv/iso/_AudioCDs=/srv/audiobooks --state-dir /var/lib/audio-import
```

Each run handles every book folder that is ready and exits. A book is
published only when its whole set of discs is present and each disc is an exact
MusicBrainz Disc ID match or carries the author and title typed at the drive;
anything else waits in the inbox or is held for a person. It needs `ffmpeg`,
`ffprobe` and `7zz` (`--ffmpeg`, `--ffprobe`, `--sevenzip`). See
[the operations runbook](../../documentation/operations.md#automatic-audio-cd-import).

## Reliability and recovery

- Every ISO is scanned, even in main-feature mode, so title selection and
  completion validation are deterministic.
- Encodes use a same-filesystem partial file and an atomic no-clobber publish.
- MKVPropEdit removes HandBrake's encode-time Matroska date so Jellyfin cannot
  mistake the conversion year for the release year.
- FFprobe verifies Matroska/H.264, duration, audio, subtitles, chapters, and
  the absence of that misleading encode date.
- Resume only skips an output whose completed manifest exactly matches its ISO,
  title, HandBrake version, audio profile, RF, and x264 preset.
- Per-output locks prevent two instances from corrupting the same job.
- Ctrl-C terminates HandBrake and removes only the active partial file.
- Failed jobs do not stop later jobs; a failure summary is printed at the end.
- Manifests and full HandBrake logs live outside the media library under
  `$XDG_STATE_HOME/disc-to-jellyfin/jobs` or
  `~/.local/state/disc-to-jellyfin/jobs`.
- `--dry-run` prints the complete plan and exact HandBrake commands.

## Process deadlines

HandBrake scans have a ten-minute deadline. Encodes keep the selected quality
and have a 24-hour wall deadline plus a thirty-minute output-growth deadline.
Output validation has a sixty-second deadline and a 4 MiB output limit per
stream. Cancellation and timeout kill the child process group and reap the
leader; failed active partial outputs are removed through the normal error path.
The import supervisor also bounds the converter to 24 hours and terminates its
descendant groups on shutdown, lease loss, or timeout, allowing queue retry and
later items to proceed.

## Developer verification

```sh
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
```

The Nix packaging lives in `default.nix` and is built by the repository flake
(via `custom_apps/rust/lib/mk-rust-app.nix`); the repository validation gate
covers it.

Normal users do not need to run these commands.
