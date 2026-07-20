# disc-to-jellyfin

An interactive CLI that converts DVD ISO images into efficient H.264 MKV files
and organises them using Jellyfin's preferred movie and TV naming. NTSC and PAL
DVDs are detected automatically.

## Run it

From the directory containing the ISO files:

```sh
./disc-to-jellyfin
```

That launcher uses the committed `app/flake.lock`, provides known-compatible
HandBrake and FFprobe binaries, and builds the small Rust frontend automatically
on its first run. You do not need Cargo, a development environment, or a manual
`nix shell`. Subsequent runs reuse the Nix result.

Check the complete runtime at any time:

```sh
./disc-to-jellyfin --doctor
```

Optional permanent installation:

```sh
nix profile install ./app
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
Series Name (1976)/
└── Season 01/
    ├── Series Name (1976) S01E01 - Pilot.mkv
    └── Series Name (1976) S01E02.mkv
```

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

## Reliability and recovery

- Every ISO is scanned, even in main-feature mode, so title selection and
  completion validation are deterministic.
- Encodes use a same-filesystem partial file and an atomic no-clobber publish.
- FFprobe verifies Matroska/H.264, duration, audio, subtitles, and chapters.
- Resume only skips an output whose completed manifest exactly matches its ISO,
  title, HandBrake version, audio profile, RF, and x264 preset.
- Per-output locks prevent two instances from corrupting the same job.
- Ctrl-C terminates HandBrake and removes only the active partial file.
- Failed jobs do not stop later jobs; a failure summary is printed at the end.
- Manifests and full HandBrake logs live outside the media library under
  `$XDG_STATE_HOME/disc-to-jellyfin/jobs` or
  `~/.local/state/disc-to-jellyfin/jobs`.
- `--dry-run` prints the complete plan and exact HandBrake commands.

## Developer verification

```sh
cd app
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
cargo test --locked
nix flake check -L
nix build -L
```

Normal users do not need to run these commands.
