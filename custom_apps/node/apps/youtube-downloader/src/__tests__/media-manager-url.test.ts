import { describe, expect, it } from 'vitest';
import { buildMediaManagerUrl } from '../client/media-manager-url.js';

const location = {
  hostname: 'ytdownload.sydneybasiniot.org',
  protocol: 'https:',
};

describe('media manager deep links', () => {
  it('points music at the player view with the linked track path', () => {
    expect(buildMediaManagerUrl('audio', location, 'Artist - Album/Song.flac')).toBe(
      'https://media.sydneybasiniot.org/?view=player&path=Artist+-+Album%2FSong.flac',
    );
  });

  it('points video at the videos view with the linked file path', () => {
    expect(buildMediaManagerUrl('video', location, 'Clip/Clip.mkv')).toBe(
      'https://media.sydneybasiniot.org/?view=videos&path=Clip%2FClip.mkv',
    );
  });

  it('omits the path when it is unknown', () => {
    expect(buildMediaManagerUrl('audio', location)).toBe(
      'https://media.sydneybasiniot.org/?view=player',
    );
  });
});
