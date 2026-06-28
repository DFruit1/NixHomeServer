import { describe, expect, it } from 'vitest';
import { buildDownloadArgs, parseProgress } from '../ytdlp.js';
import { normalizeDownloadUrl } from '../../shared/url.js';
import type { CreateJobRequest } from '../../shared/types.js';

const baseRequest = {
  url: 'https://example.test/watch?v=1',
  destination: 'personal',
  mediaType: 'audio',
  audioFormat: 'flac',
  splitChapters: false,
  includeChannel: true,
  includeDate: true,
} satisfies CreateJobRequest;

describe('yt-dlp argv generation', () => {
  it('generates flac extraction without shell interpolation', () => {
    const args = buildDownloadArgs(baseRequest, '/tmp/out.%(ext)s', '/tmp/ch/%(section_title)s.%(ext)s');
    expect(args).toContain('-x');
    expect(args).toContain('--windows-filenames');
    expect(args).toContain('--audio-format');
    expect(args).toContain('flac');
    expect(args).toContain('--embed-thumbnail');
    expect(args.at(-1)).toBe(baseRequest.url);
  });

  it('can disable embedded cover art for audio extraction', () => {
    const args = buildDownloadArgs({ ...baseRequest, embedAudioCoverArt: false }, '/tmp/out.%(ext)s', '/tmp/ch/%(section_title)s.%(ext)s');
    expect(args).not.toContain('--embed-thumbnail');
    expect(args).toContain('--write-thumbnail');
  });

  it('downloads one converted source file for audio chapter splitting', () => {
    const args = buildDownloadArgs({ ...baseRequest, splitChapters: true }, '/tmp/out.%(ext)s', '/tmp/ch/%(section_title)s.%(ext)s');
    expect(args).not.toContain('--split-chapters');
    expect(args).toContain('-x');
    expect(args).toContain('--audio-format');
    expect(args).toContain('flac');
    expect(args).toContain('--embed-chapters');
  });

  it('generates split chapter output arguments for video', () => {
    const args = buildDownloadArgs(
      {
        ...baseRequest,
        mediaType: 'video',
        audioFormat: undefined,
        videoContainer: 'mkv',
        videoQuality: '1080p',
        splitChapters: true,
      },
      '/tmp/out.%(ext)s',
      '/tmp/ch/%(section_title)s.%(ext)s',
    );
    expect(args).toContain('--split-chapters');
    expect(args).toContain('chapter:/tmp/ch/%(section_title)s.%(ext)s');
  });

  it('generates video quality selectors', () => {
    const args = buildDownloadArgs(
      {
        ...baseRequest,
        mediaType: 'video',
        audioFormat: undefined,
        videoContainer: 'mkv',
        videoQuality: '1080p',
      },
      '/tmp/out.%(ext)s',
      '/tmp/ch/%(section_title)s.%(ext)s',
    );
    expect(args).toContain('bestvideo[height<=1080]+bestaudio/best[height<=1080]/best');
    expect(args).toContain('--format-sort');
    expect(args).toContain('+vcodec:avc,+acodec:m4a,res,fps,br');
    expect(args).toContain('--merge-output-format');
  });

  it('parses yt-dlp progress lines', () => {
    expect(parseProgress('[download]  42.5% of 10.00MiB at 1.00MiB/s ETA 00:05')).toEqual({
      percent: 42.5,
      speed: '1.00MiB/s',
      eta: '00:05',
    });
  });

  it('strips YouTube watch context and tracking parameters from single-video URLs', () => {
    expect(
      normalizeDownloadUrl(' https://www.youtube.com/watch?si=abc&v=fiwd5hMQsEU&list=RDfiwd5hMQsEU&radio-start=1&t=20s '),
    ).toBe('https://www.youtube.com/watch?v=fiwd5hMQsEU');
  });

  it('keeps YouTube playlist IDs on playlist URLs', () => {
    expect(normalizeDownloadUrl('https://www.youtube.com/playlist?list=PL123&si=abc&radio-start=1')).toBe(
      'https://www.youtube.com/playlist?list=PL123',
    );
  });
});
