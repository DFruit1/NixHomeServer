#!/usr/bin/env python3
"""Render the supervisor's generated report through the existing daily delivery."""
import json
import os
from pathlib import Path
import sys
import time

from agent_usage_report import render_summary

root = Path(os.environ.get('HERMES_ROOT', str(Path.home()/'.hermes')))
path = root/'state/fleet/report.json'
if not path.is_file() or path.is_symlink():
    print('Hermes fleet report unavailable; inspect the fleet supervisor execution.')
    sys.exit(1)
report = json.loads(path.read_text())
age = int(time.time()) - report['generated_at']
print('Hermes fleet: ' + ', '.join(report['boards']))
print('Generated '+str(max(0,age)//60)+' minutes ago.')
outcomes=report.get('outcomes',{})
if outcomes.get('status')=='observed':
    print('Outcome window ended '+time.strftime('%Y-%m-%d %H:%M UTC',time.gmtime(outcomes['generated_at']))+'.')
    for board,values in sorted(outcomes.get('boards',{}).items()):
        if values.get('status')!='observed':
            print(board+': outcome measurements unavailable.');continue
        print(board+': '+str(values['recorded_scope_deliveries'])+' recorded scope deliveries; '
              +str(values['unfinished_feature_trackers'])+' unfinished feature trackers; '
              +str(values['repeat_blocked_tasks'])+' repeatedly blocked tasks in the measured day.')
        print('Maintenance: '+str(values['maintenance_completed_runs'])+' completed runs, '
              +str(round(values['maintenance_elapsed_seconds']/60))+' summed worker minutes, including waits. Billing unknown.')
else:
    print('Outcome measurements unavailable; no productivity conclusion can be drawn.')
print('\n'.join(render_summary(root)))
for name, state in sorted(report['handlers'].items()):
    if state.get('exit_code') or state.get('interrupted') or state.get('in_flight') or state.get('wake_error'):
        print(name+': needs technical recovery (exit '+str(state.get('exit_code','unknown'))+').')
    elif name.startswith(('board-health','idle-state')) and state.get('output','').strip():
        print(name+': '+state['output'].strip()[:2000])
if age > 900:
    print('Report is stale; inspect the supervisor before relying on it.')
    sys.exit(1)
