import type { TrackOrderFileRow } from "./api-contract.generated";

export type TrackSequenceOrder =
  | "recommended"
  | "metadata"
  | "filename"
  | "playlist"
  | "custom";

export function hasCompleteTrackMetadata(files: TrackOrderFileRow[]): boolean {
  return (
    files.length > 0 &&
    files.every((file) => file.tagTrack != null && file.tagTrack > 0) &&
    new Set(files.map((file) => `${file.tagDisc ?? 1}:${file.tagTrack}`))
      .size === files.length
  );
}

export function hasCompletePlaylist(files: TrackOrderFileRow[]): boolean {
  return (
    files.length > 0 &&
    files.every((file) => file.playlistPosition != null) &&
    new Set(files.map((file) => file.playlistPosition)).size === files.length
  );
}

export function recommendedTrackOrder(files: TrackOrderFileRow[]) {
  if (hasCompleteTrackMetadata(files))
    return {
      source: "metadata" as const,
      reason:
        "Every file has a distinct disc/track tag. Use those tags to set the order.",
    };
  if (hasCompletePlaylist(files))
    return {
      source: "playlist" as const,
      reason: "The playlist includes every file once. Use its play order.",
    };
  return {
    source: "filename" as const,
    reason:
      "No complete, unique metadata or playlist order is available. Sort filenames naturally; check the list before writing.",
  };
}

export function sortTrackSequence(
  files: TrackOrderFileRow[],
  order: TrackSequenceOrder,
): TrackOrderFileRow[] {
  const source =
    order === "recommended" ? recommendedTrackOrder(files).source : order;
  if (source === "custom") return [...files];
  return [...files].sort((a, b) => {
    const byName = () =>
      a.fileName.localeCompare(b.fileName, undefined, { numeric: true });
    if (source === "metadata")
      return (
        (a.tagDisc ?? 1) - (b.tagDisc ?? 1) ||
        (a.tagTrack ?? Infinity) - (b.tagTrack ?? Infinity) ||
        byName()
      );
    if (source === "playlist")
      return (
        (a.playlistPosition ?? Infinity) - (b.playlistPosition ?? Infinity) ||
        byName()
      );
    return byName();
  });
}
