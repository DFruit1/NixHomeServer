# Bonsai Local AI

The `bonsai` application module serves PrismML's Ternary Bonsai 27B
vision-language model through llama.cpp's OpenAI-compatible API. It is intended
as a private local inference foundation for document classification, media
categorisation, metadata extraction, tool calling, and future system
automation.

The API deliberately binds only to `127.0.0.1`. It has no API authentication
and is not published through Caddy, Cloudflare, NetBird, or the LAN firewall.
Local applications should use:

```text
http://127.0.0.1:8086/v1
```

The stable API model name is `bonsai-ternary-27b`.

## Runtime Compatibility Decision

The module pins the official PrismML llama.cpp fork at commit
`7529fdaaf99ffdc5ca71ace9c7409a56b27ad92f` (2026-07-20). This was the newest
`prism` branch commit when the module was implemented.

Mainline llama.cpp has since acquired a `Q2_0` tensor type, but that alone does
not establish equivalent support for this model. PrismML's model card still
directs CUDA, Metal, and CPU users to its fork because it includes the custom
Q2_0 hybrid-attention kernels used by Ternary Bonsai 27B. The fork is therefore
the conservative compatible choice until PrismML explicitly documents
mainline support or the relevant work is demonstrably merged upstream.

Authoritative references:

- [Ternary Bonsai 27B model card](https://huggingface.co/prism-ml/Ternary-Bonsai-27B-gguf)
- [PrismML llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp/tree/prism)
- [Mainline llama.cpp](https://github.com/ggml-org/llama.cpp)

The runtime is built from source by Nix and is currently CPU-only because this
host has no declared GPU hardware support. Do not merely enable a CUDA, ROCm,
or Vulkan build flag: first add the matching NixOS driver/toolkit configuration
and validate the target hardware.

## Model Artifacts And Persistence

On first service start, `bonsai-model-prepare.service` downloads and verifies:

- `Ternary-Bonsai-27B-Q2_0.gguf` — 7,165,121,600 bytes.
- `Ternary-Bonsai-27B-mmproj-Q8_0.gguf` — 629,246,880 bytes.

Both files come from the official
`prism-ml/Ternary-Bonsai-27B-gguf` repository at commit
`abbae723028d71be674e71e1a71201a6f43fab22`. Their expected sizes and SHA-256 LFS
object hashes are declared in the NixOS module. A partial download resumes, a
completed file must pass its checksum, and replacement is atomic.

Artifacts live below `/var/lib/bonsai/models`. The core impermanence module
persists `/var/lib/bonsai` even if the application module is later removed.
Kopia intentionally does not back up these approximately 7.8 GB of reproducible
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

`repo.bonsai.contextSize = 0` is the default. It never asks llama.cpp to load
the full 262K training context blindly. Instead, startup selects a conservative
physical-RAM tier:

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

## Service Operations

The service starts automatically after both artifacts have been verified:

```bash
sudo systemctl status bonsai-model-prepare.service bonsai-llama.service
curl --fail http://127.0.0.1:8086/health
```

Text request:

```bash
curl --fail-with-body http://127.0.0.1:8086/v1/chat/completions \
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
