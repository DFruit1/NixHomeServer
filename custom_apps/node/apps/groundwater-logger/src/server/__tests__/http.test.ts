import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { describe, expect, it } from 'vitest';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { MqttMessage } from '../../shared/types.js';
import type { AppConfig } from '../config.js';
import type { Database } from '../db.js';
import { handleApiRequest, type ServerContext } from '../http.js';
import type { MqttBridge } from '../mqttBridge.js';

const config: AppConfig = {
  host: '127.0.0.1',
  port: 8091,
  stateDir: '/tmp',
  databasePath: '/tmp/messages.sqlite',
  staticDir: '/tmp',
  mqttUrl: 'mqtt://127.0.0.1:1883',
  mqttUsername: 'test',
  mqttPassword: 'test',
  mqttSubscribeTopics: [],
  mqttDefaultQos: 1,
  retentionDays: 90,
  maximumMessages: 1000,
};

const message: MqttMessage = {
  id: 1,
  createdAt: '2026-07-19 00:00:00',
  direction: 'inbound',
  topic: 'test/topic',
  qos: 1,
  retain: false,
  payloadText: 'value',
  payloadEncoding: 'utf8',
  payloadBytes: 5,
  source: 'mqtt',
};

describe('groundwater HTTP safety', () => {
  it('rejects a command from a sibling origin before publishing', async () => {
    let published = false;
    const context = fakeContext({
      publish: async () => {
        published = true;
        return message;
      },
    });
    const response = new TestResponse();

    await handleApiRequest(
      context,
      makeRequest('POST', '/api/publish', '{}', {
        host: 'groundwater.example.test',
        origin: 'https://homepage.example.test',
        'content-type': 'application/json',
      }),
      response as unknown as ServerResponse,
    );

    expect(response.statusCode).toBe(403);
    expect(published).toBe(false);
  });

  it('requires JSON and bounds command bodies', async () => {
    const context = fakeContext();
    const wrongType = new TestResponse();
    await handleApiRequest(
      context,
      makeRequest('POST', '/api/publish', '{}', {
        host: 'groundwater.example.test',
        origin: 'https://groundwater.example.test',
        'content-type': 'text/plain',
      }),
      wrongType as unknown as ServerResponse,
    );
    expect(wrongType.statusCode).toBe(415);

    const oversized = new TestResponse();
    await handleApiRequest(
      context,
      makeRequest('POST', '/api/publish', JSON.stringify({ payload: 'x'.repeat(70 * 1024) }), {
        host: 'groundwater.example.test',
        origin: 'https://groundwater.example.test',
        'content-type': 'application/json',
      }),
      oversized as unknown as ServerResponse,
    );
    expect(oversized.statusCode).toBe(413);
  });

  it('requires an Origin and rejects contradictory fetch metadata', async () => {
    const context = fakeContext();
    for (const headers of [
      { host: 'groundwater.example.test', 'content-type': 'application/json' },
      {
        host: 'groundwater.example.test',
        origin: 'https://groundwater.example.test',
        'content-type': 'application/json',
        'sec-fetch-site': 'cross-site',
      },
    ]) {
      const response = new TestResponse();
      await handleApiRequest(
        context,
        makeRequest('POST', '/api/publish', '{}', headers),
        response as unknown as ServerResponse,
      );
      expect(response.statusCode).toBe(403);
    }
  });

  it('accepts a valid JSON command below the documented body limit', async () => {
    let published = false;
    const context = fakeContext({
      publish: async () => {
        published = true;
        return message;
      },
    });
    const response = new TestResponse();

    await handleApiRequest(
      context,
      makeRequest('POST', '/api/publish', JSON.stringify({
        topic: 'test/topic',
        payload: 'x'.repeat(60 * 1024),
      }), {
        host: 'groundwater.example.test',
        origin: 'https://groundwater.example.test',
        'content-type': 'application/json',
      }),
      response as unknown as ServerResponse,
    );

    expect(response.statusCode).toBe(201);
    expect(published).toBe(true);
  });

  it('rejects non-object JSON without invoking the publish helper', async () => {
    let published = false;
    const context = fakeContext({
      publish: async () => {
        published = true;
        return message;
      },
    });
    const response = new TestResponse();

    await handleApiRequest(
      context,
      makeRequest('POST', '/api/publish', 'null', {
        host: 'groundwater.example.test',
        origin: 'https://groundwater.example.test',
        'content-type': 'application/json',
      }),
      response as unknown as ServerResponse,
    );

    expect(response.statusCode).toBe(400);
    expect(published).toBe(false);
  });

  it('closes the database iterator promptly when an export client disconnects under backpressure', async () => {
    let iteratorClosed = false;
    const context = fakeContext(undefined, function* () {
      try {
        yield message;
        yield { ...message, id: 2 };
      } finally {
        iteratorClosed = true;
      }
    });
    const response = new TestResponse((writeNumber) => {
      if (writeNumber === 2) {
        queueMicrotask(() => {
          response.destroyed = true;
          response.emit('close');
        });
        return false;
      }
      return true;
    });

    await expect(
      handleApiRequest(
        context,
        makeRequest('GET', '/api/messages/export?format=csv', ''),
        response as unknown as ServerResponse,
      ),
    ).resolves.toBe(true);

    expect(iteratorClosed).toBe(true);
    expect(response.ended).toBe(false);
    expect(response.writeCount).toBe(2);
  });
});

const fakeContext = (
  mqttOverrides: Partial<MqttBridge> = {},
  iterateMessages: () => IterableIterator<MqttMessage> = function* () {},
): ServerContext => ({
  config,
  db: { iterateMessages } as unknown as Database,
  mqttBridge: mqttOverrides as MqttBridge,
});

const makeRequest = (
  method: string,
  url: string,
  body: string,
  headers: IncomingMessage['headers'] = { host: 'groundwater.example.test' },
): IncomingMessage => {
  const request = Readable.from(body ? [body] : []) as IncomingMessage;
  request.method = method;
  request.url = url;
  request.headers = headers;
  return request;
};

class TestResponse extends EventEmitter {
  statusCode = 200;
  destroyed = false;
  writableEnded = false;
  ended = false;
  writeCount = 0;
  body = '';

  constructor(private readonly writeResult: (writeNumber: number) => boolean = () => true) {
    super();
  }

  setHeader(): void {}

  write(chunk: string): boolean {
    this.writeCount += 1;
    this.body += chunk;
    return this.writeResult(this.writeCount);
  }

  end(chunk?: string): void {
    if (chunk) this.body += chunk;
    this.ended = true;
    this.writableEnded = true;
  }
}
