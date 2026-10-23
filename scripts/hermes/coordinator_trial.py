"""Owner-selected coordinator model trial, composed by the fleet release.

Python matches the existing Hermes YAML installer; no new backend or dependency.
Only the coordinator's model, Sol effort and duplicate fallback are changed.
"""
import copy

import yaml

from hermes_config import document


def configure(text):
    original = document(text)
    desired = copy.deepcopy(original)
    model = desired.setdefault('model', {})
    agent = desired.setdefault('agent', {})
    if not isinstance(model, dict) or not isinstance(agent, dict):
        raise ValueError('Expected coordinator model and agent mappings')
    overrides = agent.setdefault('reasoning_overrides', {})
    if not isinstance(overrides, dict):
        raise ValueError('Expected coordinator reasoning overrides mapping')
    model.update(default='gpt-6.1-sol', provider='openai-codex')
    overrides['gpt-6.1-sol'] = 'medium'
    # Keep the established OpenCode model available when Sol is unavailable.
    # Additional fallbacks retain their exact order and settings.
    chain = desired.get('fallback_providers', [])
    if not isinstance(chain, list) or any(not isinstance(x, dict) for x in chain):
        raise ValueError('Expected coordinator fallback list')
    desired['fallback_providers'] = [
        {'provider': 'custom:opencode-go', 'model': 'glm-5.3-flash'}
        if x == {'provider': 'openai-codex', 'model': 'gpt-6.1-sol'} else x
        for x in chain]
    nodes = {key.value: value for key, value in yaml.compose(text).value}
    edits = []
    for key in ('model', 'agent', 'fallback_providers'):
        if original.get(key) == desired[key]:
            continue
        rendered = yaml.safe_dump(desired[key], default_flow_style=True, width=100000).strip()
        node = nodes.get(key)
        if node is None:
            edits.append((len(text), len(text), '\n' + key + ': ' + rendered + '\n'))
        else:
            suffix = '\n' if isinstance(node, (yaml.MappingNode, yaml.SequenceNode)) and not node.flow_style else ''
            edits.append((node.start_mark.index, node.end_mark.index, rendered + suffix))
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    if document(text) != desired:
        raise ValueError('Coordinator trial would change unrelated settings')
    return text
