# Bonsai Local AI

The optional `bonsai` application serves **Ternary Bonsai 2 27B** through
llama.cpp's chat UI at `https://ai.<domain>`. Sign in through Kanidm with the
`ai-users` group. The local API alias remains `bonsai-ternary-27b` so existing
clients keep working.

## Pinned model and runtime

- Model: `prism-ml/Ternary-Bonsai-2-27B-gguf`, revision
  `839bd57023c1558945afea70a74fa83c054f35f9`.
- Language weights: `Ternary-Bonsai-2-27B-Q2_0.gguf`, 7,626,008,928 bytes.
- Vision projector: `Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf`, 629,246,976 bytes.
- Runtime: mainline llama.cpp v0.9.0, commit
  `cd959bae99ff4bed22bef2604f45241c09bbb8c8`.

Both artifacts are size- and SHA-256-verified before inference starts. The
Q2_0 packing supports Vulkan and does not need Prism's custom PQ2_0/PTQ1_0
kernels. **Bonsai 2 needs the Hadamard activation runtime in b11556 or newer.**
Older runtimes can load the file while producing incorrect output.
See the [publisher's model card](https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf).

Weights live on the data pool at `/mnt/data/bonsai/models`. Disabling or
removing the app retains both old and new weights as reusable archives.
Central persistence retains `/var/lib/bonsai`; backups exclude GGUF weights.

## Server profile

The Arc Pro B60 profile uses Vulkan, one inference slot, a 32K-token context,
and quantized KV cache. Vision processing stays on the CPU. The model releases
its GPU allocations after 15 idle minutes and reloads on demand.

Bonsai 2 reasons by default. The server uses medium reasoning effort and a
1,024-token thinking budget so document metadata requests have time to return
an answer. The chat UI can override request settings. The model's advertised
262K context is not the configured context; raising it requires measuring
weights, KV cache and working buffers together, allowing for transcription.

The loopback API is `http://127.0.0.1:8086/v1`. Local background clients use
`http://127.0.0.1:8094/v1`, the `bonsai-gate` concurrency proxy. It admits one
active request and two queued requests, with bounded wait and upstream timeouts.
There is no API credential on loopback; neither listener is exposed directly.

Qwen remains disabled on this host. Its optional background-job integration
still stops Bonsai while Qwen runs if both applications are enabled later.

## Paperless-GPT

The separately removable `paperless-gpt` app provides the upstream v0.31.0 UI
at `https://paperless-gpt.<domain>`, restricted to the configured owner's
`paperless-gpt-users` Kanidm group. Its upstream release container is pinned
by digest. It connects to Bonsai through the concurrency gate and reads the
existing Paperless OCR text. Paperless-ngx stays on its existing version;
this does not enable the prepared v3 migration.

For an initial test:

1. In Paperless, add the `paperless-gpt` tag to a document you want to test.
2. Open Paperless-GPT and request suggestions.
3. Review the proposed title, tags, correspondent and document type before
   applying them. Existing metadata is preserved by default and new tag
   creation is disabled initially.

No import rule adds the automatic-processing tag. Adding `paperless-gpt-auto`
explicitly opts that document into upstream automatic processing; do not add
it in bulk until suggestions have been checked. OCR replacement and PDF
upload are disabled.

The owner approved creation of a dedicated `paperless-gpt-service` Paperless
account and API token. It has no password login or admin status. Provisioning
grants view/change access to owner-accessible documents and metadata access,
without document deletion or upload permissions. Object grants refresh every
five minutes, including revocation when owner access is lost. Documents
imported after startup may need one refresh before appearing.

The token is materialized only at `/run/paperless-gpt-credentials/environment`
(root-only) and passed to the container. Do not print that file or container
environment. Settings, prompts and undo history persist in
`/var/lib/paperless-gpt` and are covered by the normal `/persist` backup.
Disabling the app retains its state and service identity; it stops runtime,
provisioning and routing.

## Operations

```bash
sudo systemctl status bonsai-model-prepare bonsai-llama bonsai-gate paperless-gpt
sudo journalctl -u bonsai-model-prepare -u bonsai-llama -n 80 --no-pager
curl --fail http://127.0.0.1:8086/health
curl --fail http://127.0.0.1:8094/v1/models
```

An enabled service and a healthy API do not prove document classification
quality. Check suggestions on representative documents, especially scans with
poor OCR, unfamiliar layouts and ambiguous tags.
