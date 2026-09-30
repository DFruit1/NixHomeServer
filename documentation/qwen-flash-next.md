# Qwen3.8-Flash-Next Local AI

The `qwen-flash-next` application module serves Qwen3.8-Flash-Next through a
pinned mainline llama.cpp build and an OpenAI-compatible API. The model is a
125B-parameter mixture-of-experts preview of the Qwen4 architecture with about
6B active parameters, native vision, tool calling, and a 262,144-token context.

For this server, Qwen is the primary local inference endpoint. It starts at
boot as a loopback-only llama-server with the upstream chat UI. The UI is
available at `https://ai.<domain>` through the shared Kanidm authentication
gateway; access is granted to `ai-users`. The same host exposes the OpenAI
compatible API to signed-in browsers and trusted local clients. Bonsai is
currently disabled. If both apps are enabled later, the optional
background-job integration reserves Qwen for on-demand use and coordinates the
shared GPU.

Local clients use the loopback OpenAI-compatible API:

```text
http://127.0.0.1:8093/v1
```

The stable API model name is `qwen3.8-flash-next`.

## Model Artifacts

The module pins `unsloth/Qwen3.8-Flash-Next-GGUF` at revision
`38bb39ee97821de2c9009abb7e93950eec396e66` and downloads the IQ4_XS
quantization (roughly 94 GB across three shards), the F16 multimodal projector,
and the shared Q8_0 MTP (NextN) draft head (2.6 GiB, `MTP/` subfolder). Every
artifact has a pinned size and SHA-256 hash in the NixOS module; a partial
download resumes, a completed file must pass its checksum, and replacement is
atomic.

Artifacts live under `/mnt/data/qwen-flash-next/models` because the system SSD
does not have room for them. That directory is on the data pool, is not a Kopia
snapshot root, and is retained if this module is later removed.

Monitor the initial download with:

```bash
sudo journalctl -fu qwen-flash-next-model-prepare.service
```

## Runtime Compatibility Decision

Qwen3.8-Flash-Next uses the new `qwen4exp` architecture, which is newer than
the llama.cpp revision shipped by the nixpkgs channels this host pins, and its
MTP (NextN) speculative decoding is not in mainline yet. The shared runtime in
`lib/llama-cpp-runtime.nix` is therefore pinned to
`danielhanchen/llama.cpp` at
`6fcaa16f4b360649933a54d1f91ad40ed35c0e11`, the head of the branch behind
upstream PR #28243 ("models: Qwen3.8-Flash-Next MTP"), which is current master
plus the NextN/MTP graph and is the route Unsloth documents for the MTP heads.
It still builds every other architecture (including Bonsai). Revert the URL to
`ggml-org/llama.cpp` once #28243 merges, and re-verify the MTP canary.

- MTP pull request: <https://github.com/ggml-org/llama.cpp/pull/28243>
- Fork source: <https://github.com/danielhanchen/llama.cpp>
- Model repository: <https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF>

## Enabling

```nix
# vars.nix
applications.enabled = [ ... "qwen-flash-next" ];

# host configuration
repo.qwenFlashNext.enable = true;
```

`repo.qwenFlashNext.loadAtBoot` (default `true`) controls the boot-time start.
When Qwen and Bonsai are enabled together, the background integration defaults
it to `false` so the UI model keeps the GPU until a job explicitly starts the
Qwen unit. Start it with `sudo systemctl start qwen-flash-next-llama.service`
and stop it with `sudo systemctl stop qwen-flash-next-llama.service`.

## Memory And Context

The IQ4_XS weights need about 94 GB before runtime overhead. This host has
128 GB of RAM, and ZFS ARC reclaims cache under pressure, but the model still
shares the machine with the rest of the stack. `repo.qwenFlashNext.contextSize = 0`
selects a conservative tier at startup instead of blindly asking for the full
training context:

| Physical RAM | Context |
| --- | ---: |
| up to 11 GiB | 8,192 |
| 12–23 GiB | 16,384 |
| 24–35 GiB | 32,768 |
| 36–71 GiB | 65,536 |
| 72 GiB or more | 131,072 |

Set an explicit value up to 262,144 if the host has headroom:

```nix
repo.qwenFlashNext.contextSize = 32768;
```

The host uses a Q8_0 KV cache, which roughly halves KV memory and bandwidth at
a negligible quality cost and speeds up longer generations:

