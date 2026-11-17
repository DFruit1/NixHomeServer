/**
 * Shared names for files and folders. Everything here is presentation-only
 * except `stripProviderIdTags`, which mirrors the server parser and is safe
 * for values that are saved or used to rename files.
 */

const FRIENDLY_FOLDER_NAMES: Record<string, string> = {
  _movies: "Movies",
  _shows: "TV shows",
  _tv: "TV shows",
  _unidentified: "Not yet identified",
  _youtube: "YouTube",
  _ebooks: "Ebooks",
  _anon: "Anonymous",
  _tombstone: "Removed",
  _transcribe: "Waiting for transcription",
};

/** Name a folder the way a person would, hiding the server's `_` prefix. */
export function friendlyFolderName(name: string): string {
  const known = FRIENDLY_FOLDER_NAMES[name.toLowerCase()];
  if (known) return known;
  if (name.startsWith("_") && name.length > 1) {
    return name.slice(1).replace(/[_-]+/g, " ");
  }
  return name;
}

/** Apply {@link friendlyFolderName} to every segment of a relative path. */
export function friendlyPath(relativePath: string): string {
  return relativePath
    .split("/")
    .filter(Boolean)
    .map((segment) => stripIdTags(friendlyFolderName(segment)))
    .join(" / ");
}

// `[tmdbid-799]`, `{imdb-tt0123}`, `[dQw4w9WgXcQ]` (YouTube) and similar
// machine identifiers that people never type themselves. An 11-character
// YouTube id must contain a digit so real words such as "[Anniversary]" or
// "[Extended-Ed]" survive.
const ID_TAG =
  /\s*[[{](?:(?:tmdb|tvdb|imdb|musicbrainz|mbid|isbn|asin|youtube)(?:id)?[-=:\s][^\]}]+|(?=[A-Za-z_-]*\d)[A-Za-z0-9_-]{11})[\]}]/gi;

