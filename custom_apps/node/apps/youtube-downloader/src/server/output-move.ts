import { access, cp, readdir } from 'node:fs/promises';
import path from 'node:path';

export const copyDirectoryContents = async (sourceDir: string, destinationDir: string): Promise<void> => {
  const entries = await readdir(sourceDir, { withFileTypes: true });
  for (const entry of entries) {
    const destination = await allocateUniqueDestination(destinationDir, entry.name);
    await cp(path.join(sourceDir, entry.name), destination, {
      recursive: true,
      force: false,
      errorOnExist: true,
    });
  }
};

export const allocateUniqueDestination = async (directory: string, name: string): Promise<string> => {
  const extension = path.extname(name);
  const base = extension ? name.slice(0, -extension.length) : name;
  for (let index = 0; index < 1000; index += 1) {
    const candidate = index === 0 ? name : `${base} (${index})${extension}`;
    try {
      await access(path.join(directory, candidate));
    } catch {
      return path.join(directory, candidate);
    }
  }
  throw new Error(`could not allocate a unique output name for ${name} under ${directory}`);
};
