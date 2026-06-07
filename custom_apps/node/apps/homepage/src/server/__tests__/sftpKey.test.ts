import { describe, expect, it } from 'vitest';
import { normalisePublicKey } from '../sftpKey.js';

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
});
