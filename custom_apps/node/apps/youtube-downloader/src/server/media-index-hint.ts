import { randomUUID } from 'node:crypto';
import { rename, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';

/**
 * Announces freshly written library paths to Media Manager so it can catalog
 * exactly those files instead of walking the whole library. The hint is
 * written under a dot-prefixed name and renamed into place, so the consumer's
 * `*.json` trigger only ever sees complete files.
 */
export const writeMediaIndexHint = async (hintDir: string, jobId: string, paths: string[]): Promise<void> => {
  if (paths.length === 0) {
    return;
  }
  const name = `${jobId.replace(/[^A-Za-z0-9-]/g, '_')}-${randomUUID()}`;
  const partial = path.join(hintDir, `.${name}.tmp`);
  const payload = JSON.stringify({ schemaVersion: 1, source: 'youtube-downloader', paths });
  try {
    // The drop directory denies listing to everyone but Media Manager, which
    // reads hints as a non-member, so the file itself must be world-readable.
    await writeFile(partial, payload, { mode: 0o644, flag: 'wx' });
    await rename(partial, path.join(hintDir, `${name}.json`));
  } catch (error) {
    await rm(partial, { force: true });
    throw error;
  }
};
