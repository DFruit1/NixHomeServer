"""Use the signed-in OpenCode CLI through Hermes's existing ACP transport.

Python is required by Hermes's provider plugin interface. No new dependencies,
credential export, HTTP proxy, or core patches are needed.
"""

import os
from pathlib import Path
import shutil

from providers import register_provider
from providers.base import ProviderProfile


def opencode_command():
    """Services may have a smaller PATH than the interactive desktop session."""
    if command := shutil.which('opencode'):
        return command
    for relative in ('.local/share/pnpm/bin/opencode', '.local/share/pnpm/opencode',
                     '.opencode/bin/opencode', '.local/bin/opencode'):
        candidate = Path.home() / relative
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return 'opencode'


class OpenCodeACPProfile(ProviderProfile):
    def create_client(self, **kwargs):
        from agent.copilot_acp_client import CopilotACPClient

        class OpenCodeACPClient(CopilotACPClient):
            def _run_prompt(self, prompt_text, *, timeout_seconds, model=None):
                # Nemotron's OpenCode route consumes XML tool delimiters before
                # ACP can return them as text. Hermes already parses plain JSON
                # function calls too. Change only our protocol instructions,
                # preserving the user's transcript verbatim.
                header, separator, transcript = prompt_text.partition('Conversation transcript:\n\n')
                header = header.replace('using <tool_call>{...}</tool_call> blocks',
                                        'as plain JSON objects')
                header = header.replace('<tool_call>{...}</tool_call>', 'a plain JSON object')
                header += ('\n\nWhen requesting a Hermes tool, emit one plain JSON object '
                           'with fields in this exact order: '
                           '{"id":"call_1","type":"function","function":'
                           '{"name":"tool_name","arguments":"JSON-encoded arguments"}}. '
                           'Use a unique id per call. Do not call OpenCode native tools '
                           'in place of the provided Hermes functions.\n\n')
                return super()._run_prompt(header + separator + transcript,
                                           timeout_seconds=timeout_seconds, model=model)

        kwargs.setdefault('command', self.process_command)
        kwargs.setdefault('args', list(self.process_args))
        return OpenCodeACPClient(**kwargs)

    def fetch_models(self, *, api_key=None, base_url=None, timeout=15.0):
        # session/new advertises the logged-in CLI's models; its own auth store
        # remains authoritative. The ACP client also handles permission requests.
        client = self.create_client()
        try:
            return client.list_models(timeout_seconds=timeout) or None
        except Exception:
            return None
        finally:
            client.close()


register_provider(OpenCodeACPProfile(
    name='opencode-acp',
    api_mode='chat_completions',
    env_vars=(),
    base_url='acp://opencode',
    auth_type='external_process',
    process_command=opencode_command(),
    process_args=('acp',),
))
