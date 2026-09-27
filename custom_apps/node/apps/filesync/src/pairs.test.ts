import assert from 'node:assert/strict';
import test from 'node:test';
import { parseSavedPairs } from './pairs.ts';

test('a malformed saved pair cannot blank the startup screen', () => {
  assert.deepEqual(parseSavedPairs('[{"id":"broken"}]', 'https://sync.example'), []);
});

test('valid saved pairs survive alongside incomplete records', () => {
  const valid = {
    id: 'pair-1', name: 'Notes', local: { uri: 'content://notes', displayName: 'Notes' },
    serverPath: 'notes', direction: 'phone-to-server',
  };
  assert.deepEqual(parseSavedPairs(JSON.stringify([null, { id: 'broken' }, valid]), 'https://sync.example'), [
    { ...valid, server: 'https://sync.example' },
  ]);
  assert.deepEqual(parseSavedPairs('not json', ''), []);
});
