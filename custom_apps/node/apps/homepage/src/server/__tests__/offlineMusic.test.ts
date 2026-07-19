import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execPath } from 'node:process';
import { Readable } from 'node:stream';
import { describe, expect, it } from 'vitest';
import type { IncomingMessage, ServerResponse } from 'node:http';
import type { AppConfig } from '../config.js';
import { buildHomepageData } from '../homepageData.js';
import { handleApiRequest } from '../http.js';
import { enrollOfflineMediaDevice, normaliseSyncthingDeviceId, removeOfflineMediaDevice } from '../offlineMedia.js';

const validDeviceId = 'AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH';
const serverDeviceId = 'IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP';

const baseConfig = (dir: string, sudoPath: string): AppConfig => ({
  host: '127.0.0.1',
  port: 8084,
  staticDir: dir,
  sudoPath,
  syncthingDeviceIdCommand: 'homepage-show-syncthing-device-id',
  offlineMediaStatusCommand: 'homepage-offline-media-status',
  offlineMediaEnrollCommand: 'homepage-offline-media-enroll',
  offlineMediaRemoveCommand: 'homepage-offline-media-remove',
  homepage: {
    brandName: 'Test Home',
    domain: 'example.test',
    services: [],
    folderGuides: [],
    adminGuide: [],
    offlineMedia: {
      enabled: true,
      connectionAddresses: ['tcp://server.internal:22000'],
      folders: [],
      devices: [],
    },
  },
});

