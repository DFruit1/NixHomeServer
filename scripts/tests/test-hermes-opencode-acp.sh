#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

source = Path(sys.argv[1]) / 'scripts/hermes'
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('installer', source / 'install-opencode-acp.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class OpenCodeACPTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hermes-opencode-acp-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_install_is_scoped_idempotent_and_backs_up_changed_plugin(self):
        for home in [self.root, self.root / 'profiles/head-coordinator']:
            home.mkdir(parents=True, exist_ok=True)
            (home / 'config.yaml').write_text('model: {provider: openai-codex}\n')
        absent = self.root / 'profiles/deleted'
        absent.mkdir()
        before = (self.root / 'config.yaml').read_bytes()
        self.assertFalse(installer.install(self.root, check=True))
        self.assertFalse((self.root / 'plugins').exists())
        self.assertTrue(installer.install(self.root))
        self.assertTrue(installer.install(self.root, check=True))
        self.assertFalse((absent / 'plugins').exists())
        self.assertEqual(before, (self.root / 'config.yaml').read_bytes())
        plugin = self.root / 'plugins/model-providers/opencode-acp/__init__.py'
        plugin.write_text('# old plugin\n')
        self.assertFalse(installer.install(self.root, check=True))
        self.assertTrue(installer.install(self.root))
        self.assertTrue(any(p.read_text() == '# old plugin\n'
                            for p in (self.root / 'backups/opencode-acp').glob('*/*')))

    def test_provider_reuses_acp_without_reading_or_exporting_credentials(self):
        class Profile:
            def __init__(self, **kwargs):
                self.__dict__.update(kwargs)

        class Client:
            def __init__(self, **kwargs):
                self.kwargs = kwargs

            def list_models(self, **kwargs):
                return ['opencode/nemotron-3.5-super-vl-free']

            def close(self):
                self.closed = True

            def _run_prompt(self, prompt_text, **kwargs):
                self.prompt_text = prompt_text
                return 'response', ''

        registered = []
        providers = types.ModuleType('providers')
        providers.register_provider = registered.append
        base = types.ModuleType('providers.base')
        base.ProviderProfile = Profile
        client_module = types.ModuleType('agent.copilot_acp_client')
        client_module.CopilotACPClient = Client
        # Service PATH omits pnpm, but the user's installed executable is present.
        binary = self.root / '.local/share/pnpm/bin/opencode'
        binary.parent.mkdir(parents=True)
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o700)
        modules = {'providers': providers, 'providers.base': base,
                   'agent.copilot_acp_client': client_module}
        spec = importlib.util.spec_from_file_location('opencode_test', source / 'opencode-acp/__init__.py')
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules), patch('shutil.which', return_value=None), patch.object(Path, 'home', return_value=self.root):
            spec.loader.exec_module(module)
            profile = registered[0]
            self.assertEqual('opencode-acp', profile.name)
            self.assertEqual('external_process', profile.auth_type)
            self.assertEqual(str(binary), profile.process_command)
            self.assertEqual(('acp',), profile.process_args)
            self.assertEqual((), profile.env_vars)
            client = profile.create_client(timeout=30)
            self.assertEqual(str(binary), client.kwargs['command'])
            self.assertEqual(['acp'], client.kwargs['args'])
            client._run_prompt('Emit <tool_call>{...}</tool_call>\n\n'
                               'Conversation transcript:\n\nUser: literal <tool_call>',
                               timeout_seconds=30, model='opencode/test')
            header, _, transcript = client.prompt_text.partition('Conversation transcript:\n\n')
            self.assertNotIn('<tool_call>', header)
            self.assertIn('"id"', header)
            self.assertEqual('User: literal <tool_call>', transcript)
            self.assertEqual(['opencode/nemotron-3.5-super-vl-free'], profile.fetch_models())
            with patch.object(Client, 'list_models', side_effect=RuntimeError('offline')):
                self.assertIsNone(profile.fetch_models())


unittest.main(argv=[sys.argv[0]])
PY
