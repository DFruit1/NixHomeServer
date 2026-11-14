import assert from 'node:assert/strict';
import test from 'node:test';
import { evaluateSpace, formatBytes } from './storage.ts';

test('byte counts use binary units with one decimal below one hundred', () => {
  assert.equal(formatBytes(0), '0 B');
  assert.equal(formatBytes(512), '512 B');
  assert.equal(formatBytes(1536), '1.5 KB');
  assert.equal(formatBytes(12 * 1024 * 1024), '12.0 MB');
  assert.equal(formatBytes(300 * 1024 * 1024), '300 MB');
  assert.equal(formatBytes(1.5 * 1024 * 1024 * 1024), '1.5 GB');
});

test('small downloads are fine and uploads never trip the limit', () => {
  assert.equal(evaluateSpace({ freeBytes: 100e9, pendingBytes: 1_000, direction: 'server-to-phone' }), 'ok');
  assert.equal(evaluateSpace({ freeBytes: 1_000, pendingBytes: 9_999_999, direction: 'phone-to-server' }), 'ok');
  assert.equal(evaluateSpace({ freeBytes: 0, pendingBytes: 0, direction: 'server-to-phone' }), 'ok');
});

test('downloads block only above ninety-nine percent of free space', () => {
  const base = { freeBytes: 100e9, direction: 'server-to-phone' };
  assert.equal(evaluateSpace({ ...base, pendingBytes: 98e9 }), 'ok');
  assert.equal(evaluateSpace({ ...base, pendingBytes: 99e9 }), 'ok');
  assert.equal(evaluateSpace({ ...base, pendingBytes: 99.5e9 }), 'blocked');
});
