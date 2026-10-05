# Qwen3.8-27B Local AI

The `qwen-27b` application module serves Qwen3.8-27B through a pinned
llama.cpp build and an OpenAI-compatible API. The model is a 27B-parameter dense
vision-language model with native image and video understanding, tool calling,
flexible thinking control, and a 262,144-token native context.

For this server, Qwen is the primary local inference endpoint. It starts at boot
as a loopback-only llama-server with the upstream chat UI. The UI is available at
`https://ai.<domain>` through the shared Kanidm authentication gateway; access is
granted to `ai-users`. The same host exposes the OpenAI compatible API to
signed-in browsers and trusted local clients. Bonsai is currently disabled. If
both apps are enabled later, the optional background-job integration reserves
Qwen for on-demand use and coordinates the shared GPU.

Local clients use the loopback OpenAI-compatible API:

```text
http://127.0.0.1:8093/v1
```

The stable API model name is `qwen3.8-27b-q4_km`.

## Model Artifacts

The module pins `ukisai/Swift-1.5-Qwen3.8-27B-GGUF` at revision
`14bfe4b42be4a925d98816db830155f476c605e7` and downloads the Q4_K_M
quantization (about 16.2 GiB in a single file) and Swift's own F16 multimodal
projector (885 MiB). This repository publishes no MTP draft head, so
`repo.qwen27b.model.mtpFile` is empty and `mtp.enable` must stay false; an
assertion enforces that. Every artifact has a pinned size and SHA-256 hash in
the NixOS module; a partial download resumes, a completed file must pass its
checksum, and replacement is atomic.

Swift 1.5 is UkisAI's reasoning-efficient post-training of
`Qwen/Qwen3.8-27B`. Measured on this host against the foundation Q4_K_M with
identical flags, it decodes at about 17.45 tok/s versus 13.15, a 33% gain
reproduced with the run order reversed to rule out a warm-GPU artifact. Prefill
is within noise. The accuracy claims on the model card were not independently
verified here; the speed difference was.

Artifacts live under `/mnt/data/qwen-27b/models` because the system SSD does not
have room for them. That directory is on the data pool, is not a Kopia snapshot
root, and is retained if this module is later removed.

Monitor the initial download with:

```bash
sudo journalctl -fu qwen-27b-model-prepare.service
```

### Retired Qwen3.8-Flash-Next weights

The previous model, `unsloth/Qwen3.8-Flash-Next-GGUF` (IQ4_XS, about 94 GB plus
a 2.6 GiB MTP head), was archived rather than deleted:

```text
/mnt/data/archive/qwen-flash-next
```

Nothing in the configuration reads that directory. Its files are owned by the
retired `qwen-flash-next` service UID, so restoring it means re-owning the tree
by hand. Deleting it later is safe and frees about 97 GB on the data pool.

## Runtime Compatibility Decision

Qwen3.8 support and its MTP (NextN) speculative decoding are newer than the
llama.cpp revision shipped by the nixpkgs channels this host pins. The shared
runtime in `lib/llama-cpp-runtime.nix` is therefore pinned to
`danielhanchen/llama.cpp` at `6fcaa16f4b360649933a54d1f91ad40ed35c0e11`, the
head of the branch behind upstream PR #28243 ("models: Qwen3.8 MTP"), which is
current master plus the NextN/MTP graph and is the route Unsloth documents for
the MTP heads. It still builds every other architecture (including Bonsai).
Revert the URL to `ggml-org/llama.cpp` once #28243 merges.

- MTP pull request: <https://github.com/ggml-org/llama.cpp/pull/28243>
- Fork source: <https://github.com/danielhanchen/llama.cpp>
- Foundation weights: <https://huggingface.co/unsloth/Qwen3.8-27B-GGUF>
- Model repository: <https://huggingface.co/ukisai/Swift-1.5-Qwen3.8-27B-GGUF>

## Enabling

```nix
# vars.nix
applications.enabled = [ ... "qwen-27b" ];

# host configuration
repo.qwen27b.enable = true;
```

