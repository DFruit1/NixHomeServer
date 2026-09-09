import type { ChildProcess } from 'node:child_process';

export const killChildGroup = (child: ChildProcess, signal: NodeJS.Signals): void => {
  try {
    if (child.pid) {
      process.kill(-child.pid, signal);
      return;
    }
  } catch (error) {
    const code = typeof error === 'object' && error != null && 'code' in error ? String(error.code) : '';
    if (code !== 'ESRCH') {
      throw error;
    }
  }
  try {
    child.kill(signal);
  } catch (error) {
    const code = typeof error === 'object' && error != null && 'code' in error ? String(error.code) : '';
    if (code !== 'ESRCH') {
      throw error;
    }
  }
};

export const childHasExited = (child: ChildProcess): boolean =>
  child.exitCode !== null || child.signalCode !== null;

export const waitForChildExit = (child: ChildProcess): Promise<void> => {
  if (childHasExited(child)) {
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const done = () => {
      child.off('close', done);
      child.off('error', done);
      resolve();
    };
    child.once('close', done);
    child.once('error', done);
  });
};

export const delay = (milliseconds: number): Promise<void> =>
  new Promise((resolve) => {
    const timer = setTimeout(resolve, milliseconds);
    timer.unref();
  });
