import { EventEmitter } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { Database } from '../db.js';
import { MqttBridge, type MqttPublisher } from '../mqttBridge.js';

class FakeMqttClient extends EventEmitter implements MqttPublisher {
  published: Array<{ topic: string; payload: string }> = [];

  async publish(topic: string, payload: string): Promise<void> {
    this.published.push({ topic, payload });
  }

  end(): void {}

  subscribe(_topics: string[], _options: { qos: 0 | 1 | 2 }, callback: (error?: Error) => void): void {
    callback();
  }
}

let tempDir = '';

beforeEach(async () => {
  tempDir = await mkdtemp(path.join(os.tmpdir(), 'groundwater-logger-bridge-test-'));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

const config = (databasePath: string): AppConfig => ({
  host: '127.0.0.1',
  port: 8091,
  stateDir: path.dirname(databasePath),
  databasePath,
  staticDir: 'dist/client',
  mqttUrl: 'mqtt://127.0.0.1:1883',
  mqttUsername: 'groundwater-app',
  mqttPassword: 'secret',
  mqttSubscribeTopics: ['azman1/feeds/#', 'cmd/#', 'cfg/#'],
  mqttDefaultQos: 1,
});

describe('MqttBridge', () => {
  it('publishes and records outbound messages', async () => {
    const db = new Database(path.join(tempDir, 'messages.sqlite'));
    await db.migrate();
    const fake = new FakeMqttClient();
    const bridge = new MqttBridge(config(path.join(tempDir, 'messages.sqlite')), db, () => fake);
    bridge.start();
    fake.emit('connect');

    const message = await bridge.publish({
      topic: 'cfg/desired',
      payloadMode: 'json',
      payload: '{"Disable_Logging":"0"}',
    });

    expect(fake.published).toEqual([{ topic: 'cfg/desired', payload: '{"Disable_Logging":"0"}' }]);
    expect(message.direction).toBe('outbound');
    expect((await db.listMessages())[0].topic).toBe('cfg/desired');
  });
});
