import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

test('the Tauri app icon decodes as 8-bit RGBA', () => {
  const png = readFileSync(new URL('../src-tauri/icons/icon.png', import.meta.url));
  assert.deepEqual(png.subarray(0, 8), Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  assert.equal(png.readUInt32BE(16), 512);
  assert.equal(png.readUInt32BE(20), 512);
  assert.equal(png[24], 8, '16-bit channels make Tauri abort during Android startup');
  assert.equal(png[25], 6, 'Tauri expects an RGBA icon');
});
