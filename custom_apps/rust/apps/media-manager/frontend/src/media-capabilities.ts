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