`repo.qwen27b.loadAtBoot` (default `true`) controls the boot-time start. When
Qwen and Bonsai are enabled together, the background integration defaults it to
`false` so the UI model keeps the GPU until a job explicitly starts the Qwen
unit. Start it with `sudo systemctl start qwen-27b-llama.service` and stop it
with `sudo systemctl stop qwen-27b-llama.service`.

## Memory And Context

The Q4_K_M weights are about 16.5 GB and offload entirely to the GPU, so the
model no longer competes with ZFS ARC for system RAM. `repo.qwen27b.contextSize
= 0` still selects a conservative tier from physical RAM at startup rather than
blindly asking for the full training context:

| Physical RAM | Context |
| --- | ---: |
| up to 11 GiB | 8,192 |
| 12–23 GiB | 16,384 |
| 24–35 GiB | 32,768 |
| 36–71 GiB | 65,536 |
| 72 GiB or more | 131,072 |

This host pins an explicit 128K, which is double the minimum Hermes Agent
recommends for tool workflows:

```nix
repo.qwen27b.contextSize = 131072;
```

Set an explicit value up to 262,144 if the host has VRAM headroom. This host has
just enough for 128K, and 262,144 would not fit — see the VRAM budget below.

The host uses a Q8_0 KV cache, which roughly halves KV memory and bandwidth at a
negligible quality cost and is what keeps the 128K context inside the card:

```nix
repo.qwen27b.kvCacheType = "q8_0"; # "f16" (default), "q8_0", or "q4_0"
```

Q4_0 is smaller but noticeably lossier; keep Q8_0 or F16 when quality matters.

ZFS ARC is no longer clamped for this module. `zfs-arc-tune` uses the standard
`zfsArcMaxPercent` ceiling (50% by default) whether or not Qwen is enabled; the
previous 8% override existed only to make room for the 94 GB Flash-Next weights.

## Stability And Quality Choices

The host profile is deliberately biased toward stability and output quality over
peak speed. The choices that matter:

- **Swap is forbidden for this unit** (`MemorySwapMax = "0"`). The host swaps to
  zram with `vm.swappiness = 150`; compressing inference working sets into zram
  under pressure thrashes the whole machine (multi-second SSH stalls, ~1 tok/s
  inference). With swap off for Qwen, memory pressure is absorbed by reclaimable
  page cache, or at worst an OOM restart of Qwen. `MemoryHigh`/`MemoryMax`
  (`32G`/`48G`) are runaway guards, well above measured usage, not working
  limits.
- **Everything offloads.** `gpuLayers = "all"` sends every tensor to the card;
  there is no CPU-resident expert pool to size any more.
- **Vision runs on the CPU.** `projectorOnCpu = true` passes
  `--no-mmproj-offload`, so the projector and vision encoder stay in system RAM
  and VRAM is dedicated to the language model and the KV cache. Image and video
  input keep working; image encoding costs CPU and a little latency instead of
  VRAM.
- **Video is sampled at half rate.** `videoFps = 2.0` rather than llama.cpp's
  4.0. The vision encoder allocates activations per sampled frame, so halving
  the rate shrinks the largest allocation the process can make. It costs
  temporal detail on video question answering.
- **Restart resistance, not just stability.** `StartLimitBurst = 10` in a
  15-minute window, up from the systemd default of 3. A device-local VRAM
  allocation failure is not survivable in-process: ggml-vulkan returns
  nullptr rather than spilling the tensor to system RAM, so recovery means
  restarting the unit. With a burst of 3, three oversized vision requests would
  latch the unit off and take the AI server down until someone intervened.
- **No MTP.** `mtp.enable = false`, and this pin has no draft head. Measured
  15-21% *slower* than plain decode on this host at 43% draft acceptance, so
  this is a measured decision rather than an untested default.
- **One model at a time.** The Q4_K_M weights fit the 24 GiB card, but they do
  not fit alongside Bonsai's weights. The background integration still stops the
  UI model before starting Qwen.
- **Q8_0 KV cache + flash attention** keep the 128K context near-lossless and
  cheap enough to fit; step up to F16 only if you raise the context.
- **Quality is preserved by construction**: Q4_K_M weights and
  thinking/reasoning-preserve left at their template defaults. Do not globally
  disable thinking (it breaks arithmetic) or turn off reasoning-preserve (it
  drops multi-turn continuity) if quality matters.
