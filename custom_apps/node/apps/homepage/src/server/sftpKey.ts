import { spawn } from 'node:child_process';
import type { ChildProcessWithoutNullStreams } from 'node:child_process';
import type { AppConfig } from './config.js';
import type { CurrentUser, SftpKeyResponse } from '../shared/types.js';

const PUBLIC_KEY_PATTERN =
  /^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+(?: [^\r\n]{0,256})?$/;

export const normalisePublicKey = (raw: unknown): string => {
  if (typeof raw !== 'string') {
    throw new Error('publicKey must be a string');
  }
  const key = raw.trim().replace(/\r/g, '');
  if (!key) {
    throw new Error('public key is required');
  }
  if (key.includes('\n')) {
    throw new Error('public key must be a single line');
  }
  if (key.length > 8192) {
    throw new Error('public key is too large');
  }
  if (!PUBLIC_KEY_PATTERN.test(key)) {
    throw new Error('public key must be an OpenSSH public key');
  }
  return key;
};

export const installSftpPublicKey = async (config: AppConfig, user: CurrentUser, publicKey: string): Promise<SftpKeyResponse> => {
  if (!config.sftpKeyInstallCommand) {
    throw new Error('SFTP key installation is not configured');
  }

  const installCommand = config.sftpKeyInstallCommand;
  const details = await runInstaller(config, installCommand, user.username, publicKey);
  return {
    ok: true,
    message: 'SFTP device key added and verified on the server.',
    details,
  };
};

const runInstaller = (config: AppConfig, installCommand: string, username: string, publicKey: string): Promise<string | undefined> =>
  new Promise((resolve, reject) => {
    const child = spawn(config.sudoPath, ['-n', installCommand, username], {
      stdio: ['pipe', 'pipe', 'pipe'],
    }) as ChildProcessWithoutNullStreams;
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];

    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) {
        const detail = Buffer.concat(stdout).toString('utf8').trim();
        resolve(detail || undefined);
        return;
      }
      const detail = Buffer.concat(stderr).toString('utf8').trim();
      reject(new Error(detail || `SFTP key installer exited with status ${code}`));
    });

    child.stdin.end(`${publicKey}\n`);
  });
