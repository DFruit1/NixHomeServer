import { describe, expect, it } from 'vitest';
import { buildDownloadArgs, parseProgress, transcriptSubLangs } from '../ytdlp.js';
import { normalizeDownloadUrl } from '../../shared/url.js';
import type { CreateJobRequest, ProbeResponse } from '../../shared/types.js';

const probe = (overrides: Partial<ProbeResponse> = {}): ProbeResponse => ({
  title: 'Example',
  chapters: [],
  isPlaylist: false,
  ...overrides,
});

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
    expect(args[0]).toBe('--no-config');
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

  it('does not request subtitles unless the transcript option is set', () => {
    const args = buildDownloadArgs(baseRequest, '/tmp/out.%(ext)s', '/tmp/ch/%(section_title)s.%(ext)s');
    expect(args).not.toContain('--write-subs');
    expect(args).not.toContain('--write-auto-subs');
    expect(args).not.toContain('--convert-subs');
  });

  it('requests manual subtitles and the automatic transcript as srt sidecars', () => {
    const args = buildDownloadArgs(
      { ...baseRequest, downloadTranscript: true },
      '/tmp/out.%(ext)s',
      '/tmp/ch/%(section_title)s.%(ext)s',
    );
    expect(args).toContain('--write-subs');
    expect(args).toContain('--write-auto-subs');
    // ffmpeg cannot demux YouTube's json3 or srv1/2/3 subtitle formats, so vtt
    // has to lead the preference list for --convert-subs to work at all.
    expect(args[args.indexOf('--sub-format') + 1]).toBe('vtt/best');
    expect(args[args.indexOf('--convert-subs') + 1]).toBe('srt');
    expect(args.at(-1)).toBe(baseRequest.url);
  });

  it('requests subtitles for video downloads too', () => {
    const args = buildDownloadArgs(
      {
        ...baseRequest,
        mediaType: 'video',
        audioFormat: undefined,
        videoContainer: 'mkv',
        videoQuality: '1080p',
        downloadTranscript: true,
      },
      '/tmp/out.%(ext)s',
      '/tmp/ch/%(section_title)s.%(ext)s',
    );
    expect(args).toContain('--write-subs');
    expect(args[args.indexOf('--convert-subs') + 1]).toBe('srt');
    expect(args.at(-1)).toBe(baseRequest.url);
  });

  it('takes the subtitle languages from the caller so the probe can add manual tracks', () => {
    const args = buildDownloadArgs(
      { ...baseRequest, downloadTranscript: true },
      '/tmp/out.%(ext)s',
      '/tmp/ch/%(section_title)s.%(ext)s',
      '.*-orig,en,es',
    );
    expect(args[args.indexOf('--sub-langs') + 1]).toBe('.*-orig,en,es');
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

describe('transcriptSubLangs', () => {
  it('always asks for the original-language track and English', () => {
    expect(transcriptSubLangs(probe())).toBe('.*-orig,en');
  });

  it('adds the human-authored tracks the probe reported', () => {
    expect(transcriptSubLangs(probe({ subtitleLanguages: ['es', 'ja'] }))).toBe('.*-orig,en,es,ja');
  });

  it('drops duplicates of the two built-in selectors', () => {
    expect(transcriptSubLangs(probe({ subtitleLanguages: ['en', 'en-US'] }))).toBe('.*-orig,en,en-US');
  });

  it('refuses tags that could change the meaning of the surrounding expression', () => {
    expect(transcriptSubLangs(probe({ subtitleLanguages: ['.*', 'es|ja', '(all)', '', 'a'.repeat(65)] }))).toBe(
      '.*-orig,en',
    );
  });

  it('caps how many manual tracks one download can pull', () => {
    const many = Array.from({ length: 30 }, (_, index) => `lang${index}`);
    const langs = transcriptSubLangs(probe({ subtitleLanguages: many })).split(',');
    expect(langs).toHaveLength(12);
    expect(langs[2]).toBe('lang0');
  });
});
