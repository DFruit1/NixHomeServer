import assert from 'node:assert/strict';
import test from 'node:test';
import { clampPercent, evaluateSpace, formatBytes, storageBudget } from './storage.ts';

test('byte counts use binary units with one decimal below one hundred', () => {
  assert.equal(formatBytes(0), '0 B');
  assert.equal(formatBytes(512), '512 B');
  assert.equal(formatBytes(1536), '1.5 KB');
  assert.equal(formatBytes(12 * 1024 * 1024), '12.0 MB');
  assert.equal(formatBytes(300 * 1024 * 1024), '300 MB');
  assert.equal(formatBytes(1.5 * 1024 * 1024 * 1024), '1.5 GB');
});

test('the spendable budget keeps fifteen percent of total storage free', () => {
  assert.equal(storageBudget(10_000, 100_000), 0);
  assert.equal(storageBudget(50_000, 100_000), 35_000);
});

test('small downloads are fine and uploads never trip the cap', () => {
  const base = { freeBytes: 100e9, totalBytes: 100e9, warnFraction: 0.8, blockFraction: 0.95 };
  assert.equal(evaluateSpace({ ...base, pendingBytes: 1_000, direction: 'server-to-phone' }).status, 'ok');
  assert.equal(evaluateSpace({ ...base, pendingBytes: 9_999_999, direction: 'phone-to-server' }).status, 'ok');
  assert.equal(evaluateSpace({ ...base, pendingBytes: 0, direction: 'server-to-phone' }).status, 'ok');
});

test('downloads warn at eighty and block at ninety-five percent of budget', () => {
  // Budget is zero here (10k free of 100k total), so any download blocks.
  const tight = { freeBytes: 10_000, totalBytes: 100_000, warnFraction: 0.8, blockFraction: 0.95, direction: 'server-to-phone' };
  assert.equal(evaluateSpace({ ...tight, pendingBytes: 1 }).status, 'blocked');
  // Roomy device: budget is 85 GB; warn above 68 GB, block above 80.75 GB.
  const roomy = { freeBytes: 100e9, totalBytes: 100e9, warnFraction: 0.8, blockFraction: 0.95, direction: 'server-to-phone' };
  assert.equal(evaluateSpace({ ...roomy, pendingBytes: 10e9 }).status, 'ok');
  assert.equal(evaluateSpace({ ...roomy, pendingBytes: 70e9 }).status, 'warn');
  assert.equal(evaluateSpace({ ...roomy, pendingBytes: 90e9 }).status, 'blocked');
});

test('limit percents clamp into a sane range with a fallback', () => {
  assert.equal(clampPercent('80', 80), 80);
  assert.equal(clampPercent(0, 80), 1);
  assert.equal(clampPercent(250, 95), 100);
  assert.equal(clampPercent('nope', 95), 95);
  assert.equal(clampPercent(undefined, 80), 80);
});