describe('offline media sync helpers', () => {
  it('normalises Syncthing device IDs', () => {
    expect(normaliseSyncthingDeviceId(` ${validDeviceId.toLowerCase()}\n`)).toBe(validDeviceId);
    expect(() => normaliseSyncthingDeviceId('not-a-device')).toThrow(/valid Syncthing device ID/);
  });

  it('passes the authenticated username to the enrollment helper', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'homepage-offline-media-'));
    try {
      const sudo = join(dir, 'sudo.mjs');
      const argsPath = join(dir, 'args.json');
      const stdinPath = join(dir, 'stdin.json');
      await writeFile(
        sudo,
        `#!${execPath}
import { writeFileSync } from 'node:fs';
import { argv, stdin, stdout } from 'node:process';
const chunks = [];
stdin.on('data', chunk => chunks.push(chunk));
stdin.on('end', () => {
  const input = Buffer.concat(chunks).toString('utf8');
  writeFileSync(${JSON.stringify(argsPath)}, JSON.stringify(argv.slice(2)));
  writeFileSync(${JSON.stringify(stdinPath)}, input);
  const payload = JSON.parse(input);
  stdout.write(JSON.stringify({
    ok: true,
    username: argv[4],
    serverDeviceId: ${JSON.stringify(serverDeviceId)},
    enrolledDeviceId: payload.deviceId,
    enrolledDeviceName: payload.deviceName,
    folders: [
      {
        key: 'music',
        label: 'Music',
        folderId: 'nixhomeserver-music-' + argv[4],
        folderLabel: 'NixHomeServer Music - ' + argv[4],
        serverFolderPath: '/mnt/data/users/' + argv[4] + '/_Music',
        suggestedDevicePath: 'Music/NixHomeServer'
      }
    ],
    devices: [{ deviceId: payload.deviceId, deviceName: payload.deviceName }]
  }));
});
stdin.resume();
`,
      );
      await chmod(sudo, 0o755);

      const response = await enrollOfflineMediaDevice(
        baseConfig(dir, sudo),
        { username: 'alice', groups: [] },
        { deviceId: validDeviceId, deviceName: 'alice-phone' },
      );

      expect(response).toMatchObject({
        ok: true,
        username: 'alice',
        enrolledDeviceId: validDeviceId,
        devices: [{ deviceId: validDeviceId, deviceName: 'alice-phone' }],
      });
      expect(JSON.parse(await readFile(argsPath, 'utf8'))).toEqual(['-n', 'homepage-offline-media-enroll', 'alice']);
      expect(JSON.parse(await readFile(stdinPath, 'utf8'))).toEqual({
        deviceId: validDeviceId,
        deviceName: 'alice-phone',
      });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('surfaces helper stderr as an enrollment error', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'homepage-offline-media-error-'));
    try {
      const sudo = join(dir, 'sudo.mjs');
      await writeFile(
        sudo,
        `#!${execPath}
import { stderr, exit } from 'node:process';
stderr.write('syncthing api unavailable\\n');
exit(1);
`,
      );
      await chmod(sudo, 0o755);

      await expect(
        enrollOfflineMediaDevice(baseConfig(dir, sudo), { username: 'alice', groups: [] }, { deviceId: validDeviceId }),
      ).rejects.toThrow(/syncthing api unavailable/);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('includes offline media status in homepage data', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'homepage-offline-media-data-'));
    try {
      const sudo = join(dir, 'sudo.mjs');
      await writeFile(
        sudo,
        `#!${execPath}
import { argv, stdout } from 'node:process';
const command = argv[3];
if (command === 'homepage-show-syncthing-device-id') {
  stdout.write(${JSON.stringify(serverDeviceId)} + '\\n');
} else if (command === 'homepage-offline-media-status') {
  stdout.write(JSON.stringify({
    folders: [{
      key: 'music',
      label: 'Music',
      folderId: 'nixhomeserver-music-alice',
      folderLabel: 'NixHomeServer Music - alice',
      serverFolderPath: '/mnt/data/users/alice/_Music',
      suggestedDevicePath: 'Music/NixHomeServer'
    }],
    devices: [{
      deviceId: ${JSON.stringify(validDeviceId)},
      deviceName: 'alice-phone',
      connected: false,
      lastSeen: '2026-06-15T13:43:28Z',
      completion: 54.75,
      needBytes: 4755446849,
      needItems: 46
    }]
  }));
}
`,
      );
      await chmod(sudo, 0o755);

      const data = await buildHomepageData(baseConfig(dir, sudo), {
        'x-auth-request-preferred-username': 'alice',
      });

      expect(data.offlineMedia).toMatchObject({
        enabled: true,
        serverDeviceId,
        devices: [{
          deviceId: validDeviceId,
          deviceName: 'alice-phone',
          connected: false,
          completion: 54.75,
          needBytes: 4755446849,
          needItems: 46,
        }],
      });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('requires an authenticated user for the enrollment endpoint', async () => {
    const request = Readable.from([JSON.stringify({ deviceId: validDeviceId })]) as IncomingMessage;
    request.method = 'POST';
    request.url = '/api/offline-media/devices';
    request.headers = {
      host: 'localhost',
      origin: 'http://localhost',
      'content-type': 'application/json',
    };

    const response = makeResponse();
    const handled = await handleApiRequest(baseConfig(tmpdir(), execPath), request, response.res);

    expect(handled).toBe(true);
    expect(response.statusCode).toBe(401);
    expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(/authenticated user/) });
  });

  it('passes the authenticated username and device ID to the removal helper', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'homepage-offline-media-remove-'));
    try {
      const sudo = join(dir, 'sudo.mjs');
      const argsPath = join(dir, 'args.json');
      await writeFile(
        sudo,
        `#!${execPath}
import { writeFileSync } from 'node:fs';
import { argv, stdout } from 'node:process';
writeFileSync(${JSON.stringify(argsPath)}, JSON.stringify(argv.slice(2)));
stdout.write(JSON.stringify({
  ok: true,
  username: argv[4],
  removedDeviceId: argv[5],
  folders: [],
  devices: []
}));
`,
      );
      await chmod(sudo, 0o755);

      const response = await removeOfflineMediaDevice(baseConfig(dir, sudo), { username: 'alice', groups: [] }, validDeviceId);

      expect(response).toMatchObject({
        ok: true,
        username: 'alice',
        removedDeviceId: validDeviceId,
      });
      expect(JSON.parse(await readFile(argsPath, 'utf8'))).toEqual(['-n', 'homepage-offline-media-remove', 'alice', validDeviceId]);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});

const makeResponse = (): { res: ServerResponse; readonly statusCode: number; readonly body: string } => {
  const state = {
    statusCode: 200,
    body: '',
  };
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
