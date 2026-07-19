const YOUTUBE_HOSTS = new Set([
  'youtube.com',
  'www.youtube.com',
  'm.youtube.com',
  'music.youtube.com',
]);

const YOUTUBE_SHORT_HOSTS = new Set(['youtu.be', 'www.youtu.be']);

const isYouTubeHost = (host: string): boolean => YOUTUBE_HOSTS.has(host) || YOUTUBE_SHORT_HOSTS.has(host);

export const isYouTubeUrl = (value: string): boolean => {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return false;
  }
  if (parsed.protocol !== 'https:') {
    return false;
  }
  return isYouTubeHost(parsed.hostname.toLowerCase());
};

export const normalizeDownloadUrl = (value: string): string => {
  const trimmed = value.trim();
  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return trimmed;
  }

  const host = parsed.hostname.toLowerCase();
  if (!isYouTubeHost(host)) {
    return trimmed;
  }

  const clean = new URL(parsed.href);
  clean.search = '';
  clean.hash = '';

  if (YOUTUBE_SHORT_HOSTS.has(host)) {
    return clean.toString();
  }

  if (parsed.pathname === '/watch') {
    const videoId = parsed.searchParams.get('v')?.trim();
    const listId = parsed.searchParams.get('list')?.trim();
    if (videoId) {
      clean.searchParams.set('v', videoId);
    } else if (listId) {
      clean.searchParams.set('list', listId);
    }
  } else if (parsed.pathname === '/playlist') {
    const listId = parsed.searchParams.get('list')?.trim();
    if (listId) {
      clean.searchParams.set('list', listId);
    }
  }

  return clean.toString();
};