- **Speed without quality loss**: have clients send per-request
  `enable_thinking: false` for trivia and `reasoning_effort: low|medium` for
  normal work; keep the default for hard reasoning.

## Sampling

Server defaults follow the model card's thinking-mode recommendation:
`temperature = 1.0`, `top_p = 0.95`, `top_k = 20`, `min_p = 0`, repetition
penalty `1.0`. For instruct (non-thinking) usage the card recommends
`temperature = 0.7`, `top_p = 0.80`, and repetition penalty `1.5`:

```nix
repo.qwen27b.temperature = 0.7;
repo.qwen27b.topP = 0.80;
repo.qwen27b.repetitionPenalty = 1.5;
```

Thinking behaviour (`enable_thinking`, `preserve_thinking`, `reasoning_effort`)
is selected per request through the chat template; `--jinja` is enabled so
OpenAI-compatible clients can pass `chat_template_kwargs`.

Multi-Token-Prediction (MTP) speculative decoding is **disabled** and
unavailable for this pin. Measured on the foundation weights, the Q4_0 NextN
head at `--spec-type draft-mtp --spec-draft-n-max 4` ran at 10.6-11.6 tok/s
against 13.4 for plain decode, with 43% draft acceptance and a mean draft
length of 2.5. The draft forward pass costs more than the accepted tokens save.
The Swift repository also publishes no MTP head.

## GPU Acceleration (Intel Arc Pro B60)

The standalone Qwen server enables Vulkan on the installed Arc Pro B60. Its
Resizable BAR is enabled. The flags on the host are:

```nix
repo.qwen27b.gpu.enable = true;      # builds llama.cpp with GGML_VULKAN
repo.qwen27b.gpuLayers = "all";      # offload every tensor
repo.qwen27b.projectorOnCpu = true;  # --no-mmproj-offload
repo.qwen27b.kvCacheType = "q8_0";   # keeps the 128K context in VRAM
repo.qwen27b.extraArgs = [
  "--batch-size" "2048"
  "--ubatch-size" "2048"
  "--threads" "8"
  "--threads-batch" "8"
];
```

The Arc-specific loader workarounds used for Flash-Next are gone. `--n-cpu-moe`,
`--lazy-mode on`, `--load-mode none`, `--no-host` and `--no-op-offload` all
existed to squeeze a 94 GB mixture-of-experts model into a 24 GiB card; a 16.5 GB
dense model has none of those constraints. If VRAM allocation ever fails with
`ggml_vulkan: Device memory allocation of size ... failed`, re-add `--no-host`
first — it bypasses the host-visible buffer and allows extra device buffers.

The unit sets a writable `CacheDirectory` and points `HOME`/`XDG_CACHE_HOME` at
it. Under `ProtectSystem=strict` the Mesa/Vulkan shader cache was otherwise
unwritable and recompiled on every start; the module persists it at
`/var/cache/qwen-27b`.

When enabled, the module activates `hardware.graphics` with the Intel compute
runtime, media driver, mesa (ANV Vulkan driver), and Vulkan tools, and the
systemd unit gains access to the `render` and `video` groups and `/dev/dri`.

Expectations with a single 24 GiB Arc Pro B60:

- `n-gpu-layers = all` puts the whole 16.5 GB model on the card. With the
  projector on the CPU and a Q8_0 128K KV cache there is still room for the
  prefill compute buffers; a long-context prefill is the first thing to watch if
  memory ever gets tight.
- The UI model is stopped before Qwen starts so the card is free; do not run both
  models at once.
- ReBAR must be enabled in firmware; without it llama.cpp falls back to slow
  paths on Arc.
- Vulkan support for this architecture is less mature than the CPU path. If the
  Vulkan build fails to serve, fall back to CPU inference
  (`repo.qwen27b.gpu.enable = false`) and report the failure upstream.

### VRAM Budget For The Context Setting

