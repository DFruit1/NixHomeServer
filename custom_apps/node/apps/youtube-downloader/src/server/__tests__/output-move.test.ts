import { mkdir, mkdtemp, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { allocateUniqueDestination, copyDirectoryContents, copySubtitleSidecars, isArtworkSidecar, isSubtitleSidecar } from '../output-move.js';

let tempDir = '';

beforeEach(async () => {
  tempDir = await mkdtemp(path.join(os.tmpdir(), 'youtube-downloader-output-move-'));
});

afterEach(async () => {
  await rm(tempDir, { recursive: true, force: true });
});

describe('isArtworkSidecar', () => {
  it('matches loose image extensions case-insensitively', () => {
    expect(isArtworkSidecar('cover.jpg')).toBe(true);
    expect(isArtworkSidecar('Cover.JPEG')).toBe(true);
    expect(isArtworkSidecar('art.PnG')).toBe(true);
    expect(isArtworkSidecar('thumb.webp')).toBe(true);
  });

  it('ignores media and metadata files', () => {
    expect(isArtworkSidecar('song.flac')).toBe(false);
    expect(isArtworkSidecar('song.info.json')).toBe(false);
    expect(isArtworkSidecar('01 - Intro.mkv')).toBe(false);
  });
});

describe('copyDirectoryContents', () => {
  it('copies media and metadata while skipping artwork sidecars', async () => {
    const source = path.join(tempDir, 'source');
    const destination = path.join(tempDir, 'destination');
    await mkdir(source, { recursive: true });
    await mkdir(destination, { recursive: true });
    await writeFile(path.join(source, 'Song.flac'), 'audio');
    await writeFile(path.join(source, 'Song.jpg'), 'cover');
    await writeFile(path.join(source, 'Song.info.json'), '{}');

    await copyDirectoryContents(source, destination, { skipArtworkSidecars: true });

    const copied = (await readdir(destination)).sort();
    expect(copied).toEqual(['Song.flac', 'Song.info.json']);
  });

  it('copies artwork sidecars when the filter is not enabled', async () => {
    const source = path.join(tempDir, 'source');
    const destination = path.join(tempDir, 'destination');
    await mkdir(source, { recursive: true });
    await mkdir(destination, { recursive: true });
    await writeFile(path.join(source, 'Song.flac'), 'audio');
    await writeFile(path.join(source, 'Song.jpg'), 'cover');

    await copyDirectoryContents(source, destination);

    const copied = (await readdir(destination)).sort();
    expect(copied).toEqual(['Song.flac', 'Song.jpg']);
  });

  it('copies chapter directories and skips a folder-level cover', async () => {
    const source = path.join(tempDir, 'chapters');
    const destination = path.join(tempDir, 'destination');
    await mkdir(source, { recursive: true });
    await mkdir(destination, { recursive: true });
    await writeFile(path.join(source, '01 - Intro.flac'), 'audio');
    await writeFile(path.join(source, 'cover.jpg'), 'cover');

    await copyDirectoryContents(source, destination, { skipArtworkSidecars: true });

    const copied = (await readdir(destination)).sort();
    expect(copied).toEqual(['01 - Intro.flac']);
  });
});

describe('isSubtitleSidecar', () => {
  it('matches subtitle extensions case-insensitively', () => {
    expect(isSubtitleSidecar('Song.en.srt')).toBe(true);
    expect(isSubtitleSidecar('Song.en.SRT')).toBe(true);
    expect(isSubtitleSidecar('Song.en.vtt')).toBe(true);
    expect(isSubtitleSidecar('Song.ass')).toBe(true);
    expect(isSubtitleSidecar('Song.lrc')).toBe(true);
  });

  it('ignores media, artwork, and metadata files', () => {
    expect(isSubtitleSidecar('Song.flac')).toBe(false);
    expect(isSubtitleSidecar('Song.jpg')).toBe(false);
    expect(isSubtitleSidecar('Song.info.json')).toBe(false);
  });
});

describe('copySubtitleSidecars', () => {
  it('copies only subtitles from the temp root', async () => {
    const source = path.join(tempDir, 'source');
    const destination = path.join(tempDir, 'destination');
    await mkdir(source, { recursive: true });
    await mkdir(destination, { recursive: true });
    await writeFile(path.join(source, 'Talk.en-orig.srt'), 'transcript');
    await writeFile(path.join(source, 'Talk.en.srt'), 'transcript');
    await writeFile(path.join(source, 'Talk.jpg'), 'cover');
    await writeFile(path.join(source, 'Talk.info.json'), '{}');

    await copySubtitleSidecars(source, destination);

    const copied = (await readdir(destination)).sort();
    expect(copied).toEqual(['Talk.en-orig.srt', 'Talk.en.srt']);
  });

  it('does not descend into subdirectories', async () => {
    const source = path.join(tempDir, 'source');
    const destination = path.join(tempDir, 'destination');
    await mkdir(path.join(source, 'chapters'), { recursive: true });
    await mkdir(destination, { recursive: true });
    await writeFile(path.join(source, 'chapters', '01 - Intro.flac'), 'audio');

    await copySubtitleSidecars(source, destination);

    expect(await readdir(destination)).toEqual([]);
  });
});

describe('allocateUniqueDestination', () => {
  it('appends a counter before the extension when a name already exists', async () => {
    const directory = path.join(tempDir, 'unique');
    await mkdir(directory, { recursive: true });
    await writeFile(path.join(directory, 'Song.flac'), 'audio');

    await expect(allocateUniqueDestination(directory, 'Song.flac')).resolves.toBe(path.join(directory, 'Song (1).flac'));
  });
});
