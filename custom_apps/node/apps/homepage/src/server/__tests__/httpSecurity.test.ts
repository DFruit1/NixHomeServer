import { tmpdir } from 'node:os';
import { Readable } from 'node:stream';
import { describe, expect, it } from 'vitest';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { AppConfig } from '../config.js';
import { handleApiRequest, handleRequest } from '../http.js';

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
    sftp: {
      enabled: true,
      host: 'server.internal',
      port: 2222,
      networkNote: 'LAN only.',
      requiredAnyGroups: ['files-sftp-users', 'files-shared-users', 'usb-access', 'backup-storage-users'],
    },
    offlineMedia: {
      enabled: true,
      requiredAnyGroups: ['offline-media-users'],
      connectionAddresses: [],
      folders: [],
      devices: [],
    },
  },
};
const validDeviceId = 'AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH';
const offlineMutationConfig: AppConfig = {
  ...config,
  offlineMediaEnrollCommand: '/bin/false',
  offlineMediaRemoveCommand: '/bin/false',
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

  it('rejects SFTP key installation for a user outside the evaluated access group', async () => {
    const response = await request('POST', '/api/sftp-key', JSON.stringify({
      publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECtGBZcPahwDCtWiMgn24qGdqMOJhPpHoPpKsHAF laptop',
    }), {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'alice',
      'x-forwarded-groups': 'users',
    });
    expect(response.statusCode).toBe(403);
  });

  it('reports malformed SFTP public keys as client errors', async () => {
    const response = await request('POST', '/api/sftp-key', JSON.stringify({ publicKey: 'not a key' }), {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'alice',
      'x-forwarded-groups': 'files-sftp-users',
    });
    expect(response.statusCode).toBe(400);
    expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(/OpenSSH public key/) });
  });

  it.each(['files-shared-users', 'usb-access', 'backup-storage-users'])(
    'authorises SFTP key enrollment for a role-only %s user',
    async (group) => {
      const response = await request('POST', '/api/sftp-key', JSON.stringify({ publicKey: 'not a key' }), {
        origin: 'https://homepage.example.test',
        host: 'homepage.example.test',
        'content-type': 'application/json',
        'x-forwarded-preferred-username': 'role-only-user',
        'x-forwarded-groups': group,
      });
      // A validation error proves this role passed feature authorization and
      // reached the public-key parser; an unauthorized role returns 403.
      expect(response.statusCode).toBe(400);
      expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(/OpenSSH public key/) });
    },
  );

  it.each([
    ['GET', '/api/offline-media'],
    ['POST', '/api/offline-media/devices'],
    ['DELETE', '/api/offline-media/devices/AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH'],
  ])('rejects %s %s outside the offline-media access group', async (method, url) => {
    const response = await request(method, url, '{}', {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'alice',
      'x-forwarded-groups': 'users',
    });
    expect(response.statusCode).toBe(403);
  });

  it.each([
    ['an invalid device ID', { deviceId: 'not-a-syncthing-id', deviceName: 'alice-phone' }, /deviceId/],
    ['a non-string device ID', { deviceId: 42, deviceName: 'alice-phone' }, /deviceId/],
    ['an invalid device name', { deviceId: validDeviceId, deviceName: 'bad\nname' }, /deviceName/],
    ['a non-string device name', { deviceId: validDeviceId, deviceName: { unsafe: true } }, /deviceName/],
  ])('reports %s as HTTP 400', async (_description, payload, expectedError) => {
    const response = await request('POST', '/api/offline-media/devices', JSON.stringify(payload), {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'alice',
      'x-forwarded-groups': 'offline-media-users',
    }, offlineMutationConfig);
    expect(response.statusCode).toBe(400);
    expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(expectedError) });
  });

  it('reports an invalid removal device ID as HTTP 400', async () => {
    const response = await request('DELETE', '/api/offline-media/devices/not-a-syncthing-id', '{}', {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'alice',
      'x-forwarded-groups': 'offline-media-users',
    }, offlineMutationConfig);
    expect(response.statusCode).toBe(400);
    expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(/deviceId/) });
  });

  it('reports malformed device-path URI encoding as HTTP 400', async () => {
    const response = await request('DELETE', '/api/offline-media/devices/%E0%A4%A', '{}', {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'alice',
      'x-forwarded-groups': 'offline-media-users',
    }, offlineMutationConfig);
    expect(response.statusCode).toBe(400);
    expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(/URI|malformed/i) });
  });

  it('reports malformed static-path URI encoding as HTTP 400', async () => {
    const incoming = Readable.from([]) as IncomingMessage;
    incoming.method = 'GET';
    incoming.url = '/%E0%A4%A';
    incoming.headers = { host: 'homepage.example.test' };
    const response = makeResponse();

    await handleRequest(config, incoming, response.res);

    expect(response.statusCode).toBe(400);
    expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(/URI|malformed/i) });
  });

  it.each([
    ['GET', '/api/offline-media'],
    ['GET', '/api/offline-music'],
    ['POST', '/api/offline-media/devices'],
    ['POST', '/api/offline-music/device'],
    ['DELETE', '/api/offline-media/devices/AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH'],
  ])('returns not found for %s %s when offline media is disabled', async (method, url) => {
    const disabledConfig: AppConfig = {
      ...config,
      homepage: { ...config.homepage, offlineMedia: { ...config.homepage.offlineMedia!, enabled: false } },
    };
    const response = await request(method, url, '{}', {
      origin: 'https://homepage.example.test',
      host: 'homepage.example.test',
      'content-type': 'application/json',
      'x-forwarded-preferred-username': 'alice',
      // Deliberately omit offline-media-users: disabled routes must stop at
      // the feature boundary instead of falling through to a group denial.
      'x-forwarded-groups': 'users',
    }, disabledConfig);
    expect(response.statusCode).toBe(404);
  });
});

const request = async (
  method: string,
  url: string,
  body: string,
  headers: IncomingMessage['headers'],
  appConfig: AppConfig = config,
): Promise<{ statusCode: number; body: string }> => {
  const incoming = Readable.from([body]) as IncomingMessage;
  incoming.method = method;
  incoming.url = url;
  incoming.headers = headers;
  const response = makeResponse();
  expect(await handleApiRequest(appConfig, incoming, response.res)).toBe(true);
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
