# Local transcription

The optional `transcribe` application processes audio and video locally with
Parakeet-TDT-0.6B-v3 Q8_0 or Whisper large-v3-turbo Q5_0. Media Manager's
Conversions page shows your jobs, downloads and failures. This adds no network
listener or browser hostname. The implementation follows
[decision 0010](decisions/0010-local-transcription.md), with the implementation
adjustments recorded there.

## Submit a recording

Choose the backend by copying the file into your personal directory:

```text
_Transcribe/parakeet/
_Transcribe/whisper/
```

Folders are provisioned idempotently for existing and subsequently created user
roots. The file must remain unchanged for at least 60 seconds across two scans.
Without a request file, the output is a plain-text transcript. Sources are always
retained. The worker does not automatically switch backends.

For subtitles, speaker labels or hints, write the request file **first**, then
copy the recording. `lecture.mkv` pairs with
`lecture.transcribe.request.json`; only the final extension is removed.

```json
{
  "version": 1,
  "source": { "origin": "inbox", "title": "Lecture" },
  "output": {
    "formats": ["txt", "srt", "vtt"],
    "language": "en",
    "diarize": true
  },
  "transcription": {
    "language": "en",
    "prompt": "Context for proper nouns",
    "vocabulary": ["Kanidm"]
  }
}
```

`output.language` labels the result; it does not translate speech. Whisper
accepts language, prompt and vocabulary hints. Parakeet's pinned CLI has none
of those arguments, so those hints appear in `ignored` instead of being silently
discarded. Unknown request keys also appear in `ignored`. Parakeet does not
report a detected language; its result uses `null`, not an invented language.
Requests are limited to 64 KiB; only version 1 and TXT/SRT/VTT formats are accepted.

## Read and install results

Successful jobs publish their completion marker beside the recording and write
artifacts under `_Transcripts/<stem>-<hash>/`:

- `transcript.txt` is always present, along with `meta.json`.
- `subtitles.srt` and `subtitles.vtt` follow the requested formats.
- `diarized.srt` is added when speaker diarisation is requested.

The result records provenance, source fingerprint, transcript SHA-256, backend,
duration, detected language where available, mean token confidence where available,
speaker count, honoured settings and ignored settings. A new source/request
fingerprint gets a distinct output directory, preserving earlier exports.

Media Manager lists the 200 most recent jobs belonging to the signed-in user.
Download artifacts from Processed on Conversions. In a video's subtitle tools,
choose a completed SRT/VTT transcript and **Preview transcript installation**,
then use the existing confirmation flow. The broker, audit trail and optimistic
concurrency checks are the same as for uploaded subtitles. Transcription itself
never writes a subtitle beside a library video without that confirmation.

Results suppress repeated processing of unchanged input. To retry with new
options, update the request and add `"force": true`; leaving that exact request
unchanged will not cause an endless retry loop. Errors leave the source intact,
write `<stem>.transcribe.error.txt`, and add an entry under `_Transcribe/_Failed/`.
No-audio, malformed-request, orphaned-request and ambiguous-stem failures are
distinct. Request-only declarations expire after an hour.

## Runtime and operations

`transcribe-worker.service` is a single-instance, flock-protected oneshot. A
path watcher notices the private server inbox; a one-minute timer handles settling
and personal inboxes. Jobs report extracting, transcribing, diarising and writing
stages. The UI uses indeterminate progress, not fabricated percentages.

Only one ASR process runs at a time. It exits and releases its model after each
job. Backend affinity is retained while choosing jobs, but an older job from
the other backend takes priority after five minutes at a job boundary. CPU
diarisation runs after ASR has exited, using sherpa-onnx. Backend subprocesses
have a six-hour timeout and bounded diagnostic capture. Errors returned to users
contain a code, never raw decoder output or private recording contents.

Weights are hash-pinned and downloaded during model preparation into
`${dataRoot}/transcribe/models`; disposable extracted WAVs also stay on the data
pool. Queue observations, job records and the private server inbox live under
`/var/lib/transcribe`, registered in central persistence and its backups.
Disabling/removing the app retains state, outputs and weights. Its authenticated
Media Manager endpoints then return `503 transcription_unavailable`.

The private server inbox is `/var/lib/transcribe/incoming/{parakeet,whisper}/`.
It is root-only and outside all browsable roots. Server artifacts remain in the
module state directory; browser endpoints never list or download server jobs.
Do not grant an application root access just to submit a recording; explicitly
design its narrow inbox write grant first.

```bash
systemctl status transcribe-model-prepare transcribe-provision transcribe-worker
journalctl -u transcribe-worker -n 50 --no-pager
```

Long-running transcription and model preparation block scheduled suspend and
guarded shutdown. No live activation is implied by editing or testing the source.

## Implementation verification

Focused checks cover the Rust binaries, existing subtitle serializers, transcript
ownership boundaries, managed Immich accounts, frontend types/build and relevant
UI tests, API contracts, and enabled/disabled module evaluation. Direct fixtures
exercise the real worker and FFmpeg with mocked ASR/diarisation executables,
EYE's load/idle/reload lifecycle with a mocked SDK, and provisioning against a
temporary PostgreSQL database and encrypted credential store. Desktop/mobile
browser checks cover artifact download and subtitle preview/confirmation.

Native model inference, GPU execution and live NixOS activation still require
deployment verification. No full repository gate was run. Strict Clippy reports
four existing warnings in unchanged provider/subtitle code.
