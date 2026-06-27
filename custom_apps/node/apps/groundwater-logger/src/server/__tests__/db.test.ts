import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { Database } from '../db.js';

let tempDir = '';

beforeEach(async () => {
  tempDir = await mkdtemp(path.join(os.tmpdir(), 'groundwater-logger-test-'));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe('Database', () => {
  it('migrates, inserts, filters, and summarizes MQTT messages', async () => {
    const db = new Database(path.join(tempDir, 'messages.sqlite'));
    await db.migrate();
    const id = await db.insertMessage({
      direction: 'inbound',
      topic: 'azman1/feeds/gps-data',
      payloadText: '{"lat":1}',
      payloadJson: { lat: 1 },
      qos: 1,
      source: 'mqtt',
    });

    expect(id).toBeGreaterThan(0);
    const messages = await db.listMessages({ topic: 'azman1/feeds/gps-data' });
    expect(messages).toHaveLength(1);
    expect(messages[0].payloadJson).toEqual({ lat: 1 });
    expect(await db.observedTopics()).toEqual(['azman1/feeds/gps-data']);
    expect(await db.summary()).toMatchObject({ messageCount: 1 });
  });
});
