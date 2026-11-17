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
    "diarize": true,
    "cleanup": true
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

`output.cleanup` asks Bonsai to proofread the finished transcript (see
[Bonsai proofreading](#bonsai-proofreading)). The Media Manager upload form
requests it by default; a request file without the key, and an inbox file with
no request, do not. Where Bonsai is not enabled the key appears in `ignored`.

## Read and install results

Successful jobs publish their completion marker beside the recording and write
artifacts under `_Transcripts/<stem>-<hash>/`:

- `transcript.txt` is always present, along with `meta.json`.
- `subtitles.srt` and `subtitles.vtt` follow the requested formats.
- `diarized.srt` is added when speaker diarisation is requested.
- When Bonsai proofreading ran, `transcript.txt` and the subtitles carry the
  proofread words, and the recognised text is kept separately as
  `transcript.original.txt`. `words.original.json` and `words.cleaned.json`
  hold both versions word by word with times (and the recogniser's confidence
  for the original), for comparing, revising or training; the cleaned file is
  absent when proofreading failed. Search indexes only the proofread transcript.

The result records provenance, source fingerprint, transcript SHA-256, backend,
duration, detected language where available, mean token confidence where available,
speaker count, honoured settings and ignored settings. A new source/request
fingerprint gets a distinct output directory, preserving earlier exports.

Media Manager lists the 200 most recent jobs belonging to the signed-in user.
Completed and Failed keep the last three days visible and fold older work behind
one disclosure; each entry can be dismissed in the browser without deleting the
transcript or its artifacts. Download artifacts from Completed on Conversions. In a video's subtitle tools,
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
stages, with a percentage only where the tool reports its real position:
FFmpeg's extraction progress, whisper.cpp's `-pp` line, and the same line from
the pinned parakeet-cli, which `modules/transcribe/parakeet-progress.patch`
teaches to print its decoded position. Speaker detection reports no position, so
the UI shows that stage without inventing a number.

### Long recordings

Parakeet encodes each input file in one pass, so its graphics memory grows with
the file's length: on the Arc Pro B60 one minute peaked at 1.12 GiB, two at
1.51, four at 2.66, and a 90-minute recording ran the card out of memory,
pushed the resident search models into host RAM and was killed at the unit's
32 GiB limit. Parakeet audio longer than about 104 seconds is therefore cut at
pauses into chunks of about 90 seconds (the longest silence between 67 and 104
seconds, at the quietest of -40/-35/-30/-25 dB that has one, otherwise a cut at
90 seconds). All chunks go to one parakeet-cli run, so the model loads once,
and word times are shifted back onto the recording. Measured on a 90-minute
stand-up recording: 78 seconds of decoding, a 1.42 GiB peak, and accuracy
matching three-minute chunks, where 30-second chunks garbled more words. A
chunked job reports decoding progress across all chunks. Whisper already reads
audio in 30-second windows and is not chunked.

### Bonsai proofreading

When a job asks for it and both this app and Bonsai are enabled
(`modules/Integrations/clean_transcripts_with_bonsai.nix`), the worker sends
the transcript to Bonsai through its loopback concurrency gate after
transcription; that is the worker's only network access. The job shows
"Correcting names and misheard words" meanwhile. Bonsai receives the recording
title (the request's `source.title`, else the file name), any `vocabulary`
hints and the transcript in numbered lines, in sections of up to 1,000 words
(about seven minutes of speech). With 4,000-word sections Bonsai proposed
corrections only for the first few minutes of each. Names settled in one
section are passed to the next.

Bonsai may only answer with short corrections: a line number, words from that
line and their replacement. The worker applies a correction only if:

- its quoted words occur exactly once in that line and do not overlap another
  correction;
- judged on the words that actually change, ignoring unchanged words quoted
  around them: at most three change, at most two are added, none are removed
  (so swearing, repetitions and filler stay), except merging near-identical
  words such as "t shirt" into "t-shirt";
- numbers never change;
- swearing is never removed, even as a sound-alike substitution;
- a changed word must be one the recogniser was unsure of (confidence below
  0.5), and the replacement must resemble it unless every changed word was
  garbled (below 0.35, as in "Is Handy got a knife?" for "Has anyone"). A confidently recognised word changes only into a name or term
  from the recording title or `vocabulary` (for example "Conley" into
  "Connolly" for a Billy Connolly show), or when near-identical words merge. On
  a 90-minute recording, Bonsai's sound-alike fixes replaced words scored
  0.31-0.46, while its meaning changes ("an older woman" made younger, "£12,000"
  made £1,200) replaced words scored 0.74-1.0.

A section where the accepted corrections would change more than 15% of its
words is left untouched. Replaced words share the original span's time, so
subtitles stay in sync. `meta.json` records the outcome under `cleanup`:
`status` (`applied`, `unchanged` or `failed`), counts of applied and rejected
corrections, every applied correction with its time, and each refused
correction with its reason. A Bonsai failure or
timeout leaves the transcript as recognised and does not fail the job.

### Process limits

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
