/** Audio codecs these browsers decode inside a video element. AC-3/E-AC-3,
 * DTS, TrueHD, MLP and WMA are deliberately absent: the container still plays
 * but the track is dropped without an error event, which looks like a broken
 * player rather than a codec mismatch. */
const browserAudioCodecs = new Set([
  "aac",
  "mp3",
  "mp2",
  "opus",
  "vorbis",
  "flac",
  "pcm_s16le",
  "pcm_s16be",
  "pcm_s24le",
  "pcm_s32le",
  "pcm_f32le",
  "pcm_u8",
  "pcm_mulaw",
  "pcm_alaw",
]);

/** Minimal probe shape so callers can pass the catalog's `videoProbe`. */
export type AudioTrackProbe = { audioCodecs?: string[] } | null | undefined;

/** True when the file carries no audio track the browser can decode, so the
 * player must serve its H.264/AAC conversion to get sound. A file that also
 * has a playable track is left alone: converting takes minutes and the browser
 * can already produce audio from it. */
export function audioNeedsBrowserConversion(probe: AudioTrackProbe): boolean {
  const codecs = (probe?.audioCodecs ?? []).map((codec) =>
    codec.trim().toLowerCase(),
  );
  if (codecs.length === 0) return false;
  return !codecs.some((codec) => browserAudioCodecs.has(codec));
}

/** True only when a probe positively reports a video without audio tracks. */
export function probeReportsNoAudio(probe: AudioTrackProbe): boolean {
  return Array.isArray(probe?.audioCodecs) && probe.audioCodecs.length === 0;
}

type AudioDecodeCountVideo = HTMLVideoElement & {
  webkitAudioDecodedByteCount?: number;
  mozHasAudio?: boolean;
};

/** Whether the element has actually decoded audio while playing. Browsers
 * expose this differently, and some expose nothing, hence "unknown". */
export function decodedAudioState(
  video: HTMLVideoElement,
): "decoded" | "silent" | "unknown" {
  const candidate = video as AudioDecodeCountVideo;
  if (typeof candidate.webkitAudioDecodedByteCount === "number") {
    return candidate.webkitAudioDecodedByteCount > 0 ? "decoded" : "silent";
  }
  if (typeof candidate.mozHasAudio === "boolean") {
    return candidate.mozHasAudio ? "decoded" : "silent";
  }
  return "unknown";
}
