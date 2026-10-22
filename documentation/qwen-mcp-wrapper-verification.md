# Generated Qwen MCP wrapper — built-artefact verification

Revision verified: `02f5fef` (merge of `d9f603e` into `wt/t_34c52c70`).
The wrapper itself is unchanged by that merge; it is `d9f603e`'s derivation.

The `Verify:` clause on this card is the built `ExecStart` wrapper's argv, which
`t_bed911e9`'s harness deliberately does not assert: `ExecStart` records only the
generated wrapper's store path, so the flags can only be read off a built output.

## How the wrapper was obtained

`ExecStart` is a string with context, so `builtins.storePath` on the path is not
a legal request. The derivation has to be realised instead:

    nix eval --impure --raw --expr '
      let f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      in f.nixosConfigurations.server.config.systemd.services
           .qwen-27b-llama.serviceConfig.ExecStart'
    # => /nix/store/0hs7iq90nqrblwnnnrmrdbxw7l5n61ll-qwen-27b-llama-server/bin/qwen-27b-llama-server

    nix eval --impure --json --expr '... builtins.getContext s ...'
    # => {"/nix/store/p8yv25cyl7vlrndpaqxbnkrqmx21s1w9-qwen-27b-llama-server.drv":{"outputs":["out"]}}

    nix build --impure --no-link --print-out-paths \
      '/nix/store/p8yv25cyl7vlrndpaqxbnkrqmx21s1w9-qwen-27b-llama-server.drv^*'
    # => /nix/store/0hs7iq90nqrblwnnnrmrdbxw7l5n61ll-qwen-27b-llama-server

Built on the configured remote builder (`ssh-ng://server`).

## The generated argv (both apps enabled)

    --mcp-servers-config /nix/store/vy34p9zlm84ra6bfjw621pa0bgh27364-qwen-27b-mcp-servers.json
    --cors-origins localhost

Full argv, for the record:

    --ui
    --path /nix/store/jq3q0i9ndf2h2lrig2nhswb7c0afcsd4-webui-6fcaa16f4b360649933a54d1f91ad40ed35c0e11
    --model /mnt/data/qwen-27b/models/Swift-1.5-Qwen3.8-27B-Q4_K_M.gguf
    --mmproj /mnt/data/qwen-27b/models/mmproj-Swift-1.5-Qwen3.8-27B-F16.gguf
    --no-mmproj-offload
    --alias qwen3.8-27b-q4_km
    --host 127.0.0.1
    --port 8093
    --ctx-size "$context_size"          # resolved to 131072
    --parallel 1
    --n-gpu-layers all
    --flash-attn on
    --jinja
    --mcp-servers-config /nix/store/vy34...-qwen-27b-mcp-servers.json
    --cors-origins localhost
    --temp 1.000000
    --top-p 0.950000
    --top-k 20
    --min-p 0
    --repeat-penalty 1.000000
    --image-max-tokens 1024
    --video-fps 2.000000
    --cache-type-k q8_0 --cache-type-v q8_0
    --batch-size 2048 --ubatch-size 2048 --threads 8 --threads-batch 8

## The generated MCP config file, read off disk

`/nix/store/vy34p9zlm84ra6bfjw621pa0bgh27364-qwen-27b-mcp-servers.json`:

    {
      "mcpServers": {
        "ai_tools": {
          "args": [],
          "command": "/nix/store/qxnl69fv9vlp1pcprwbbzpsyz7l6xmh2-ai-tools-0.1.0/bin/ai-tools",
          "env": {
            "AI_TOOLS_BRIDGE_CALL_TIMEOUT_SECS": "120",
            "AI_TOOLS_BRIDGE_CONNECT_TIMEOUT_SECS": "10",
            "AI_TOOLS_BRIDGE_UPSTREAM_URL": "http://127.0.0.1:8097/",
            "AI_TOOLS_TRANSPORT": "stdio"
          },
          "timeout_ms": 120000
        }
      }
    }

Loopback port 8097, stdio transport, one declared child, `ai_tools` prefix.

## The ai-tools-disabled wrapper