Raising `repo.qwen27b.contextSize` spends card memory, not host memory, because
the KV cache is allocated in VRAM whenever `gpuLayers = "all"`. ggml-vulkan does
not spill a failed allocation to system RAM: it returns `nullptr` and the unit
restarts. So the budget is a hard ceiling, and it is worth checking before
raising the value rather than after.

The KV cost is derivable from the GGUF header alone. This model is `qwen35` with
64 blocks, `full_attention_interval = 4` (so 16 full-attention layers keep a KV
cache; the other 48 are gated-delta-net layers with a fixed-size recurrent state),
`head_count_kv = 4`, and key/value length 256. That is 4 x 256 = 1,024 elements
per tensor per token per layer, or 2,048 for K and V together. Q8_0 costs 34 bytes
per 32 elements, so:

```text
34,816 bytes/token = 16 layers x 2 tensors x 1,024 elements x (34/32)
64K context  ->  2.13 GiB KV
128K context ->  4.25 GiB KV
262K context ->  8.50 GiB KV
```

The budget for 128K, measured on this card by loading exactly the configuration
above and reading `/sys/kernel/debug/dri/*/vram0_mm`:

| Component | Size |
| --- | ---: |
| Q4_K_M weights, less the unused `blk.64` MTP tensors | 15.98 GiB |
| KV cache at 131072 tokens, Q8_0 | 4.25 GiB |
| Compute buffers, SSM state, Vulkan bookkeeping | 0.86 GiB |
| **Total, measured** | **21.09 GiB of 23.91 GiB** |
| Free after the load | 2.82 GiB |

That total was read after serving a 12,223-token prompt, so it covers the
worst-case full 2048-token ubatch rather than an idle server. Prefill held 259
tokens/s. To reproduce it, stop `qwen-27b-llama.service`, start `llama-server`
with the flags from this document plus `--ctx-size 131072`, read the counter,
and start the unit again.

262,144 does not fit: 8.50 GiB of KV cache alone would put the total near 25 GiB
against 23.91 GiB of card. If that context is ever needed, the levers in order of
preference are dropping to `kvCacheType = "q4_0"` (halves the KV again but is
noticeably lossier), keeping the projector on the CPU, or moving to a larger
card.

One trap worth knowing: with the card already mostly full, `llama-server` logs
`common_fit_params: failed to fit params to free device memory: n_gpu_layers
already set by user to -2, abort` and then starts anyway with the weights split
between card and host. It does not fail cleanly, and it serves requests at a
fraction of the speed. Treat that warning as a real out-of-memory signal rather
than noise, and check that no other workload is holding VRAM before reading a
slow inference run as a model problem.

## Tools: The Office Workflow

The `ai-tools` module serves an MCP tool endpoint that llama-server reaches as
its own tool set. Qwen therefore does not answer from the model's weights alone:
it can search the web, read a document you have shared, and write a spreadsheet
or a Word file back into a workspace folder. This section is the operator view
of that surface. The inference host is the entry point in `ai.<domain>`.

### How the tools reach the model

The pinned llama.cpp build can only reach an MCP server by spawning it as a
child process and speaking newline-delimited JSON-RPC over stdin. `ai-tools`
speaks MCP over Streamable HTTP on loopback instead, so it runs a second time as
a **stdio bridge**: `AI_TOOLS_TRANSPORT=stdio` makes the same binary speak the
framing llama.cpp drives and forward to the loopback endpoint every other client
uses.

```text
browser / MCP client ──HTTPS──▶ tools.<domain> ──▶ ai-tools.service (policy owner)
                                                            ▲
llama-server ──stdio child──▶ ai-tools (stdio bridge) ──loopback──┘
```

This is deliberate. `ai-tools` keeps sole ownership of the shared-root grant,
its service account and its sandbox. The child llama-server spawns holds no
grant of its own, reaches nothing but loopback, and re-validates nothing itself:
every path a tool receives is resolved by `ai-tools` against its configured root
before anything is opened. Disabling either app removes its half cleanly — with
`repo.aiTools.enable = false` the MCP server list is empty and no unit depends
on `ai-tools.service`.

