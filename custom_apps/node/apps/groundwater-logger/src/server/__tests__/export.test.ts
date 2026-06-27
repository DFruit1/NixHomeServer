import { describe, expect, it } from 'vitest';
import { messagesToCsv, messagesToJsonl } from '../export.js';
import type { MqttMessage } from '../../shared/types.js';

const message: MqttMessage = {
  id: 1,
  createdAt: '2026-06-27 10:00:00',
  direction: 'inbound',
  topic: 'azman1/feeds/gps-data',
  qos: 1,
  retain: false,
  payloadText: '{"note":"quoted \\" value"}',
  payloadJson: { note: 'quoted " value' },
  payloadEncoding: 'utf8',
  payloadBytes: 27,
  source: 'mqtt',
};

describe('message exports', () => {
  it('escapes CSV values', () => {
    const csv = messagesToCsv([message]);
    expect(csv).toContain('"payload_text"');
    expect(csv).toContain('"{""note"":""quoted \\"" value""}"');
  });

  it('writes JSONL rows', () => {
    const jsonl = messagesToJsonl([message]);
    expect(jsonl.trim().split('\n')).toHaveLength(1);
    expect(JSON.parse(jsonl).topic).toBe('azman1/feeds/gps-data');
  });
});
