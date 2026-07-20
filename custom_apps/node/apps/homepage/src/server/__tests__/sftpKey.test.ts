import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execPath } from 'node:process';
import { describe, expect, it } from 'vitest';
import type { AppConfig } from '../config.js';
import { installSftpPublicKey, normalisePublicKey } from '../sftpKey.js';

describe('SFTP public key validation', () => {
  it('accepts a normal OpenSSH public key line', () => {
    const key = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECtGBZcPahwDCtWiMgn24qGdqMOJhPpHoPpKsHAF laptop';
    expect(normalisePublicKey(` ${key}\n`)).toBe(key);
  });

  it('rejects multiple lines', () => {
    expect(() => normalisePublicKey('ssh-ed25519 AAAA\nssh-ed25519 BBBB')).toThrow(/single line/);
  });

  it('rejects non-public-key text', () => {
    expect(() => normalisePublicKey('not a key')).toThrow(/OpenSSH/);
  });

  it('returns installer verification details after saving a key', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'homepage-sftp-key-'));
    try {
      const sudo = join(dir, 'sudo.mjs');
      await writeFile(
        sudo,
        `#!${execPath}
import { stdin, stdout } from 'node:process';
stdin.resume();
stdin.on('end', () => stdout.write('installed /persist/appdata/files-sftp-authorized-keys/alice owner=root:root mode=644\\n'));
`,
      );
      await chmod(sudo, 0o755);

      const config: AppConfig = {
        host: '127.0.0.1',
        port: 8084,
        staticDir: dir,
        sftpKeyInstallCommand: 'homepage-install-sftp-key',
        sudoPath: sudo,
        homepage: {
          brandName: 'Test Home',
          domain: 'example.test',
          services: [],
          folderGuides: [],
          adminGuide: [],
        },
      };

      const response = await installSftpPublicKey(
        config,
        { username: 'alice', groups: [] },
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECtGBZcPahwDCtWiMgn24qGdqMOJhPpHoPpKsHAF laptop',
      );

      expect(response).toEqual({
        ok: true,
        message: 'SFTP device key added and verified on the server.',
        details: 'installed /persist/appdata/files-sftp-authorized-keys/alice owner=root:root mode=644',
      });
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