llama-server prefixes every tool with the name its MCP config declared, so the
model sees `ai_tools_spreadsheet_read` rather than `spreadsheet_read`. That
prefix is what makes the tools visible to *every* client of the shared inference
endpoint, not just this one. The bridge restores the prefix on the way out and
strips it on the way in, and refuses any name outside it — a call for
`exec_shell_command` is refused as `unknown tool`, without an upstream call.

One ordering edge matters: `qwen-27b-llama` `wants=` and `after=`
`ai-tools.service`, because llama-server discovers MCP tools at startup and
would otherwise publish none.

### The tool surface

| Tool | Does | Formats | Access |
| --- | --- | --- | --- |
| `web_search` | Ranked results from the local SearXNG | — | loopback only |
| `convert_document` | Office file to text; spreadsheets become CSV | docx, odt, rtf, doc, xlsx, ods, pptx, odp | reads shared root |
| `spreadsheet_read` | **Every sheet**, each as an array of rows | xlsx, ods | reads shared root |
| `spreadsheet_write` | New workbook from sheets you supply | xlsx, ods | **writes workspace only** |
| `word_document` | Read or write a Word document | docx, odt | read root / **write workspace only** |

`spreadsheet_read` exists because `convert_document` returns only the *first*
sheet — Collabora's convert-to cannot do better, which is the whole reason the
native helper exists.

The read tools return a `not_retained` list on **every** response, naming
exactly what the round trip loses. Nothing is lost silently:

- **Spreadsheets**: cell formatting (fonts, fills, borders, number formats,
  column widths), merged ranges, conditional formatting, data validation, named
  ranges, charts, images, pivot tables and their caches, comments, hyperlinks,
  and the cached *result* of a formula (formula text comes back instead). Hidden
  rows and columns are returned but not marked as hidden, and a bare date reads
  back as midnight.
- **Word**: tracked changes, comments, footnotes and endnotes, headers and
  footers, embedded objects (images, charts, equations, OLE), never-calculated
  fields, section properties beyond the final section, and document metadata.
  Numbering resolves to rendered text only.

A written document keeps paragraphs, runs (bold and italic) and tables, in
document order. A value xlsx genuinely cannot store — `NaN`, `Infinity` — is
refused before anything is written, naming the sheet, rather than being written
as an empty cell and lost.

### Reads are broad; writes are confined

This asymmetry is the design, and it is enforced at three independent layers.

**Reads** resolve against the whole shared root: a generated answer may be built
from anything you have already shared. A read refuses an absolute path, a parent
traversal, a NUL byte, a hidden entry, and any path whose canonical result
escapes the root — so a symlink cannot get out.

**Writes** resolve against one directory only:

```text
<sharedRoot>/ai-workspace
```

The caller supplies a *name*, never a path. The extension comes from the format
and the directory comes from the workspace, so the only free input is a relative
name. A write additionally refuses:

- a final path component that is itself a symlink (it would land wherever the
  link points);
- a parent directory that does not already exist, so a write can never create a
  structure outside the workspace;
- replacing an existing file unless `overwrite` is explicitly `true`.

The systemd unit makes the refusal real rather than advisory. `ProtectSystem=strict`
plus `ReadOnlyPaths=[sharedRoot]` and a nested
`ReadWritePaths=[workspaceRoot]` means the whole shared root is read-only to the
service and only the workspace is writable, *even if a future tool forgets to
check*. The ACL unit grants `g:ai-tools` read over the shared root and `rwx` on
the workspace only, and `qwen-27b-llama` is asserted to hold no reference to the
workspace at all, so the inference account cannot write it either.

### The workspace is deliberately not backed up

`<sharedRoot>/ai-workspace` sits on the data pool but **outside every Kopia
snapshot root**, and an assertion fails the build if a snapshot root ever comes
to cover it. That is intentional: it holds generated output, not your documents,
and it must not grow a backup policy by accident.

The consequence for you is real and worth stating plainly: **anything the model
writes there can be lost.** Move anything you want to keep out of the workspace
into the right library — see `documentation/content-placement.md` for which one
that is. The same warning is carried on the Homepage card for the app.

### Format limits worth knowing before you rely on this

