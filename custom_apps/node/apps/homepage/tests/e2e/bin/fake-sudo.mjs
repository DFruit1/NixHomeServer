#!/usr/bin/env node
import { spawn } from 'node:child_process';
import process from 'node:process';

const args = process.argv.slice(2);
if (args[0] === '-n') {
  args.shift();
}

const command = args.shift();
if (!command) {
  process.stderr.write('missing command\n');
  process.exit(1);
}

const child = spawn(process.execPath, [command, ...args], {
  stdio: ['pipe', 'pipe', 'pipe'],
});

process.stdin.pipe(child.stdin);
child.stdout.pipe(process.stdout);
child.stderr.pipe(process.stderr);
child.on('close', (code) => process.exit(code ?? 1));
child.on('error', (error) => {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
