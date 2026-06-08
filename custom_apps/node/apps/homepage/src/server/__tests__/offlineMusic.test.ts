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
import { enrollOfflineMusicDevice, normaliseSyncthingDeviceId } from '../offlineMusic.js';

const validDeviceId = 'AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH';
const serverDeviceId = 'IIIIIII-JJJJJJJ-KKKKKKK-LLLLLLL-MMMMMMM-NNNNNNN-OOOOOOO-PPPPPPP';

const baseConfig = (dir: string, sudoPath: string): AppConfig => ({
  host: '127.0.0.1',
  port: 8084,
  staticDir: dir,
  sudoPath,
  syncthingDeviceIdCommand: 'homepage-show-syncthing-device-id',
  offlineMusicStatusCommand: 'homepage-offline-music-status',
  offlineMusicEnrollCommand: 'homepage-offline-music-enroll',
  homepage: {
    domain: 'example.test',
    services: [],
    folderGuides: [],
    adminGuide: [],
    offlineMusic: {
      enabled: true,
      folderName: '_Music',
      folderIdPrefix: 'nixhomeserver-music',
      connectionAddresses: ['tcp://server.home.arpa:22000'],
    },
  },
});

describe('offline music sync helpers', () => {
  it('normalises Syncthing device IDs', () => {
    expect(normaliseSyncthingDeviceId(` ${validDeviceId.toLowerCase()}\n`)).toBe(validDeviceId);
    expect(() => normaliseSyncthingDeviceId('not-a-device')).toThrow(/valid Syncthing device ID/);
  });

  it('passes the authenticated username to the enrollment helper', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'homepage-offline-music-'));
    try {
      const sudo = join(dir, 'sudo.mjs');
      const argsPath = join(dir, 'args.json');
      const stdinPath = join(dir, 'stdin.json');
      await writeFile(
        sudo,
        `#!${execPath}
import { readFileSync, writeFileSync } from 'node:fs';
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
    folderId: 'nixhomeserver-music-' + argv[4],
    folderLabel: 'NixHomeServer Music - ' + argv[4],
    serverDeviceId: ${JSON.stringify(serverDeviceId)},
    serverFolderPath: '/mnt/data/users/' + argv[4] + '/_Music',
    enrolledDeviceId: payload.deviceId,
    enrolledDeviceName: payload.deviceName
  }));
});
stdin.resume();
`,
      );
      await chmod(sudo, 0o755);

      const response = await enrollOfflineMusicDevice(
        baseConfig(dir, sudo),
        { username: 'alice', groups: [] },
        { deviceId: validDeviceId, deviceName: 'alice-phone' },
      );

      expect(response).toMatchObject({
        ok: true,
        username: 'alice',
        folderId: 'nixhomeserver-music-alice',
        enrolledDeviceId: validDeviceId,
      });
      expect(JSON.parse(await readFile(argsPath, 'utf8'))).toEqual(['-n', 'homepage-offline-music-enroll', 'alice']);
      expect(JSON.parse(await readFile(stdinPath, 'utf8'))).toEqual({
        deviceId: validDeviceId,
        deviceName: 'alice-phone',
      });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('surfaces helper stderr as an enrollment error', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'homepage-offline-music-error-'));
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
        enrollOfflineMusicDevice(baseConfig(dir, sudo), { username: 'alice', groups: [] }, { deviceId: validDeviceId }),
      ).rejects.toThrow(/syncthing api unavailable/);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('includes offline music status in homepage data', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'homepage-offline-music-data-'));
    try {
      const sudo = join(dir, 'sudo.mjs');
      await writeFile(
        sudo,
        `#!${execPath}
import { argv, stdout } from 'node:process';
const command = argv[3];
if (command === 'homepage-show-syncthing-device-id') {
  stdout.write(${JSON.stringify(serverDeviceId)} + '\\n');
} else if (command === 'homepage-offline-music-status') {
  stdout.write(JSON.stringify({
    folderId: 'nixhomeserver-music-alice',
    folderLabel: 'NixHomeServer Music - alice',
    serverFolderPath: '/mnt/data/users/alice/_Music',
    enrolledDeviceId: ${JSON.stringify(validDeviceId)},
    enrolledDeviceName: 'alice-phone'
  }));
}
`,
      );
      await chmod(sudo, 0o755);

      const data = await buildHomepageData(baseConfig(dir, sudo), {
        'x-auth-request-preferred-username': 'alice',
      });

      expect(data.offlineMusic).toMatchObject({
        enabled: true,
        serverDeviceId,
        enrolledDeviceId: validDeviceId,
        folderId: 'nixhomeserver-music-alice',
      });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it('requires an authenticated user for the enrollment endpoint', async () => {
    const request = Readable.from([JSON.stringify({ deviceId: validDeviceId })]) as IncomingMessage;
    request.method = 'POST';
    request.url = '/api/offline-music/device';
    request.headers = { host: 'localhost' };

    const response = makeResponse();
    const handled = await handleApiRequest(baseConfig(tmpdir(), execPath), request, response.res);

    expect(handled).toBe(true);
    expect(response.statusCode).toBe(401);
    expect(JSON.parse(response.body)).toMatchObject({ error: expect.stringMatching(/authenticated user/) });
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