- **ODF output goes through Collabora.** There is no native ODF writer in Rust
  or Python, so an `ods` or `odt` is produced by handing Collabora the native
  document and asking it to convert. That instance is shared with OpenCloud's
  editing sessions, so **conversion returns 503 while Collabora is busy**, and
  its concurrency budget is contended. A native `xlsx` or `docx` write does not
  touch Collabora at all.
- **An `ods` or `odt` read also goes through Collabora**, because the helper has
  no native ODF reader. The converted document is held in memory between the two
  steps and never written to the shared root, so a read leaves no temporary file.
- **Input ceiling**: 32 MiB per document, refused before the bytes are read.
  **Write ceiling**: 64 MiB. **Output ceiling**: 512 KiB of JSON from the helper.
  All three report the loss rather than truncating silently.
- **Spreadsheet ceilings**: 31 characters per sheet name (Excel's own limit), 256
  sheets, 2000 rows per sheet, and 64 cells per row. Rows, columns and sheets over a
  ceiling are clamped with the clamp **declared** in the response rather than
  dropped quietly.
- **A formula cell returns formula text, not its last calculated value.**

### Python, deliberately

Native `xlsx` and `docx` handling is the one documented exception to this
repository's Rust preference, and the reason is a library gap rather than a
choice: the `docx` crate has been unmaintained since 2020, so there is no Word
reader at all, and `docx-rs` only writes. `openpyxl` and `python-docx` are the
mature components for exactly these two formats. The reasoning sits at the head
of `custom_apps/rust/apps/ai-tools/helper-package.nix`.

The helper holds no grant of its own. It runs as part of `ai-tools`, as the same
account, inside the same sandbox, and receives only absolute paths the Rust side
has already validated. **Reads never hand it a path**: the document arrives as
bytes on stdin, so there is nothing for it to open and no path for a
prompt-injected call to redirect. Writes pass the validated path with the request
over stdin rather than on argv, so no path appears in a process listing, and the
child is spawned with `env_clear` so no `PYTHONPATH` from the parent reaches it.

### Verifying it

```bash
# the tool set and the confinement, evaluated rather than deployed
bash scripts/tests/test-ai-tools-module.sh
bash scripts/tests/test-qwen-ai-tools-mcp-bridge.sh

# the helper's own round-trip tests, on the pinned interpreter
bash scripts/tests/test-ai-tools-office-helper.sh

# the Rust path validation either side of the helper
cd custom_apps && cargo test -p ai-tools
```

After a deploy, confirm the tools are actually attached to the model and that
the endpoint answers through the gateway:

```bash
sudo systemctl status ai-tools.service qwen-27b-llama.service
curl --fail-with-body http://127.0.0.1:8097/ \
  --header 'content-type: application/json' \
  --header 'accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
```

A green deploy is not proof that the tools are wired: `ai-tools.service` refuses
any `Host` it was not configured with, so if `AI_TOOLS_PUBLIC_HOST` does not
match the published name every request through the gateway is a 403 with nothing
in the logs to explain it. The authenticated Homepage canary covers the route
(`modules/Core_Modules/homepage/canary.nix`); `tools.<domain>` is its target for
this app.

## Service Operations

When Bonsai and Qwen are both enabled, Qwen does not start at boot. Verify the
model artifacts, then start it for a background run:

```bash
sudo systemctl status qwen-27b-model-prepare.service
sudo systemctl start qwen-27b-llama.service
curl --fail http://127.0.0.1:8093/health
```

Starting Qwen stops `bonsai-llama.service`; stopping Qwen restarts it.

Text request:

```bash
curl --fail-with-body http://127.0.0.1:8093/v1/chat/completions \
  --header 'Content-Type: application/json' \
  --data '{
    "model": "qwen3.8-27b-q4_km",
    "messages": [
      {"role": "user", "content": "Summarise this title in three categories: Water bore inspection report"}
    ]
  }'
```

Disable the running services without deleting the persisted artifacts:

```nix
repo.qwen27b.enable = false;
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
systemctl show qwen-27b-llama.service --property=MemoryCurrent,MemoryHigh,MemoryMax
```

The ARC tuning service is attached to `multi-user.target`, since this host
has no `zfs-import-cache.service`. Its 50% ceiling must be visible in the
live module parameter after activation.