# Bonsai Local AI

The `bonsai` application module serves PrismML's Ternary Bonsai 27B
vision-language model through llama.cpp's OpenAI-compatible API. It is intended
as a private local inference foundation for document classification, media
categorisation, metadata extraction, tool calling, and future system
automation.

The upstream llama.cpp UI is available at `https://ai.sydneybasiniot.org` on
home Wi-Fi/LAN or NetBird, protected by the shared Kanidm gateway and the
`ai-users` group. There is no public Cloudflare route. The UI assets are built
from the same pinned source as the server and served through its static path.
The UI is intentionally Bonsai-only: `bonsai-llama.service` loads just the
Bonsai model, and the larger Qwen model is not present in its model list. Qwen
is reserved for background jobs; see
[Qwen Flash Next](qwen-flash-next.md).

The direct API binds only to `127.0.0.1` and has no API authentication.
Local applications must go through the ai-gate concurrency guard, not the
server directly:

```text
http://127.0.0.1:8094/v1
```

`bonsai-gate.service` (Rust `ai-gate`) holds exactly one in-flight upstream
request with at most two queued; further bursts fail fast with 429/504 and
`Retry-After: 15` instead of piling up on llama-server's single slot. The gate
itself is capped at 256M/512M RAM and 50% CPU with `NoNewPrivileges` and
`PrivateTmp`, while `bonsai-llama.service` stays deprioritized (`Nice 10`,
`CPUWeight 20`, `IOWeight 20`, `OOMScoreAdjust 500`) so inference can never
starve core services. Paperless v3 AI suggestions ride this path; the raw
`http://127.0.0.1:8086/v1` endpoint is reserved for debugging.

The stable API model name is `bonsai-ternary-27b`.

## Runtime Compatibility Decision

