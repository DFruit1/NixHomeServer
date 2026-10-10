# Local transcription from the inbox

- Status: proposed
- Date: 2026-10-05

## Context

Media Manager's Conversions page currently shows one thing: DVD ISO conversion,
performed by `mkvmaker`, observed through a pass-through of its progress file
(`src/http/conversions.rs:11-35`). Nothing generates a subtitle file anywhere in
the repository. `src/subtitle_format.rs` parses SRT, VTT and ASS and validates
cues, but there is no serializer, no audio extraction, and no model call.

There is a documented gap that transcription fills.
`documentation/operations.md:1572` records that a video with no subtitles of
either kind "simply gets no sidecar", because `youtube-downloader`'s
`download_transcript` fetches the uploader's own captions. A local model can
cover the rest.

### What was measured, on this host

Measured by sampling `/sys/kernel/debug/dri/*/vram0_mm` through a real
transcription with Qwen resident. The card is an Intel Arc Pro B60 (BMG G21)
exposing 23.91 GiB through the `xe` driver.

| Candidate | Weights | Peak VRAM | Verdict |
| --- | ---: | ---: | --- |
| Parakeet-TDT-0.6B-v3, q8_0 | 668.50 MB | 0.802 GiB | keep |
| Whisper large-v3-turbo, q5_0 | 573.40 MB | 0.879 GiB | keep |
| Qwen3-ASR-1.7B, Q8_0, c=4096 | 2.35 GiB | 2.701 GiB | dropped |
| Qwen3-ASR-1.7B, Q8_0, c=16384 | 2.35 GiB | 4.025 GiB | dropped |

Qwen3-ASR was dropped for two independent reasons. It is an LLM-based ASR, so
its cost scales with the context window the job needs, and a 5:08 clip truncated
at `finish_reason: length` at **both** c=4096 and c=16384 — it cannot do
long-form on this card at all. Its VRAM at c=4096 is 2.701 GiB against the
2.82 GiB left by Qwen at a 128K context, and llama.cpp does not spill a failed
allocation to host RAM; under pressure it splits weights between card and host
without erroring. A nightly unload window was considered and rejected: it would
have cost Hermes availability during active worker turns, in exchange for a tool
that cannot transcribe a ten-minute video.

Parakeet is English-only. Whisper covers 100 languages plus translation. Both
transcribe correctly, both cost under 0.9 GiB, and both use fixed processing
windows, so a two-hour video costs exactly what an eleven-second clip does.

## Decision

A new optional module, `modules/transcribe/`, owns two ASR backends and a
worker that runs them on demand. Media Manager gains a second track on the
Conversions page and becomes a **client** of that module.

Two boundaries matter:

- **Media Manager is a core service.** Optional applications may register typed
  capabilities, but their absence must not prevent Media Manager from starting
  (`documentation/decisions/0001-media-manager-architecture.md`).
  Transcription is declared as an `IntegrationCapability` in the manner of
  `modules/jellyfin/registration.nix`; when the module is absent every endpoint
  returns `503 transcription_unavailable` and the Conversions page renders
  nothing. Removing `modules/transcribe/` must leave the repository working.
- **Transcription never runs inside a Media Manager request.**
  `src/http.rs:403` admits handlers through `isolate_handlers(router, 16)`; a
  long transcription would hold a permit for minutes. The work happens in a
  systemd `.path`-triggered oneshot, following the marker-file precedent in
  `src/http/refresh.rs:3-75`.

### Inbox layout

Two roots with different trust properties.

**Per-user inboxes**, for user-facing work on a user's own files:

    <usersRoot>/<username>/_Transcribe/parakeet/
    <usersRoot>/<username>/_Transcribe/whisper/
    <usersRoot>/<username>/_Transcribe/_Failed/

**One server inbox**, for server-side applications and processes:

    <transcribeStateDir>/incoming/parakeet/
    <transcribeStateDir>/incoming/whisper/
    <transcribeStateDir>/incoming/_Failed/

The server inbox is deliberately **not** under `sharedRoot`. That is the whole
point of it: users reach `sharedRoot` through Filestash and Media Manager, so a
folder there cannot be protected from them by permissions alone. Placing it in
the module's state directory makes it structurally unreachable from any
browsable root, which is a stronger guarantee than an ACL. Only the worker, and
services explicitly granted write access, can place a file there.

`_`-prefixed directories are bookkeeping and are skipped by the lister, matching
the convention the durability sync already applies to archived boards.