```nix
repo.qwenFlashNext.kvCacheType = "q8_0"; # "f16" (default), "q8_0", or "q4_0"
```

Q4_0 is smaller but noticeably lossier; keep Q8_0 or F16 when quality matters.

## Sampling

Server defaults follow the model card's thinking-mode recommendation:
`temperature = 1.0`, `top_p = 0.95`, `top_k = 20`, `min_p = 0`, repetition
penalty `1.0`. For instruct (non-thinking) usage the card recommends
`temperature = 0.7`, `top_p = 0.80`, and repetition penalty `1.5`:

```nix
repo.qwenFlashNext.temperature = 0.7;
repo.qwenFlashNext.topP = 0.80;
repo.qwenFlashNext.repetitionPenalty = 1.5;
```

Thinking behaviour (`enable_thinking`, `preserve_thinking`, `reasoning_effort`)
is selected per request through the chat template; `--jinja` is enabled so
OpenAI-compatible clients can pass `chat_template_kwargs`.

Multi-Token-Prediction (MTP) speculative decoding is **enabled**
(`repo.qwenFlashNext.mtp.enable = true`). The server loads the shared Q8_0
NextN head with `--model-draft` and runs `--spec-type draft-mtp
--spec-draft-n-max 4`; the head drafts a few tokens per step and the main model
verifies them exactly, so the output is unchanged and only the speed differs.
Published results for this model are roughly 1.3-1.7x decode at low concurrency
(about 2x on code and structured/tool output, less on free-form prose), which is
the regime this server's agentic workloads sit in. MTP is single-slot, so it
stays paired with `--parallel 1`.

Two operational details matter. The head lives in the Hugging Face `MTP/`
subfolder, which llama.cpp sidecar auto-discovery does not search, so `-md` must
be passed explicitly — the module does this. A `shared-` head also logs one
`borrow_shared_tensor` error at startup and continues; it is expected, and its
only consequence is that the automatic memory fit does not count the draft's
memory. Confirm speculative decoding is active by looking for the
`draft acceptance = ...` line in the journal; if it never appears, MTP did not
engage.

Measured on this host with a short temperature-0 code prompt, MTP-only decode is
about 11 tok/s warm at ~55% draft acceptance, up from the ~8 tok/s n-gram-only
baseline. A sweep of the cheap, quality-neutral levers then selected the current
profile:

- `--cache-type-k/v q8_0` plus `--n-cpu-moe 38`: best decode and prefill,
  because the smaller KV frees VRAM for four more expert layers. On an
  8K-token prompt, prefill rose from 89 tok/s (`n-cpu-moe 40`) to 97.7 tok/s
  (`n-cpu-moe 38`); short-prompt decode is about 12 tok/s.
- `--lazy-mode on` matched `n-cpu-moe 38` on prefill (97.5 vs 97.7) but the
  default is `auto`, so it was left alone rather than pinning a mode.
- `--ubatch-size 4096`: fails to allocate compute buffers on this host. Stay at
  2048.
- `--threads-batch 16` (SMT oversubscription): clearly worse, decode fell to
  ~4-9 tok/s. Threads stay at the 8 physical cores.
- `--lazy-mode off` and `ngram-mod` chaining: no reliable gain, so left at the
  default (`auto`) and removed respectively. n-gram self-speculation in general
  no longer pays once MTP is on.
- `--reasoning-budget` is available and deliberately left unset to preserve
  reasoning quality; set a per-request budget only when latency matters more.

The Vulkan shader cache now persists across restarts. Prefill remains the
bottleneck at roughly 12 tok/s, dominated by the PLE table path; that is the
next thing worth optimizing.

## GPU Acceleration (Intel Arc Pro B60)

The standalone Qwen server enables Vulkan on the installed Arc Pro B60. Its
Resizable BAR is enabled. Because the module no longer runs under the shared
router, the layer split and loader flags are set directly on the host:

```nix
repo.qwenFlashNext.gpu.enable = true;   # builds llama.cpp with GGML_VULKAN
repo.qwenFlashNext.gpuLayers = "all";   # offload every non-expert tensor
repo.qwenFlashNext.cpuMoe = false;      # --n-cpu-moe supersedes --cpu-moe
repo.qwenFlashNext.kvCacheType = "q8_0"; # frees VRAM for more expert layers
repo.qwenFlashNext.extraArgs = [
  "--n-cpu-moe" "38"        # first 38 of 48 expert layers stay in system RAM
  "--load-mode" "none"      # bypass mmap for the PLE table (see below)
  "--no-host"
  "--no-op-offload"
  "--batch-size" "2048"
  "--ubatch-size" "2048"
  "--threads" "8"
  "--threads-batch" "8"
];
```

