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

  it('prunes messages to the configured row ceiling', async () => {
    const db = new Database(path.join(tempDir, 'messages.sqlite'));
    await db.migrate();
    for (let index = 0; index < 4; index += 1) {
      await db.insertMessage({
        direction: 'inbound',
        topic: `sensor/${index}`,
        payloadText: String(index),
        source: 'mqtt',
      });
    }

    expect(await db.prune(90, 2)).toBe(2);
    expect(await db.summary()).toMatchObject({ messageCount: 2 });
    db.close();
  });

  it('drains retention backlogs larger than one 10,000-row batch', async () => {
    const db = new Database(path.join(tempDir, 'messages.sqlite'));
    await db.migrate();
    await db.exec(`
      with recursive sequence(value) as (
        select 1
        union all
        select value + 1 from sequence where value < 10025
      )
      insert into messages(created_at, direction, topic, retain, payload_text, payload_encoding, payload_bytes, source)
      select datetime('now'), 'inbound', 'sensor/backlog', 0, cast(value as text), 'utf8', 5, 'test'
      from sequence;
    `);

    expect(await db.prune(90, 10)).toBe(10015);
    expect(await db.summary()).toMatchObject({ messageCount: 10 });
    db.close();
  });

  it('iterates exports in stable order without building an in-memory result array', async () => {
    const db = new Database(path.join(tempDir, 'messages.sqlite'));
    await db.migrate();
    for (const topic of ['one', 'two', 'three']) {
      await db.insertMessage({ direction: 'inbound', topic, payloadText: topic, source: 'test' });
    }

    const iterator = db.iterateMessages();
    expect(iterator.next().value?.topic).toBe('one');
    expect([...iterator].map((message) => message.topic)).toEqual(['two', 'three']);
    db.close();
  });
});
