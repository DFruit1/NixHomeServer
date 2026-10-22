#!/usr/bin/env python3
"""Render the supervisor's generated report through the existing daily delivery."""
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ.get('HERMES_ROOT', str(Path.home()/'.hermes')))
path = root/'state/fleet/report.json'
if not path.is_file() or path.is_symlink():
    print('Hermes fleet report unavailable; inspect the fleet supervisor execution.')
    sys.exit(1)
report = json.loads(path.read_text())
age = int(time.time()) - report['generated_at']
print('Hermes fleet: ' + ', '.join(report['boards']))
print('Generated '+str(max(0,age)//60)+' minutes ago.')
for name, state in sorted(report['handlers'].items()):
    if state.get('exit_code') or state.get('interrupted') or state.get('in_flight') or state.get('wake_error'):
        print(name+': needs technical recovery (exit '+str(state.get('exit_code','unknown'))+').')
    elif name.startswith(('board-health','idle-state')) and state.get('output','').strip():
        print(name+': '+state['output'].strip()[:2000])
if age > 900:
    print('Report is stale; inspect the supervisor before relying on it.')
    sys.exit(1)
