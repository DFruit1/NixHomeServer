import assert from 'node:assert/strict';
import test from 'node:test';
import { browseOrder, directoriesOnly, entryMeta, fileActionLabel, formatModified, joinPath, parentPath, type BrowseEntry } from './browse.ts';

function entry(overrides: Partial<BrowseEntry> & { name: string }): BrowseEntry {
  return { path: overrides.name, kind: 'file', size: 0, modifiedUnixMs: 0, ...overrides };
}

test('paths join and step up one level at a time', () => {
  assert.equal(joinPath('', 'Music'), 'Music');
  assert.equal(joinPath('Music', 'Albums'), 'Music/Albums');
  assert.equal(parentPath('Music/Albums/2019'), 'Music/Albums');
  assert.equal(parentPath('Music'), '');
  assert.equal(parentPath(''), '');
});

test('folders sort above files and unreadable kinds are hidden', () => {
  const ordered = browseOrder([
    entry({ name: 'notes.txt' }),
    entry({ name: 'pipe', kind: 'other' }),
    entry({ name: 'zulu' }),
    entry({ name: 'alpha', kind: 'directory' }),
    entry({ name: 'Beta', kind: 'directory' }),
  ]);
  assert.deepEqual(ordered.map((item) => item.name), ['alpha', 'Beta', 'notes.txt', 'zulu']);
  assert.deepEqual(directoriesOnly([
    entry({ name: 'notes.txt' }),
    entry({ name: 'alpha', kind: 'directory' }),
  ]).map((item) => item.name), ['alpha']);
});

test('file rows carry size and date, folders carry the date alone', () => {
  assert.equal(entryMeta(entry({ name: 'a', size: 1536, modifiedUnixMs: 0 })), '1.5 KB');
  const stamp = Date.UTC(2026, 2, 12);
  assert.equal(entryMeta(entry({ name: 'a', size: 1536, modifiedUnixMs: stamp })), '1.5 KB · 12 Mar 2026');
  assert.equal(entryMeta(entry({ name: 'dir', kind: 'directory', modifiedUnixMs: stamp })), '12 Mar 2026');
});

test('a missing or nonsensical timestamp renders as nothing', () => {
  assert.equal(formatModified(0), '');
  assert.equal(formatModified(-1), '');
  assert.equal(formatModified(Number.NaN), '');
});

test('action labels report progress while a file is in flight', () => {
  assert.equal(fileActionLabel('share', false), 'Share');
  assert.equal(fileActionLabel('download', false), 'Download');
  assert.equal(fileActionLabel('share', true), 'Sharing…');
  assert.equal(fileActionLabel('download', true), 'Downloading…');
});
