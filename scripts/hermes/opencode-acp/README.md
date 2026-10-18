# OpenCode ACP provider for Hermes

This provider runs the installed `opencode acp` client with its existing login.
It uses Hermes's existing ACP transport and requires no additional dependencies
or copied API keys. Python is required by Hermes's plugin interface.

Install from the NixHomeServer checkout:

```sh
python3 scripts/hermes/install-opencode-acp.py
python3 scripts/hermes/install-opencode-acp.py --check
```

The installer updates the default profile and existing named profiles, preserving
model defaults and other configuration. Prior plugin versions are archived in
`~/.hermes/backups/opencode-acp/`. Restart Hermes if its provider picker is cached.

Select provider `opencode-acp` in `hermes model`, then select a model advertised
by the CLI. ACP model IDs include the provider prefix, for example
`opencode/nemotron-3.5-super-vl-free`. For a single CLI request:

```sh
hermes chat --provider opencode-acp -m opencode/nemotron-3.5-super-vl-free \
  --query 'Reply with OK only.'
```

Model discovery and prompts go through OpenCode, which owns authentication and
service access. Model availability does not imply paid-model entitlement. Go
subscriptions, paid Console credit, and the free models are separate access
paths; a working free OpenCode model does not authorize paid GLM/DeepSeek calls.

This uses the actual OpenCode client through its supported ACP command, rather
than attaching to an existing chat. ACP sessions are separate OpenCode sessions.
Hermes's ACP bridge forwards its tool schemas as prompt text and parses returned
tool calls; this differs from direct API tool calling. The plugin requests plain
JSON function calls because Nemotron's OpenCode route consumes XML tool-call
delimiters without returning them as assistant text. User transcripts are
preserved. The existing ACP client
cancels native permission requests that have no interactive approval channel.

The provider resolves OpenCode on PATH, then checks the standard user pnpm,
OpenCode and local-bin locations, so desktop services with a reduced PATH can
still find it. An absent CLI is reported by Hermes's external-process resolver.

Rollback: select the prior provider, stop sessions using this provider, and
remove only `plugins/model-providers/opencode-acp/` from the affected profile(s).
Restore a prior plugin version from the content-addressed backup if needed.

References: [OpenCode ACP](https://docs.opencode.ai/docs/acp/),
[Console inference](https://dev.opencode.ai/v2/docs/console/api/inference/).
