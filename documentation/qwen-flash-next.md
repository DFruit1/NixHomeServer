# Qwen3.8-Flash-Next Local AI

The `qwen-flash-next` application module serves Qwen3.8-Flash-Next through a
pinned mainline llama.cpp build and an OpenAI-compatible API. The model is a
125B-parameter mixture-of-experts preview of the Qwen4 architecture with about
6B active parameters, native vision, tool calling, and a 262,144-token context.

In this repository Qwen is reserved for background jobs. It runs as its own
loopback-only llama-server with no web UI, so `https://ai.sydneybasiniot.org`
never offers it: that UI is Bonsai-only (see [Bonsai operations](bonsai.md)).
Qwen does not start at boot. A background job starts
`qwen-flash-next-llama.service` when it needs the model, and stopping it frees
its RAM and the GPU again. Because Bonsai and Qwen share the single 24 GiB Arc
card, starting Qwen stops the Bonsai UI model first; Bonsai is restarted
automatically when the background run ends.

Background consumers use the loopback OpenAI-compatible API:

```text
http://127.0.0.1:8093/v1
```

The stable API model name is `qwen3.8-flash-next`.

## Model Artifacts

The module pins `unsloth/Qwen3.8-Flash-Next-GGUF` at revision
`38bb39ee97821de2c9009abb7e93950eec396e66` and downloads the IQ4_XS
quantization (roughly 94 GB across three shards) plus the F16 multimodal
projector. Every artifact has a pinned size and SHA-256 hash in the NixOS
module; a partial download resumes, a completed file must pass its checksum,
and replacement is atomic.

Artifacts live under `/mnt/data/qwen-flash-next/models` because the system SSD
does not have room for them. That directory is on the data pool, is not a Kopia
snapshot root, and is retained if this module is later removed.

Monitor the initial download with:

```bash
sudo journalctl -fu qwen-flash-next-model-prepare.service
```

## Runtime Compatibility Decision

Qwen3.8-Flash-Next uses the new `qwen4exp` architecture, which is newer than
the llama.cpp revision shipped by the nixpkgs channels this host pins. The
module therefore pins mainline `ggml-org/llama.cpp` at `b10897` and builds it
from source with Nix.

- Upstream llama.cpp: <https://github.com/ggml-org/llama.cpp>
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

For long contexts, Q4 KV caching reduces memory at a modest quality cost:

```nix
repo.qwenFlashNext.quantizeKvCache = true;
```

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

Unsloth ships separate Multi-Token-Prediction (MTP) draft heads for 1.3–1.7×
faster inference. They are not used here: the heads (`nextn`/`hc_head_*`
tensors) require the MTP graph from the Unsloth llama.cpp fork or upstream pull
request #28243, and the pinned mainline `b10897` runtime fails to load them
with a tensor-name mismatch. Enabling MTP means changing the pinned runtime,
not just adding a flag.

The host configuration instead enables self-speculative n-gram decoding
(`--spec-type ngram-simple`). It needs no draft model — llama.cpp builds a
lookup table on the host CPU from the accepted context and proposes candidate
tokens that the main model verifies exactly. On this host it measured roughly
+27% decode throughput (7.95 vs 6.27 tok/s, 22% draft acceptance) on ordinary
prose at temperature 0; the gain is larger on repetitive text and smaller on
unpredictable output, and it turns off automatically where it does not help.

## GPU Acceleration (Intel Arc Pro B60)

The standalone Qwen server enables Vulkan on the installed Arc Pro B60. Its
Resizable BAR is enabled. Because the module no longer runs under the shared
router, the layer split and loader flags are set directly on the host:

```nix
repo.qwenFlashNext.gpu.enable = true;   # builds llama.cpp with GGML_VULKAN
repo.qwenFlashNext.gpuLayers = "all";   # offload every non-expert tensor
repo.qwenFlashNext.cpuMoe = false;      # --n-cpu-moe supersedes --cpu-moe
repo.qwenFlashNext.extraArgs = [
  "--n-cpu-moe" "42"        # first 42 of 48 expert layers stay in system RAM
  "--spec-type" "ngram-simple"
  "--load-mode" "none"
  "--no-host"
  "--no-op-offload"
];
```

When enabled, the module activates `hardware.graphics` with the Intel compute
runtime, media driver, mesa (ANV Vulkan driver), and Vulkan tools, and the
systemd unit gains access to the `render` and `video` groups and `/dev/dri`.

Expectations with a single 24 GB Arc Pro B60 and ~87 GiB of weights:

- `n-gpu-layers = all` plus `n-cpu-moe = 42` sends every dense and attention
  tensor to the GPU and keeps the last 6 of 48 layers' MoE experts in VRAM
  while the first 42 layers' experts stay in system RAM. Offloading the whole
  expert pool is not possible.
- Measured on this host, `n-cpu-moe = 42` beats `--cpu-moe` by about 9% decode
  and 18% prefill. Going to `n-cpu-moe = 38` (10 expert layers on the GPU)
  overflows the 24 GiB card and decode collapses to roughly half.
- The UI model is stopped before Qwen starts so the card is free; do not run
  both models at once.
- ReBAR must be enabled in firmware; without it llama.cpp falls back to slow
  paths on Arc.
- Vulkan support for this very new architecture is less mature than the CPU
  path. If the Vulkan build fails to serve, fall back to CPU inference
  (`repo.qwenFlashNext.gpu.enable = false`) and report the failure upstream.

## Service Operations

The Qwen server does not start at boot while Bonsai is enabled. Verify the
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
