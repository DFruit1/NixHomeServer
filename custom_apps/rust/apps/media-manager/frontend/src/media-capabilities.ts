import type { MediaKindProfile, Status } from "./api-contract.generated";

export type MediaAction = MediaKindProfile["actions"][number];

export function mediaKindProfile(
  status: Status | undefined,
  kind: string | undefined,
): MediaKindProfile | undefined {
  if (!kind) return undefined;
  return status?.mediaKinds.find((profile) => profile.kind === kind);
}

export function supportsMediaAction(
  status: Status | undefined,
  kind: string | undefined,
  action: MediaAction,
): boolean {
  return Boolean(mediaKindProfile(status, kind)?.actions.includes(action));
}

/**
 * Whether the kind is curated as a browsable, editable library item rather than
 * being a companion file (artwork, subtitle) or an uncatalogued container.
 */
export function isLibraryKind(
  status: Status | undefined,
  kind: string | undefined,
): boolean {
  const profile = mediaKindProfile(status, kind);
  return Boolean(
    profile &&
      profile.curationUnit !== "companion" &&
      profile.curationUnit !== "container",
  );
}

/**
 * Maps the editor's `mediaType` label to the catalog media kind it belongs to.
 * The metadata response carries `mediaKind`, but the editor renders before it
 * loads, so this keeps capability gating stable in the meantime.
 */
export function mediaKindForMediaType(
  mediaType: string | undefined,
): string | undefined {
  switch (mediaType) {
    case "movie":
    case "series":
    case "season":
    case "episode":
      return "video";
    case "music":
      return "music";
    case "audiobook":
      return "audiobook";
    case "podcast":
      return "podcast";
    case "book":
      return "book";
    default:
      return undefined;
  }
}

const MEDIA_TYPE_LABELS: Record<string, string> = {
  movie: "Movie",
  collection: "Collection",
  series: "TV series",
  season: "TV season",
  episode: "TV episode",
  music: "Music",
  audiobook: "Audiobook",
  podcast: "Podcast",
  book: "Book",
};

/**
 * Media types a person can plausibly pick for a file of this catalog kind:
 * a video file is a movie or a TV episode, an audio file is music, an
 * audiobook or a podcast, and a document is a book. The current value always
 * stays selectable, and an unknown kind offers every type.
 */
export function mediaTypeOptions(
  mediaKind: string | undefined,
  current: string,
): Array<{ value: string; label: string }> {
  const plausible =
    mediaKind === "video"
      ? ["movie", "episode"]
      : mediaKind === "music" ||
          mediaKind === "audiobook" ||
          mediaKind === "podcast"
        ? ["music", "audiobook", "podcast"]
        : mediaKind === "book"
          ? ["book"]
          : Object.keys(MEDIA_TYPE_LABELS);
  const values = plausible.includes(current)
    ? plausible
    : [current, ...plausible];
  return Object.keys(MEDIA_TYPE_LABELS)
    .filter((value) => values.includes(value))
    .concat(values.filter((value) => !(value in MEDIA_TYPE_LABELS)))
    .map((value) => ({ value, label: MEDIA_TYPE_LABELS[value] ?? value }));
}
