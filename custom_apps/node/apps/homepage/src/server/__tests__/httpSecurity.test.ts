import { tmpdir } from 'node:os';
import { Readable } from 'node:stream';
import { describe, expect, it } from 'vitest';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { AppConfig } from '../config.js';
import { handleApiRequest } from '../http.js';

const config: AppConfig = {
  host: '127.0.0.1',
  port: 8084,
  staticDir: tmpdir(),
  sudoPath: '/bin/false',
  canaryAdminUser: 'admin',
  canaryStateDir: tmpdir(),
  canaryTriggerCommand: '/bin/false',
  homepage: {
    brandName: 'Test Home',
    domain: 'example.test',
    services: [],
    folderGuides: [],
    adminGuide: [],
    offlineMedia: {
      enabled: true,
      connectionAddresses: [],
      folders: [],
      devices: [],
    },
  },
};

describe('homepage mutation request security', () => {
  it.each([
    ['POST', '/api/canary/run'],
    ['POST', '/api/sftp-key'],
    ['POST', '/api/offline-media/devices'],
    ['POST', '/api/offline-music/device'],
    ['DELETE', '/api/offline-media/devices/AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH'],
  ])('rejects a sibling-origin %s request to %s', async (method, url) => {
    const response = await request(method, url, '{}', {
      origin: 'https://groundwater.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'admin',
    });

    expect(response.statusCode).toBe(403);
    expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(/origin|same-origin/) });
  });

  it('requires JSON for a same-origin mutation', async () => {
    const response = await request('POST', '/api/sftp-key', '{}', {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'text/plain',
      'x-forwarded-preferred-username': 'admin',
    });

    expect(response.statusCode).toBe(415);
  });

  it.each([
    ['a missing Origin header', {
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'admin',
    }],
    ['cross-site fetch metadata', {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'sec-fetch-site': 'cross-site',
      'x-forwarded-preferred-username': 'admin',
    }],
    ['a mismatched forwarded protocol', {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-proto': 'http',
      'x-forwarded-preferred-username': 'admin',
    }],
  ])('rejects %s', async (_description, headers) => {
    const response = await request('POST', '/api/sftp-key', '{}', headers);
    expect(response.statusCode).toBe(403);
  });

  it('rejects oversized JSON before invoking a mutation helper', async () => {
    const response = await request('POST', '/api/sftp-key', JSON.stringify({ publicKey: 'x'.repeat(70 * 1024) }), {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json; charset=utf-8',
      'x-forwarded-preferred-username': 'admin',
    });

    expect(response.statusCode).toBe(413);
  });

  it.each(['null', '[]', '"text"'])('rejects a non-object JSON body: %s', async (body) => {
    const response = await request('POST', '/api/sftp-key', body, {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'admin',
    });
    expect(response.statusCode).toBe(400);
  });
});

const request = async (
  method: string,
  url: string,
  body: string,
  headers: IncomingMessage['headers'],
): Promise<{ statusCode: number; body: string }> => {
  const incoming = Readable.from([body]) as IncomingMessage;
  incoming.method = method;
  incoming.url = url;
  incoming.headers = headers;
  const response = makeResponse();
  expect(await handleApiRequest(config, incoming, response.res)).toBe(true);
  return { statusCode: response.statusCode, body: response.body };
};

const makeResponse = (): { res: ServerResponse; readonly statusCode: number; readonly body: string } => {
  const state = { statusCode: 200, body: '' };
  const res = {
    get statusCode() {
      return state.statusCode;
    },
    set statusCode(value: number) {
      state.statusCode = value;
    },
    setHeader() {
      return undefined;
    },
    end(value?: unknown) {
      state.body = typeof value === 'string' ? value : Buffer.isBuffer(value) ? value.toString('utf8') : '';
    },
  } as unknown as ServerResponse;
  return {
    res,
    get statusCode() {
      return state.statusCode;
    },
    get body() {
      return state.body;
    },
  };
};