Per-user inboxes are created lazily and idempotently rather than by a one-shot
provisioner, so users created after this ships work without a migration.
Directory creation goes through the broker, which is the only principal with
write access to the roots, and the boot-time ACL pass in
`modules/Core_Modules/media-manager/storage.nix:37-83` is extended to cover
`_Transcribe` alongside the existing roots.

### The request file: one language, two models

The **folder** selects the backend. The optional **request file** carries
everything else. These are deliberately separate: one mechanism per decision,
so there is nothing to reconcile and nothing to contradict.

- `<name>.transcribe.request.json` — written by the caller, optional
- `<name>.transcribe.result.json` — written by the worker on success
- `<name>.transcribe.error.txt` — written by the worker on failure

The request file is the standardised contract for applications *and* for people
writing JSON by hand, so it stays small, flat, self-describing, and tolerant of
keys it does not recognise:

    {
      "version": 1,
      "source": {
        "origin": "library",
        "itemId": "optional opaque identifier",
        "title": "optional display title",
        "fingerprint": "optional size:mtime_ns"
      },
      "output": {
        "formats": ["txt", "srt", "vtt"],
        "language": "en",
        "diarize": false
      },
      "transcription": {
        "language": "en",
        "prompt": "optional context hint for proper nouns",
        "vocabulary": ["optional", "term", "list"]
      }
    }

`output.formats` is honoured by the worker for both models, because **the worker
never asks a backend to render subtitles**. It always takes word timings from
the backend and builds cues itself, then serialises with its own writer. That is
what makes one API genuinely uniform rather than nominally uniform: `srt` means
the same bytes regardless of which model ran. It is also necessary, because
`parakeet-cli` has no SRT or VTT output mode at all.

`source` is provenance only. It never changes model behaviour; it is copied into
the result so a later consumer, including the search indexer, can attribute a
transcript to where it came from.

### Ingestion protocol: pairing, ordering, settling

The request file and the audio file travel together as a **pair**, matched by
name. For a media file `NAME.EXT`, the request file is
`NAME.transcribe.request.json`, where `NAME` is the filename with only its final
extension removed. So `lecture.mkv` pairs with
`lecture.transcribe.request.json`, and `my.video.v2.mkv` pairs with
`my.video.v2.transcribe.request.json`.

**The request file is written first, and the audio second.** That ordering is
part of the contract, and it is what makes a large file safe to ingest. The
request is small and lands atomically, so its arrival says "a job for `NAME` is
declared"; the audio's arrival and settling is what says the job is ready. If
the order were reversed the watcher would have to guess whether a video it can
see is still being copied by Syncthing or Filestash, and the failure mode is
transcribing a truncated file and reporting it as a complete transcript.

The request file is still optional. A media file with no partner simply runs
with defaults — no formats beyond `txt`, no diarisation, no language hint. The
ordering rule binds only callers who want options.

Settling reuses the mechanism `mkvmaker` already has for DVD ISOs
(`modules/mkvmaker/services.nix:48` `settleSeconds`, default 60, plus
`leaseSeconds`), because a video landing through a sync client has exactly the
same problem an ISO has. A pair becomes eligible when:

- the media file's size and mtime are unchanged across two observations at least
  `settleSeconds` apart, and it opens under `open_regular_file_beneath`, and
- `ffprobe` reports at least one audio stream, and
- if a request file is present, it has also settled and parses.

Three failure cases are distinguished rather than lumped together, because they
mean different things to whoever dropped the file:

- **No audio stream** — failed at intake, named as such. A video file must not
  sit in the queue and produce nothing.
- **Request file present but unparseable** — failed with `request_invalid`, after
  its own settle window, so a half-written JSON is not mistaken for a broken one.
- **Request file present, audio never arrives** — failed as an orphaned
  declaration after `orphanTimeoutSeconds`, so a typo in the filename surfaces in
  the Failed box instead of accumulating silently.

Pairing by stem has one collision case: `lecture.mkv` and `lecture.mp4` in the
same folder both pair with `lecture.transcribe.request.json`. Rather than guess,
the ingester fails both as `ambiguous_source`. It is vanishingly rare for a
person, and the broker controls filenames for the application path, so it can
guarantee uniqueness there.

### The request is advisory; the result is the truth

