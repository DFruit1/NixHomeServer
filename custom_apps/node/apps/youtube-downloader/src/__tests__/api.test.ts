import { afterEach, describe, expect, it } from 'vitest';
import { apiFetch, resetApiTransport, resolveApiUrl, setApiTransport } from '../client/api.js';

afterEach(() => {
  resetApiTransport();
});

describe('resolveApiUrl', () => {
  it('keeps requests root-relative in the browser runtime', () => {
    expect(resolveApiUrl('/api/jobs', { tauri: false, baseUrl: 'https://example.test' })).toBe('/api/jobs');
  });

  it('prefixes the configured server origin in the tauri runtime', () => {
    expect(resolveApiUrl('/api/jobs', { tauri: true, baseUrl: 'https://ytdownload.example.test' })).toBe(
      'https://ytdownload.example.test/api/jobs',
    );
  });

  it('tolerates a trailing slash on the configured base URL', () => {
    expect(resolveApiUrl('/api/me', { tauri: true, baseUrl: 'https://ytdownload.example.test/' })).toBe(
      'https://ytdownload.example.test/api/me',
    );
  });

  it('normalises paths without a leading slash', () => {
    expect(resolveApiUrl('api/jobs', { tauri: true, baseUrl: 'http://127.0.0.1:8083' })).toBe(
      'http://127.0.0.1:8083/api/jobs',
    );
  });

  it('falls back to a relative URL when no base URL is configured', () => {
    expect(resolveApiUrl('/healthz', { tauri: true })).toBe('/healthz');
  });
});

describe('apiFetch', () => {
  it('delegates to the active transport with a resolved URL', async () => {
    const calls: Array<{ url: string; method?: string }> = [];
    setApiTransport(async (url, init) => {
      calls.push({ url, method: init?.method });
      return new Response(null, { status: 204 });
    });

    await apiFetch('/api/jobs', { method: 'POST' });

    expect(calls).toEqual([{ url: '/api/jobs', method: 'POST' }]);
  });
});