Bonsai runs on the shared mainline llama.cpp `b10897` build, which PrismML now
[supports through an upstream-compatible group-64 artifact](https://huggingface.co/prism-ml/Ternary-Bonsai-27B-gguf),
`Ternary-Bonsai-27B-Q2_g64.gguf`. The older group-128 artifact remains
fork-specific and is not used by this runtime. Existing files are retained.

`bonsai-llama.service` is a plain single-model llama-server at
`http://127.0.0.1:8086/v1`, not a multi-model router. The web UI therefore
lists only `bonsai-ternary-27b`, so an interactive user can never trigger a
model eviction or the large Qwen model load. Qwen has its own separate,
loopback-only server and never appears in the UI.

The Ryzen 7 5700X / 128 GB / Arc Pro B60 profile runs Bonsai with Vulkan, 8
inference threads, one slot, and 32,768 context tokens. Qwen keeps most of its
Mixture-of-Experts weights in system RAM when it runs, so the two models do not
fit in the 24 GiB card together. The background integration makes starting
Qwen stop the Bonsai server and restarts Bonsai afterwards, so the UI model and
the background model take turns on the GPU. ZFS ARC is limited to 8% of RAM
while the Qwen module is enabled. These are shared-host limits, not a promise
that every context or vision workload fits.

## Model Artifacts And Persistence

On first service start, `bonsai-model-prepare.service` downloads and verifies:

- `Ternary-Bonsai-27B-Q2_g64.gguf` — 7,585,330,240 bytes.
- `Ternary-Bonsai-27B-mmproj-Q8_0.gguf` — 629,246,880 bytes.

Both files come from the official
`prism-ml/Ternary-Bonsai-27B-gguf` repository at commit
`86e89f34c93201c3dfd5e5880fedb0022fc7e34d`. Their expected sizes and SHA-256 LFS
object hashes are declared in the NixOS module. A partial download resumes, a
completed file must pass its checksum, and replacement is atomic.

Artifacts live below `/var/lib/bonsai/models`. The core impermanence module
persists `/var/lib/bonsai` even if the application module is later removed.
Kopia intentionally does not back up these approximately 8.2 GB of reproducible
public artifacts.

Monitor the initial download with:

```bash
sudo journalctl -fu bonsai-model-prepare.service
```

## Memory And Context

The language weights require about 7.2 GB before runtime overhead. PrismML
reports about 8.4 GB peak at 4K context, 8.7 GB at 10K, and 14.7 GB at 100K
with an FP16 KV cache. Vision adds roughly another 0.9 GiB while the projector
is active.

`repo.bonsai.contextSize = 0` is the default. Startup selects a conservative
physical-RAM tier instead of asking llama.cpp to load the full 262K training
context blindly:

| Physical RAM | Context |
| --- | ---: |
| up to 11 GiB | 8,192 |
| 12–23 GiB | 16,384 |
| 24–35 GiB | 32,768 |
| 36–71 GiB | 65,536 |
| 72 GiB or more | 131,072 |

Set an explicit context after the RAM upgrade if preferred:

```nix
repo.bonsai.contextSize = 32768;
```

For unusually long contexts, Q4 KV caching can reduce memory use at a modest
quality and speed cost:

```nix
repo.bonsai.quantizeKvCache = true;
```

The service has low CPU and I/O weights, a positive OOM score adjustment, and
stops on an OOM. These controls make it a more likely memory-pressure victim
than core storage and identity services.

## Performance Tuning

The server launch includes several host-tuned defaults that can be overridden
through `repo.bonsai`:

```nix
repo.bonsai.threads = 8;          # --threads, physical core count (5700X: 8)
repo.bonsai.threadsBatch = 8;     # --threads-batch, prompt processing
repo.bonsai.speculativeNgram = false;
repo.bonsai.arcLoaderFlags = true;
```

Measurements on the Ryzen 7 5700X / 128 GB / Arc Pro B60 host:

| Configuration | Decode tok/s | Prefill tok/s |
| --- | ---: | ---: |
| Vulkan, no speculation | **29.5** | ~55 |
| Vulkan, n-gram speculation, prose | 29.5 | ~55 |
| Vulkan, n-gram speculation, repetitive | 27.4 | ~120 |
| CPU only (`--n-gpu-layers 0`) | 1.4 | ~1.5 |

- **GPU offload dominates.** The 7.5 GB Q2 model fits the 24 GiB Arc Pro B60
  and all 65 layers are offloaded (`Vulkan0 model buffer size = 6882 MiB`).
  Vulkan is about 21× faster than the CPU path, so keeping `gpu.enable = true`
  is the only change that materially matters.
- **Thread pinning.** `--threads`/`--threads-batch` are pinned to the physical
  core count (8). Decode measured identical at 8 and 16 threads, confirming it
  is GPU-bound; 8 avoids SMT contention with the rest of the stack.
- **N-gram self-speculation is not useful here.** `--spec-type ngram-simple`
  generated no drafts on ordinary prose and only about 2% draft acceptance on
  repetitive text, where it *reduced* decode from 29.5 to 27.4 tok/s. This
  differs from Qwen (see [Qwen Flash Next](qwen-flash-next.md)), where the model
  is CPU-MoE-bound; Bonsai is fully GPU-resident, so the host-side draft
  coordination only adds overhead. The option stays available but defaults to
  `false`; re-measure before enabling it.
- **Arc loader flags.** When Vulkan is enabled, `--load-mode none --no-host
  --no-op-offload` (from `repo.bonsai.arcLoaderFlags`) avoid host-memory
  staging and the slow host-tensor op-offload path on Intel Arc. They are
  ignored on the CPU backend.
- **Shader cache.** The unit sets a writable `CacheDirectory` and points
  `HOME`/`XDG_CACHE_HOME` at it. Without this the Mesa/Vulkan shader cache is
  disabled under `ProtectSystem=strict` and shaders recompile on every start.

Use `repo.bonsai.extraArgs` for a one-off experiment without editing the
module, for example an MoE placement sweep:

```nix
repo.bonsai.extraArgs = [ "--n-cpu-moe" "8" ];   # keep first 8 expert layers on CPU
```

`--n-gpu-layers` defaults to `auto` and Bonsai's 7.5 GB Q2 weights fit the
24 GiB Arc Pro B60, so unlike the 94 GB Qwen model it does not require
`--n-cpu-moe`. A sweep confirmed `--n-cpu-moe 8`/`16` changed nothing because
every layer already resides in VRAM; adding it would only reduce performance.

## Output Quality And Anti-Repetition

Seen in practice: the ternary build occasionally invents terms and loops on a
phrase, and can drift across a multi-turn chat. Both are expected at the 1.71
bits-per-weight quality tier and are addressable through sampling rather than
the model itself. The launch defaults are tuned for technical question
answering and agent use:

```nix
repo.bonsai.temperature = 0.3;    # lowered from the model's 0.7 chat default
repo.bonsai.topP = 0.9;
repo.bonsai.repeatPenalty = 1.1;  # mild token-level penalty
repo.bonsai.dryMultiplier = 0.8;  # DRY sequence-level anti-loop penalty
repo.bonsai.reasoningPreserve = false;
```

- **Temperature.** 0.3 sharpens the distribution and markedly reduces invented
  terminology versus 0.7. Raise per request (the API accepts `temperature`) for
  genuinely creative tasks.
- **DRY sampling.** DRY (`--dry-multiplier 0.8`) penalizes *repeated sequences*
  rather than individual tokens, so it stops phrase loops without the keyword
  starvation that aggressive `repeat-penalty` causes. This is the primary
  anti-loop lever.
- **Repetition penalty.** A mild 1.1 with `--repeat-last-n 64` on top of DRY.
- **Reasoning preservation.** The model template enables it by default, which
  keeps every prior turn's chain-of-thought in history and lets drift
  accumulate. `--no-reasoning-preserve` keeps only the latest reasoning and is
  the server-side fix for the same-chat degradation you observed.
- **Thinking mode.** Clients can disable per-token thinking with
  `chat_template_kwargs: { enable_thinking: false }` through `--jinja`; this
  gives faster, more direct answers for classification and extraction.

DRY and `repeat-penalty` are sampling-time only and cost nothing measurable in
decode throughput. A small factual-sloppiness rate is inherent to the ternary
quantization and is not fixable by sampling; use Bonsai for categorization,
extraction, and drafting, and verify specifics for geotechnical or engineering
calculations.

## Service Operations

The Bonsai server starts automatically after its model has been verified:

```bash
sudo systemctl status bonsai-model-prepare.service bonsai-llama.service bonsai-gate.service
curl --fail http://127.0.0.1:8094/health
curl --fail http://127.0.0.1:8094/metrics
```

Text request (via the gate, same path as Paperless uses):

```bash
curl --fail-with-body http://127.0.0.1:8094/v1/chat/completions \
  --header 'Content-Type: application/json' \
  --data '{
    "model": "bonsai-ternary-27b",
    "messages": [
      {"role": "user", "content": "Return three categories for this document title: Water bore inspection report"}
    ]
  }'
```

Vision request with a local image:

```bash
image_data="data:image/jpeg;base64,$(base64 --wrap=0 ./example.jpg)"
jq -n --arg image "$image_data" '{
  model: "bonsai-ternary-27b",
  messages: [{
    role: "user",
    content: [
      {type: "text", text: "Describe and categorise this image."},
      {type: "image_url", image_url: {url: $image}}
    ]
  }]
}' | curl --fail-with-body http://127.0.0.1:8086/v1/chat/completions \
  --header 'Content-Type: application/json' \
  --data-binary @-
```

CPU image requests default to a 1,024 vision-token cap to keep latency
reasonable. Set `repo.bonsai.imageMaxTokens = 0` for uncapped OCR/detail work,
or choose a value up to 4,096.

Useful logs:

```bash
sudo journalctl -u bonsai-model-prepare.service -n 100 --no-pager
sudo journalctl -u bonsai-llama.service -n 100 --no-pager
```

Disable the running services without deleting the persisted artifacts:

```nix
repo.bonsai.enable = false;
```
