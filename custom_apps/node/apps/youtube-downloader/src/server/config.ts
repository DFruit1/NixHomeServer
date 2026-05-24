export type AppConfig = {
  host: string;
  port: number;
  stateDir: string;
  databasePath: string;
  tempRoot: string;
  staticDir: string;
  ytDlpPath: string;
  sharedVideoRoot: string;
  sharedAudioRoot: string;
  usersRoot: string;
  concurrency: number;
  sharedWriteGroup: string;
};

const numberFromEnv = (name: string, fallback: number): number => {
  const raw = process.env[name];
  if (!raw) {
    return fallback;
  }
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) && value > 0 ? value : fallback;
};

export const loadConfig = (): AppConfig => {
  const stateDir = process.env.YOUTUBE_DOWNLOADER_STATE_DIR ?? '/var/lib/youtube-downloader/state';
  return {
    host: process.env.YOUTUBE_DOWNLOADER_HOST ?? '127.0.0.1',
    port: numberFromEnv('YOUTUBE_DOWNLOADER_PORT', 8083),
    stateDir,
    databasePath: process.env.YOUTUBE_DOWNLOADER_DATABASE ?? `${stateDir}/youtube-downloader.sqlite`,
    tempRoot: process.env.YOUTUBE_DOWNLOADER_TEMP_DIR ?? '/var/cache/youtube-downloader/tmp',
    staticDir: process.env.YOUTUBE_DOWNLOADER_STATIC_DIR ?? new URL('../../client', import.meta.url).pathname,
    ytDlpPath: process.env.YOUTUBE_DOWNLOADER_YTDLP ?? 'yt-dlp',
    sharedVideoRoot: process.env.YOUTUBE_DOWNLOADER_SHARED_VIDEO_ROOT ?? '/mnt/data/shared/videos/youtube',
    sharedAudioRoot: process.env.YOUTUBE_DOWNLOADER_SHARED_AUDIO_ROOT ?? '/mnt/data/shared/audiobooks/youtube',
    usersRoot: process.env.YOUTUBE_DOWNLOADER_USERS_ROOT ?? '/mnt/data/users',
    concurrency: numberFromEnv('YOUTUBE_DOWNLOADER_CONCURRENCY', 1),
    sharedWriteGroup: process.env.YOUTUBE_DOWNLOADER_SHARED_WRITE_GROUP ?? 'files-shared-users',
  };
};
