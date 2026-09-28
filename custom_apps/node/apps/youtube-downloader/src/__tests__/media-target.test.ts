import { describe, expect, it } from 'vitest';
import { buildMediaTargetPath, pickMediaFile } from '../client/media-target.js';

describe('media target selection', () => {
  it('prefers the file matching the job kind', () => {
    expect(
      pickMediaFile(['cover.jpg', 'notes.txt', 'song.flac'], 'audio'),
    ).toBe('song.flac');
    expect(
      pickMediaFile(['poster.jpg', 'clip.mkv'], 'video'),
    ).toBe('clip.mkv');
  });

  it('recognises audio-only formats that the previous list missed', () => {
    expect(pickMediaFile(['track.aac'], 'audio')).toBe('track.aac');
    expect(pickMediaFile(['track.ogg'], 'audio')).toBe('track.ogg');
    expect(pickMediaFile(['track.m4b'], 'audio')).toBe('track.m4b');
  });

  it('falls back to any media file when the preferred kind is absent', () => {
    expect(pickMediaFile(['clip.mp4'], 'audio')).toBe('clip.mp4');
    expect(pickMediaFile(['cover.jpg', 'notes.txt'], 'audio')).toBeUndefined();
  });

  it('builds a folder/file tail from the output folder leaf', () => {
    expect(
      buildMediaTargetPath(
        '/mnt/data/shared/_Music/_YouTube/Artist - Album',
        ['Artist - Album - Song.flac'],
        'audio',
      ),
    ).toBe('Artist - Album/Artist - Album - Song.flac');
  });

  it('supports Windows-style output folders', () => {
    expect(
      buildMediaTargetPath(
        'C:\\Users\\dsaw\\_Music\\_YouTube\\Artist',
        ['Song.mp3'],
        'audio',
      ),
    ).toBe('Artist/Song.mp3');
  });

  it('omits the target when the folder or media file is unknown', () => {
    expect(buildMediaTargetPath(undefined, ['Song.mp3'], 'audio')).toBeUndefined();
    expect(
      buildMediaTargetPath('/music/Artist', ['cover.jpg'], 'audio'),
    ).toBeUndefined();
  });
});