The two backends genuinely differ, so no schema can be honoured identically by
both. Parakeet takes no language argument and has no prompt mechanism; Whisper
takes both. Rather than pretend otherwise, the worker records what it could not
honour:

    "honoured": { "language": true, "diarize": true },
    "ignored": [
      { "field": "transcription.prompt",
        "reason": "parakeet accepts no prompt" }
    ]

Unknown keys in a hand-written request are treated the same way — recorded in
`ignored`, job proceeds. A job is never rejected for an unrecognised key, and an
unrecognised key is never silently dropped. This is the mechanism that lets one
API stay honest across two engines.

Media Manager surfaces `ignored` as a warning badge on the result, so a user who
asked for a language hint on an English-only model finds out rather than
discovering it later.

There is **no** automatic fallback between backends. When Parakeet is given
non-English audio it does not fail — it returns confident garbage — so a
fallback keyed on errors would not fire when it matters. The result reports mean
token confidence and detected language, Media Manager suggests the other model,
and the caller decides.

### Queueing and model affinity

One worker, `flock` single instance. The scheduling rule is to **drain**: once a
backend is loaded, it serves every pending job for that backend before the other
is considered. Loading a model costs seconds and roughly 0.85 GiB of card, so
interleaving the two queues would pay that repeatedly for no benefit.

Draining alone starves one backend if jobs keep arriving for the other, so the
worker re-checks at each job boundary rather than committing to a whole group:

- If the other backend's oldest pending job has waited longer than
  `maxBackendWait`, finish the current job and switch.
- Otherwise continue draining.

A loaded model is released as soon as its queue is empty. No grace period: holding
0.85 GiB speculatively is exactly the sort of thing that costs Qwen the headroom
it needs to re-acquire its allocation on restart. The grace period is left as a
tunable with a zero default rather than being designed in.

### Diarisation

`sherpa-onnx-offline-speaker-diarization` runs on CPU through ONNX Runtime and
therefore consumes **no VRAM**. It needs a segmentation model (~5.7 MB) and a
speaker embedder (~80 MB), both hash-pinned as artifacts.

Requested by `output.diarize` in the request file, defaulting to false. Parakeet
produces word timings natively; Whisper produces them with `--split-on-word`. Both
feed one shared cue builder — words to cues by punctuation, pause and length,
then speaker assignment by turn overlap — which is unit-testable with no model
present. Quality on three or more overlapping speakers is expected to be the weak
point, not VRAM.

### Artifacts and the search contract

Artifacts are written to `<ownerRoot>/_Transcripts/<stem>-<hash>/` as
`transcript.txt`, `subtitles.srt`, `subtitles.vtt`, `diarized.srt` and
`meta.json`. The result file holds `backend`, `language`, `detectedLanguage`,
`speakerCount`, `durationMs`, `meanTokenConfidence` or `noSpeechProb`,
`createdAt`, `sourceFingerprint`, `transcriptSha256`, `outputDir`, `honoured`
and `ignored`. That layout is the contract a future indexer consumes: it reads
`transcript.txt` and the result, and never learns which model produced them, so
backends stay swappable without touching consumers. That is the point of building
this before the search feature exists.

### Source handling

The ISO flow moves its input into `_Processed` because an ISO is consumed to
produce the MKV. Transcription does not consume its input, so the source stays
put and the result file is the completion marker; the worker skips any file that
has already produced a result unless the request carries `"force": true`.
`removeSourceAfterSuccess` (default `false`) restores DVD behaviour by moving the
source into `_Processed` when that is wanted.

### Proposed: application-initiated transcription

Not built in this phase. Documented so the next feature does not have to
rediscover the constraints.

Media Manager already has a safe path for turning a library item into a staged
file: a plan, then a broker action. A `CopyForTranscription` action would let a
user request a transcript for a selected item, with the broker writing a
`.tmp` audio file plus a request file into the right inbox folder, so the request
is visible to the existing inbox machinery.

Five constraints apply, and the first is the important one:

1. **Extract audio, do not copy the media file.** A 40 GB 4K source copied into
   the inbox is unacceptable and unnecessary, because the worker extracts audio
   as its first step regardless. The broker extracts 16 kHz mono audio and
   places only that in the folder: roughly 1.5 MB per minute, so about 180 MB
   for a two-hour film. The worker then needs no library read access, and the
   source can be deleted the moment the audio exists.
