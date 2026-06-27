import { spawn } from 'node:child_process';

export type CommandResult = {
  code: number | null;
  stdout: string;
  stderr: string;
};

export const runCommand = (command: string, args: string[], options: { timeoutMs?: number } = {}): Promise<CommandResult> =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    const timer = options.timeoutMs
      ? setTimeout(() => {
          child.kill('SIGTERM');
        }, options.timeoutMs)
      : undefined;

    child.stdout.on('data', (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on('data', (chunk: Buffer) => stderr.push(chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      if (timer) {
        clearTimeout(timer);
      }
      resolve({
        code,
        stdout: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
      });
    });
  });
