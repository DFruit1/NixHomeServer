# Qwen3.8-Flash-Next Local AI

The `qwen-flash-next` application module serves Qwen3.8-Flash-Next through a
pinned mainline llama.cpp build and an OpenAI-compatible API. The model is a
125B-parameter mixture-of-experts preview of the Qwen4 architecture with about
6B active parameters, native vision, tool calling, and a 262,144-token context.

The module is **disabled by default** and is not part of `vars.applications.enabled`.
Nothing is imported or built until it is explicitly enabled on the host.

The API binds only to `127.0.0.1`. It has no API authentication and is not
published through Caddy, Cloudflare, NetBird, or the LAN firewall. Local
applications use:

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

Unsloth ships a Multi-Token-Prediction (MTP) head for 1.3–1.7× faster
inference. It is not wired in yet; speculative decoding can be added later via
`repo.qwenFlashNext.extraArgs`.

## GPU Acceleration (Intel Arc Pro B60)

The Vulkan path is wired but **disabled** until the GPU is installed and the
NixOS graphics stack can be validated on the host.

```nix
repo.qwenFlashNext.gpu.enable = true;      # builds llama.cpp with GGML_VULKAN
repo.qwenFlashNext.gpuLayers = "auto";     # offload as many layers as fit
repo.qwenFlashNext.cpuMoe = true;          # keep MoE experts in system RAM
```

When enabled, the module activates `hardware.graphics` with the Intel compute
runtime, media driver, mesa (ANV Vulkan driver), and Vulkan tools, and the
systemd unit gains access to the `render` and `video` groups and `/dev/dri`.

Expectations with a single 24 GB Arc Pro B60 and ~94 GB of weights:

- Use `--cpu-moe` (`repo.qwenFlashNext.cpuMoe = true`): dense and attention
  weights on the GPU, MoE experts in RAM. Offloading the whole model is not
  possible.
- ReBAR must be enabled in firmware; without it llama.cpp falls back to slow
  paths on Arc.
- Vulkan support for this very new architecture is less mature than the CPU
  path. If the Vulkan build fails to serve, fall back to CPU inference
  (`repo.qwenFlashNext.gpu.enable = false`) and report the failure upstream.

## Service Operations

```bash
sudo systemctl status qwen-flash-next-model-prepare.service qwen-flash-next-llama.service
curl --fail http://127.0.0.1:8093/health
```

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