`--load-mode none` matters more on this model than on a typical GGUF. qwen4exp
carries a ~51B per-layer-embedding (PLE) n-gram table that is read sparsely at
prefill; the upstream mmap path over-reads it and dominates real-text prefill,
so bypassing mmap is a large TTFT win (upstream PR #28136 reports over 2x on
realistic text). `--ubatch-size 2048` likewise amortizes prompt tokens over
fewer expert-weight passes on the CPU-bound MoE path.

The unit sets a writable `CacheDirectory` and points `HOME`/`XDG_CACHE_HOME` at
it. Under `ProtectSystem=strict` the Mesa/Vulkan shader cache was otherwise
unwritable and recompiled on every start; the module now persists it at
`/var/cache/qwen-flash-next`.

When enabled, the module activates `hardware.graphics` with the Intel compute
runtime, media driver, mesa (ANV Vulkan driver), and Vulkan tools, and the
systemd unit gains access to the `render` and `video` groups and `/dev/dri`.

Expectations with a single 24 GB Arc Pro B60 and ~87 GiB of weights:

- `n-gpu-layers = all` plus `n-cpu-moe = 38` sends every dense and attention
  tensor to the GPU and keeps the last 10 of 48 layers' MoE experts in VRAM
  while the first 38 layers' experts stay in system RAM. Offloading the whole
  expert pool is not possible.
- The Q8_0 KV cache is what makes `n-cpu-moe = 38` fit. With an F16 KV cache
  the extra expert layers overflow the 24 GiB card (the older F16 profile could
  only reach 42, and `38` was recorded as overflow); the smaller KV frees enough
  VRAM for four more layers. KV and compute buffers are allocated at load, so a
  configuration that starts is stable. Measured on this host, moving 42 to 38
  with Q8_0 KV raised 8K-prompt prefill from 89 to 97.7 tok/s and warm
  short-prompt decode from roughly 11 to 12 tok/s.
- The UI model is stopped before Qwen starts so the card is free; do not run
  both models at once.
- ReBAR must be enabled in firmware; without it llama.cpp falls back to slow
  paths on Arc.
- Vulkan support for this very new architecture is less mature than the CPU
  path. If the Vulkan build fails to serve, fall back to CPU inference
  (`repo.qwenFlashNext.gpu.enable = false`) and report the failure upstream.

## Service Operations

When Bonsai and Qwen are both enabled, Qwen does not start at boot. Verify the
model artifacts, then start it for a background run:

```bash
sudo systemctl status qwen-flash-next-model-prepare.service
sudo systemctl start qwen-flash-next-llama.service
curl --fail http://127.0.0.1:8093/health
```

Starting Qwen stops `bonsai-llama.service`; stopping Qwen restarts it.

Text request:

```bash
curl --fail-with-body http://127.0.0.1:8093/v1/chat/completions \
  --header 'Content-Type: application/json' \
  --data '{
    "model": "qwen3.8-flash-next",
    "messages": [
      {"role": "user", "content": "Summarise this title in three categories: Water bore inspection report"}
    ]
  }'
```

Disable the running services without deleting the persisted artifacts:

```nix
repo.qwenFlashNext.enable = false;
```

## Hardware power and memory checks

The host keeps the Arc Pro B60 sustained power cap at 175 W. The firmware's
440 W `power1_crit` is an instantaneous limit, not a recommended sustained
cap; it is left untouched. `gpu-power-limit.service` verifies sysfs readback
and its timer reapplies the cap after driver resets/resume within about a
minute. Hardware telemetry exposed by this kernel is limited to the power
cap and its 15 ms averaging interval; a cap readback is not a wattmeter.

```bash
sudo systemctl start gpu-power-limit.service
sudo journalctl -u gpu-power-limit.service -n 20 --no-pager
cat /sys/class/hwmon/hwmon*/name
cat /sys/module/zfs/parameters/zfs_arc_max
```

The ARC tuning service is attached to `multi-user.target`, since this host
has no `zfs-import-cache.service`. Its 8% ceiling must be visible in the
live module parameter after activation.