Rebuilt with `repo.aiTools.enable = lib.mkForce false`:

    /nix/store/fkqgc72vhkfzcm7c05v1nf555qmk8yj4-qwen-27b-llama-server

    $ grep -E 'mcp|cors-origins' .../bin/qwen-27b-llama-server
    47:  --cors-origins localhost \

`--mcp-servers-config` is gone entirely, and the explicit `--cors-origins
localhost` survives. Turning the integration off cannot reintroduce the
upstream `*` default.

## Live stdio handshake against the built bridge binary

This is the residual risk `t_bed911e9` recorded: that the bridge's stdio
framing is the one the pinned llama.cpp build actually drives. Verified by
running the *built* `ai-tools` binary as the child llama-server would spawn,
against the *built* `ai-tools-server` started on loopback 8097.

Upstream reachability confirmed independently first:

    $ curl -s -X POST http://127.0.0.1:8097/ \
        -H 'Content-Type: application/json' \
        -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize",...}'
    http=200
    data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",...}}

`initialize` negotiates 2024-11-05, the revision the module documents as a hard
requirement, and `tools/list` answers with the prefixed tool surface:

    ai_tools_web_search        (query, max_results, categories, language)
    ai_tools_convert_document  (path)

`tools/call` behaviour, identical under llama.cpp's bare framing and under
per-request `_meta`:

    ai_tools_exec_shell_command  -> refused, "unknown tool: exec_shell_command"
    ai_tools_convert_document    -> refused, "path must not contain parent or
                                    root components"
    ai_tools_web_search          -> forwarded; upstream answered
                                    "SearXNG returned HTTP 404" because no
                                    SearXNG was running in this scratch context

Both refusals are the intended behaviour: a name outside the published prefix is
not forwarded, and traversal is rejected upstream of the bridge. The third
confirms the call genuinely reaches ai-tools on loopback rather than being
answered locally.

Note: a first probe reported `-32602 request _meta is missing` on `tools/call`.
That was the probe's own framing bug (an unparsable params object), not a bridge
defect — the corrected probe returns identical results in both framings.

## Filesystem grants

* inference unit: `ReadOnlyPaths = [ /mnt/data/qwen-27b ]`, no
  `ReadWritePaths`, `ProtectSystem = "strict"` — no inference-side filesystem
  grant beyond the model directory.
* `ai-tools.service`: `ReadOnlyPaths = [ /mnt/data/shared ]`, `ProtectSystem =
  "strict"`, no `ReadWritePaths` — it owns the shared root, read-only.
* No browser/playwright MCP server is declared anywhere in `modules/`.

## Wildcard CORS is refused by evaluation, not only by test

    $ nix eval --impure --json --expr '... repo.qwen27b.corsOrigins = lib.mkForce "*" ...'
    error:
       Failed assertions:
       - repo.qwen27b.corsOrigins must not be '*'; the inference API is unauthenticated.

## Gates

| Gate | Result |
|---|---|
| `bash scripts/tests/test-qwen-ai-tools-mcp-bridge.sh` | exit 0 |
| `bash scripts/tests/test-ai-tools-module.sh` | exit 0 |
| `cargo test -p ai-tools` | exit 0, 32 passed |
| `scripts/validate-repo.sh` (lean) | exit 1 — sole failure `test-kanban-retry-breaker.sh` |

The lean failure is the worker-fence fixture, not this change. That file is
untouched here (last commit `5feedc7`) and fails identically on the untouched
base:

    $ bash scripts/tests/test-kanban-retry-breaker.sh
    kanban: delegate_task child contexts cannot mutate Kanban tasks via the CLI
    exit 1

    $ env -u HERMES_DELEGATED_CHILD_CONTEXT bash scripts/tests/test-kanban-retry-breaker.sh
    ✅ reports clear on a healthy board
    ✅ reports a missing board instead of failing
    ✅ refuses loudly when the hermes CLI is unavailable
    ▶ kanban retry breaker: all checks passed
    exit 0

Its repair is `339f3fa` on `wt/t_4b0f6c29`, which this card was not told to
import.