/** Remove provider/ID tags such as `[tmdbid-799]` from a name. Display only. */
export function stripIdTags(name: string): string {
  return name
    .replace(ID_TAG, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

// Exactly the tags the server's `split_provider_id_tags` (metadata.rs)
// understands, so values sent back to the server agree with its parser.
const PROVIDER_ID_TAG =
  /\s*[[{](?:tmdb|tvdb)(?:id)?[-=: ]\s*\d+\s*[\]}]|\s*[[{]imdb(?:id)?[-=: ]\s*tt\d+\s*[\]}]/gi;

/** Remove only server-recognised provider tags (`[tmdbid-799]`); safe for
 * values that are saved or used to rename files. */
export function stripProviderIdTags(name: string): string {
  return name
    .replace(PROVIDER_ID_TAG, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

const MEDIA_EXTENSION =
  /\.(?:mkv|mp4|m4v|avi|mov|webm|wmv|ts|m2ts|iso|mp3|m4a|m4b|flac|ogg|opus|wav|aac|epub|pdf|mobi|azw3|cbz|cbr|cb7|srt|vtt|ass|jpg|jpeg|png|webp|gif|heic)$/i;

// Release-group noise in scene-style names ("1975.DVDRip.x264-GROUP").
const RELEASE_NOISE =
  /\b(?:2160p|1080p|720p|480p|4k|uhd|hdr10?|dv|dvdrip|bdrip|brrip|bluray|blu-ray|web-?dl|webrip|hdtv|remux|x26[45]|h\.?26[45]|hevc|avc|xvid|divx|aac(?:2\.0)?|ac3|dts(?:-hd)?|atmos|ddp?5\.1|10bit|8bit|proper|repack|extended|unrated)\b.*$/i;

const AUDIO_EXTENSION = /\.(?:mp3|m4a|m4b|flac|ogg|opus|wav|aac)$/i;

/**
 * Turn a file name into something readable when no real title is known:
 * drop the extension and ID tags, turn scene-style dot/underscore names
 * ("All.Creatures.1975.DVDRip.x264") into words without release noise, and
 * drop a leading track number from audio files only, so "12 Angry Men" and
 * "300 (2006)" keep their titles.
 */
export function displayTitleFromFileName(fileName: string): string {
  let name = fileName.replace(MEDIA_EXTENSION, "");
  name = stripIdTags(name);
  // Scene names have no spaces at all; only then are dots and underscores
  // separators and trailing tokens release noise. "Dr. No (1962)" keeps its
  // dot and "A Proper Job (2010)" keeps its words.
  if (!/\s/.test(name) && /[._][^._]/.test(name)) {
    name = name.replace(/[._]/g, " ").replace(RELEASE_NOISE, "");
    // "1975" left dangling after a scene title becomes "(1975)".
    name = name.replace(/\s((?:19|20)\d{2})\s*$/, " ($1)");
  }
  if (AUDIO_EXTENSION.test(fileName)) name = stripLeadingTrackNumber(name);
  name = name
    .replace(/\s*[-–]\s*$/, "")
    .replace(/\s{2,}/g, " ")
    .trim();
  return name || fileName;
}

/** "01 Track One" / "01 - Track One" / "1. Track One" → "Track One". */
export function stripLeadingTrackNumber(title: string): string {
  const stripped = title.replace(
    /^\s*(?:\d{1,2}-)?\d{1,3}(?:\s*[-.–]\s*|\s+)(?=\S)/,
    "",
  );
  return stripped || title;
}

/** Decimal sizes (KB/MB/GB) because that is what people see elsewhere. */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return "—";
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let index = 0;
  while (value >= 1000 && index < units.length - 1) {
    value /= 1000;
    index += 1;
  }
  return `${value >= 10 || index === 0 ? value.toFixed(0) : value.toFixed(1)} ${units[index]}`;
}

/** Common languages by ISO 639-1 code, for pickers instead of free text. */
export const LANGUAGE_OPTIONS: ReadonlyArray<{ code: string; name: string }> = [
  { code: "en", name: "English" },
  { code: "es", name: "Spanish" },
  { code: "fr", name: "French" },
  { code: "de", name: "German" },
  { code: "it", name: "Italian" },
  { code: "pt", name: "Portuguese" },
  { code: "nl", name: "Dutch" },
  { code: "sv", name: "Swedish" },
  { code: "no", name: "Norwegian" },
  { code: "da", name: "Danish" },
  { code: "fi", name: "Finnish" },
  { code: "pl", name: "Polish" },
  { code: "ru", name: "Russian" },
  { code: "uk", name: "Ukrainian" },
  { code: "el", name: "Greek" },
  { code: "tr", name: "Turkish" },
  { code: "ar", name: "Arabic" },
  { code: "he", name: "Hebrew" },
  { code: "hi", name: "Hindi" },
  { code: "zh", name: "Chinese" },
  { code: "ja", name: "Japanese" },
  { code: "ko", name: "Korean" },
  { code: "th", name: "Thai" },
  { code: "vi", name: "Vietnamese" },
  { code: "id", name: "Indonesian" },
  { code: "la", name: "Latin" },
];

const ISO_639_2_TO_1: Record<string, string> = {
  eng: "en",
  spa: "es",
  fra: "fr",
  fre: "fr",
  deu: "de",
  ger: "de",
  ita: "it",
  por: "pt",
  nld: "nl",
  dut: "nl",
  swe: "sv",
  nor: "no",
  dan: "da",
  fin: "fi",
  pol: "pl",
  rus: "ru",
  ukr: "uk",
  ell: "el",
  gre: "el",
  tur: "tr",
  ara: "ar",
  heb: "he",
  hin: "hi",
  zho: "zh",
  chi: "zh",
  jpn: "ja",
  kor: "ko",
  tha: "th",
  vie: "vi",
  ind: "id",
  lat: "la",
};

/** Normalise "eng"/"EN"/"en-GB" to the two-letter code used in pickers. */
export function normalizeLanguageCode(code: string): string {
  const base = code.trim().toLowerCase().split(/[-_]/)[0] ?? "";
  return ISO_639_2_TO_1[base] ?? base;
}

/** "en" / "eng" → "English"; unknown codes are shown as given. */
export function languageName(code: string): string {
  const normalized = normalizeLanguageCode(code);
  return (
    LANGUAGE_OPTIONS.find((option) => option.code === normalized)?.name ?? code
  );
}

/**
 * {@link displayTitleFromFileName} for films and episodes, whose real names
 * can start with a number ("21 Jump Street (2012)", "300 (2006)"), so a
 * leading number is kept rather than read as a track number.
 */
export function displayVideoTitleFromFileName(fileName: string): string {
  // Leading numbers are only stripped from audio, so video titles such as
  // "21 Jump Street" are already safe.
  return displayTitleFromFileName(fileName);
}

const FRIENDLY_APP_NAMES: Record<string, string> = {
  jellyfin: "Videos app",
  audiobookshelf: "Audiobooks app",
  kavita: "Books app",
  immich: "Photos",
  radarr: "Movie downloader",
  sonarr: "TV downloader",
};

/** Name a server application by what it does ("jellyfin" → "Videos app");
 * unknown ids fall back to the label the server gave. */
export function friendlyAppName(id: string, label = id): string {
  return FRIENDLY_APP_NAMES[id.toLowerCase()] ?? label;
}

/** "en" → "eng": the three-letter code some providers (TheTVDB) expect.
 * Codes without a known mapping are returned unchanged. */
export function threeLetterLanguageCode(code: string): string {
  const normalized = normalizeLanguageCode(code);
  return (
    Object.entries(ISO_639_2_TO_1).find(([, two]) => two === normalized)?.[0] ??
    code
  );
}

/** Regional variants subtitle sites (OpenSubtitles, SubDL) list separately. */
export const REGIONAL_LANGUAGE_OPTIONS: ReadonlyArray<{
  code: string;
  name: string;
}> = [
  { code: "pt-br", name: "Portuguese (Brazil)" },
  { code: "zh-cn", name: "Chinese (Simplified)" },
  { code: "zh-tw", name: "Chinese (Traditional)" },
];

/**
 * Language picker choices that keep an unlisted current value selectable,
 * so a stored "en-gb" is never shown as some other language. `regional`
 * adds the subtitle sites' regional variants.
 */
export function languageChoices(
  current: string,
  regional = false,
): Array<{ code: string; name: string }> {
  const options = regional
    ? [...LANGUAGE_OPTIONS, ...REGIONAL_LANGUAGE_OPTIONS]
    : [...LANGUAGE_OPTIONS];
  if (!current || options.some((option) => option.code === current))
    return options;
  return [
    { code: current, name: `${languageName(current)} (${current})` },
    ...options,
  ];
}

/** A folder name as a person reads it: no `_` prefix and no ID tags. */
export function displayFolderName(name: string): string {
  return name ? stripIdTags(friendlyFolderName(name)) : "";
}