2. **The broker must do it.** `modules/Core_Modules/media-manager/services.nix:191`
   marks `sharedRoot` and `usersRoot` read-only for the web service, with
   `ReadWritePaths = [ stateDir ]` only. The broker (`services.nix:302-340`) is
   the only principal with write access to the roots.
3. **The request file is how the app says what it wants.** `source.origin`,
   `source.itemId` and `source.fingerprint` go in the request, so the app needs
   no private channel to the worker.
4. **Re-requests** carry `"force": true`, since an existing result would
   otherwise suppress the job.
5. **Permission scope.** A request for another user's personal file must pass
   `visible_catalog_item` (`src/http.rs:988-996`) and the broker's personal-root
   isolation, as every other mutation does.

## Rejected alternatives

- **Automatic backend selection with confidence fallback.** Rejected: it hides a
  decision the caller should own, and the confidence signal from `parakeet-cli`
  is only reachable by parsing its human-readable `-ps` output, since the tool
  has no machine-readable mode.
- **Model selection inside the request file.** Rejected for now, to keep one
  mechanism per decision. The folder already selects the model in a way both a
  person and an application can act on. If a future caller wants a uniform
  programmatic API, an optional `model` key that must agree with the folder is
  the cheap way to add it.
- **A dedicated ASR HTTP daemon.** Rejected: the worker invokes `parakeet-cli`
  and `whisper-cli` directly, so there is no daemon, no port, and no model
  lifecycle to manage. This also dissolves the problem that `parakeet-cli`
  exposes no API at all.
- **Two concurrent workers, one per backend.** Rejected: together they hold
  about 1.7 GiB, which is headroom Qwen needs. Draining gets most of the
  throughput benefit without the standing cost.
- **Two permanent `llama-server` instances** (Qwen and an ASR model sharing one
  API shape). Rejected: 21.09 + 2.70 GiB is 23.79 of 23.91 GiB resident,
  permanently, leaving nothing for a Qwen restart.
- **Running Qwen at 64K so Qwen3-ASR could coexist.** Feasible — 18.478 + 2.701
  leaves 2.73 GiB spare — but a straight regression against the 128K context,
  and production sessions already reached 56,950 tokens at 64K.
- **Streaming multipart upload from the browser.** Rejected: there is no
  multipart path in the repository, and `frontend/src/api.ts:59-117` imposes a
  30-second abort timeout on every request. Inbox drop matches the existing DVD
  mental model and needs no upload code.

## New code this requires

- A subtitle **serializer**. `src/subtitle_format.rs` parses only; `render_srt`
  and `render_vtt` over the existing `SubtitleCue` are new, following the
  timestamp style already used at `src/subtitles.rs:794-815`. This is central
  rather than incidental: it is what makes output identical across models.
- A request-file **parser and validator**, plus the `honoured`/`ignored`
  accounting that records intent the backend could not satisfy. Tolerant of
  unknown keys by design.
- The **ingestion scanner**: pairing by stem, the write-order contract, settle
  detection borrowed from `mkvmaker`, and the three distinct intake failures
  (`request_invalid`, `ambiguous_source`, orphaned declaration).
- **Backend adapters**, one per model, each responsible for translating a
  validated request into that model's argv and for parsing its timings back out.
  This is the seam where model-specific knowledge is allowed to exist, and
  nowhere else.
- A media file lister, mirroring `list_iso_directory`
  (`src/http/conversions.rs:98`) but probing with `ffprobe` via the existing
  `probe_video` and `VideoProbeCache` (`src/video_probe.rs:45-64`, `:203-283`).
  **A file with no audio stream is failed at intake** with a clear reason, rather
  than occupying the queue and producing nothing.
- Audio extraction, following the argv-only invocation pattern at
  `src/http/playback.rs:261-311`: `ffmpeg_path` derived by
  `ffprobe_path.with_file_name("fmmpeg")` — corrected, by
  `ffprobe_path.with_file_name("ffmpeg")` — input opened with
  `open_regular_file_beneath` and fed on stdin, atomic `rename` to publish.

### Asymmetry worth recording

`whisper-cli` has real machine-readable output: `-oj` and `-ojf` for JSON, plus
`-osrt`, `-ovtt` and `-otxt`. `parakeet-cli` has none — only `-otxt`, `-of`, and
`-ps`, which prints per-token segments to stdout carrying `p` and `plog`. So the
Parakeet adapter's timings come from parsing human-readable output while the
Whisper adapter reads JSON.

