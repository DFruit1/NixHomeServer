#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import yaml

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
import hermes_config as config


class ConfigTest(unittest.TestCase):
    def test_platform_lists_support_both_styles_and_preserve_other_settings(self):
        for selection in ('[file, terminal]', '\n    - file\n    - terminal'):
            original = ('model: {default: unchanged}\nplatform_toolsets:\n'
                        f'  cli: {selection}\n  desktop: {selection}\n'
                        '  simplex: [memory]\nkanban: {max_in_progress: 3}\n')
            updated = config.platform_tools(original, 'desktop', add=('kanban',))
            before, after = yaml.safe_load(original), yaml.safe_load(updated)
            before['platform_toolsets']['desktop'].append('kanban')
            self.assertEqual(before, after)
            self.assertEqual(updated, config.platform_tools(updated, 'desktop', add=('kanban',)))
        with self.assertRaises(ValueError):
            config.platform_tools('platform_toolsets: {desktop: terminal}\n', 'desktop', add=('kanban',))
        self.assertEqual('model: x\n', config.platform_tools('model: x\n', 'desktop', optional=True))

    def test_compaction_preserves_values_multiline_strings_and_managed_markers(self):
        original = ('# Copied reference documentation\nmodel: ${MODEL}\n\n'
                    '# Operator note: keep this annotation.\n'
                    'prompt: |+\n  # This is prompt text.\n\n  Keep it.\n\n'
                    'quoted: "first\n\n  # Still inside a string\n  last"\n'
                    'hooks:\n  pre_tool_call:\n'
                    '    # nixhomeserver-guard:start\n'
                    '    - command: "echo keep" # local note\n'
                    '    # nixhomeserver-guard:end\n')
        reference = '# Copied reference documentation\n# nixhomeserver-guard:start\n'
        updated = config.compact(original, reference)
        self.assertEqual(yaml.safe_load(original), yaml.safe_load(updated))
        self.assertNotIn('Copied reference documentation', updated)
        for kept in ('  # This is prompt text.\n\n', '# Still inside a string',
                     '# nixhomeserver-guard:start', '# nixhomeserver-guard:end', '# local note',
                     '# Operator note: keep this annotation.'):
            self.assertIn(kept, updated)
        self.assertEqual(updated, config.compact(updated, reference))

    def test_rejects_ambiguous_or_unsupported_yaml_without_exposing_values(self):
        for text in ('model: private-value\nmodel: other\n', 'model: [private-value\n',
                     'model: x\n---\nmodel: y\n', 'base: &x {a: 1}\ncopy: *x\n'):
            with self.assertRaises(ValueError) as error:
                config.compact(text, '# docs\n')
            self.assertNotIn('private-value', str(error.exception))

    def test_check_backup_permissions_and_all_files_preflight(self):
        with tempfile.TemporaryDirectory(prefix='nixhomeserver-hermes-config-') as directory:
            root = Path(directory)
            example = root / 'hermes-agent/cli-config.yaml.example'
            example.parent.mkdir()
            example.write_text('# docs\n')
            path = root / 'config.yaml'
            original = '# docs\nmodel: ${MODEL}\n'
            path.write_text(original)
            path.chmod(0o640)
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(1, config.install(root, check=True))
                self.assertEqual(original, path.read_text())
                self.assertFalse((root / 'backups').exists())
                bad = root / 'profiles/bad/config.yaml'
                bad.parent.mkdir(parents=True)
                bad.write_text('model: [broken\n')
                with self.assertRaises(ValueError):
                    config.install(root)
                self.assertEqual(original, path.read_text())
                bad.write_text('model: okay\n')
                self.assertEqual(0, config.install(root))
                self.assertEqual(0o640, path.stat().st_mode & 0o777)
                copies = list((root / 'backups/config-compaction').glob('*/*'))
                self.assertEqual(1, len(copies))
                self.assertEqual(original, copies[0].read_text())
                self.assertEqual(0o600, copies[0].stat().st_mode & 0o777)
                self.assertEqual(0, config.install(root, check=True))
            self.assertNotIn('${MODEL}', output.getvalue())

    def test_symlinks_and_concurrent_edits_are_not_overwritten(self):
        with tempfile.TemporaryDirectory(prefix='nixhomeserver-hermes-config-') as directory:
            root = Path(directory)
            example = root / 'hermes-agent/cli-config.yaml.example'
            example.parent.mkdir()
            example.write_text('# docs\n')
            target = root / 'original.yaml'
            target.write_text('# docs\nmodel: first\n')
            path = root / 'config.yaml'
            path.symlink_to(target)
            with self.assertRaises(ValueError):
                config.install(root)
            self.assertEqual('# docs\nmodel: first\n', target.read_text())
            path.unlink()
            path.write_text(target.read_text())
            second = root / 'profiles/second/config.yaml'
            second.parent.mkdir(parents=True)
            second.write_text('# docs\nmodel: second\n')
            real_compact = config.compact

            def concurrent_edit(text, reference):
                if 'second' in text:
                    path.write_text('model: external-change\n')
                return real_compact(text, reference)

            with patch.object(config, 'compact', concurrent_edit), contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(ValueError):
                    config.install(root)
            self.assertEqual('model: external-change\n', path.read_text())
            self.assertEqual('# docs\nmodel: second\n', second.read_text())


unittest.main(argv=['config-policy'], verbosity=2)
PY
