import { spawn, type ChildProcess } from 'node:child_process';

export type SpawnResult = {
  code: number | null;
  signal: NodeJS.Signals | null;
  stdout: string;
  stderr: string;
};

export const runCommand = (
  command: string,
  args: string[],
  options: { cwd?: string; timeoutMs?: number; onSpawn?: (child: ChildProcess) => void } = {},
): Promise<SpawnResult> =>
  new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    options.onSpawn?.(child);
    let stdout = '';
    let stderr = '';
    const timeout =
      options.timeoutMs == null
        ? undefined
        : setTimeout(() => {
            child.kill('SIGTERM');
          }, options.timeoutMs);

    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('error', reject);
    child.on('close', (code, signal) => {
      if (timeout) {
        clearTimeout(timeout);
      }
      resolve({ code, signal, stdout, stderr });
    });
  });