That is the most durable fragility in this design. It is mitigated by pinning
`whisper-cpp`, covering the parse with a fixture test, and **failing the job
loudly** when `-ps` output cannot be parsed, rather than emitting an empty
transcript that looks like silence in the source.

## Progress reporting

Neither CLI emits progress events, and synthesising a percentage would be a lie
in a `.progress-track`. The worker therefore reports a typed stage —
`extracting`, `transcribing`, `diarising`, `writing` — with a real percentage
only where one is derivable (diarisation knows its segment count; extraction
knows the duration), and Media Manager renders an indeterminate track otherwise.

## Trust boundaries

- Inputs are opened with `open_regular_file_beneath` (`openat2` + `O_NOFOLLOW`)
  and fed to subprocesses on stdin as `pipe:0`, never as an interpolated path.
- Job names and request contents are validated: no `/`, no NUL, no leading `-`,
  length bounded as in `list_iso_directory`, JSON depth and size bounded.
  Outputs are confirmed to sit beneath the owner root.
- The worker is a root oneshot over a private network namespace, as the broker is.
- The server inbox is outside every browsable root, so no user-reachable path
  exists to it.
- Per-user inbox access is gated on `owner_username` and `visible_catalog_item`.

## VRAM

One backend on the card at a time, released when its queue drains. Against Qwen
at a 128K context (21.09 of 23.91 GiB): Parakeet brings the total to 21.89 GiB,
Whisper to 21.97 GiB, leaving roughly 2 GiB of headroom. Transcription must never
be resident, because that headroom is what lets Qwen re-acquire its allocation
on restart.

## Implementation slices

Each is independently verifiable.

1. **Module skeleton, models, worker, adapters, scanner.** Both backends,
   hash-pinned artifacts, one-shot worker, ingestion scanning with pairing and
   settle detection, queue and drain scheduling, job state files. Verified by
   writing a request file then an audio file into the server inbox and reading
   the result and error output — including the cases where the audio never
   arrives or the JSON is malformed.
2. **Serialiser and cue builder.** `render_srt`, `render_vtt`, cue grouping,
   speaker assignment. Verified with no model present.
3. **Job API.** Inbox envelope and log endpoint. Verified with a fixture inbox.
4. **Conversions page.** Second track beside the ISO progress, `Processed` and
   `Failed` boxes shared across both artifact kinds, backend and `ignored`
   badges.
5. **Per-user inboxes.** Lazy provisioning through the broker, ownership gating,
   ACL pass extended.
6. **Diarisation.** sherpa-onnx worker step merged into the cue builder.
7. **Library install.** Pull artifact over loopback into `provider-staging/`,
   then the existing plan, confirm and broker pipeline — which yields the
   Activity audit trail and `file_fingerprint` optimistic-concurrency checks for
   free.

## Test obligations

- Rust unit tests with no model present: request parsing and validation,
  `honoured`/`ignored` accounting, stem pairing including the collision case,
  settle detection, the three intake failures, cue builder, `render_srt` and
  `render_vtt`, result parsing, job-name validation, folder-to-backend mapping,
  drain scheduling including the starvation cut-over, and the `parakeet-cli`
  `-ps` parse (fixture-pinned to a `whisper-cpp` version).
- `openapi.yaml` path and schema, then
  `python3 scripts/helpers/generate-media-api.py`; the
  `media-manager-api-contract` check (`flake/checks.nix:144`) enforces freshness.
- `MediaAction` variant in `src/capabilities.rs:44` and the `openapi.yaml`
  `MediaKindProfile.actions` enum; `OPERATION_LABELS` in
  `frontend/src/activity-view.tsx:11`.
- `tests/http_api.rs:3979` path list; a `frontend/src/root.test.tsx` case using
  the existing stubbed-fetch polling pattern.
- `pnpm check` in the frontend, then the lean gate. Verify the panel at roughly
  390px and 1280px per `AGENTS.md`, with no clipped or unreachable scroll region.

## Open questions for review

1. What is a sensible default for `maxBackendWait`, the point at which draining
   switches to the other backend? Too short and the drain stops paying for
   itself; too long and the minority backend starves.
2. Should a server-ingested job's artifacts be written to the module state
   directory (not browsable, read programmatically) or mirrored into
   `sharedRoot/_Transcripts/` for visibility? The default here is the former.
3. Should `output.diarize` default to true for the per-user inbox, where the
   common case is interviews and lectures? The default here is false everywhere.