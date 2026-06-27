import { describe, expect, it } from 'vitest';
import { payloadHasDangerousCommand, validatePublishRequest, validatePublishTopic } from '../presets.js';

describe('publish validation', () => {
  it('rejects wildcard publish topics', () => {
    expect(() => validatePublishTopic('cmd/#')).toThrow(/wildcards/);
    expect(() => validatePublishTopic('cfg/+/desired')).toThrow(/wildcards/);
  });

  it('validates JSON payloads', () => {
    expect(() =>
      validatePublishRequest({
        topic: 'cfg/desired',
        payloadMode: 'json',
        payload: '{"Flush_sd":',
      }),
    ).toThrow(/valid JSON/);
  });

  it('requires explicit confirmation for dangerous command values', () => {
    expect(() =>
      validatePublishRequest({
        topic: 'cmd/danger',
        payloadMode: 'json',
        payload: '{"Wipe_sd":"1"}',
      }),
    ).toThrow(/DANGER/);
  });

  it('accepts dangerous commands only with the DANGER confirmation', () => {
    const request = validatePublishRequest({
      topic: 'cmd/danger',
      payloadMode: 'json',
      payload: '{"Wipe_sd":"1"}',
      confirm: 'DANGER',
    });

    expect(request.topic).toBe('cmd/danger');
    expect(request.payload).toBe('{"Wipe_sd":"1"}');
  });

  it('detects dangerous command keys case-insensitively', () => {
    expect(payloadHasDangerousCommand({ Reboot: '1' })).toBe(true);
    expect(payloadHasDangerousCommand({ Reboot: '0' })).toBe(false);
  });
});
