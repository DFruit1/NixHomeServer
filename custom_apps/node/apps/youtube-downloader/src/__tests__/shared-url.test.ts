import { describe, expect, it } from 'vitest';
import { normaliseSharedPromptUrl } from '../shared/url.js';

describe('normaliseSharedPromptUrl', () => {
  it('normalises a shared watch URL and strips tracking params', () => {
    expect(normaliseSharedPromptUrl('https://m.youtube.com/watch?v=abc123&feature=share&t=30')).toBe(
      'https://m.youtube.com/watch?v=abc123',
    );
  });

  it('keeps short links resolvable as shared', () => {
    expect(normaliseSharedPromptUrl('https://youtu.be/abc123?si=xyz')).toBe('https://youtu.be/abc123');
  });

  it('rejects a non-YouTube link', () => {
    expect(normaliseSharedPromptUrl('https://example.test/watch?v=abc123')).toBeUndefined();
  });

  it('rejects plain text', () => {
    expect(normaliseSharedPromptUrl('not a link')).toBeUndefined();
  });
});
