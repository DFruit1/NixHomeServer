import type {
  RootProps,
  TvEpisodeFields,
  View,
  IntegrationRefresh,
} from "./root-types";

const YEAR_MATCHER = /\.[^.]+$/;

export function viewFromSearch(search: string): View {
  const view = new URLSearchParams(search).get("view") as View | null;
  return view && ROOT_VIEWS.has(view) ? view : "library";
}

const ROOT_VIEWS: Set<View> = new Set<View>([
  "library",
  "health",
  "conversions",
  "subtitles",
  "accounts",
  "refresh",
  "player",
]);

export function rootFromSearch(search: string): string {
  return new URLSearchParams(search).get("root") ?? "";
}

export function itemFromSearch(search: string): string {
  return new URLSearchParams(search).get("item") ?? "";
}

export function initialRouteFromSearch(search: string): RootProps {
  const itemId = itemFromSearch(search);
  return {
    initialView: viewFromSearch(search),
    initialRootId: rootFromSearch(search),
    ...(itemId ? { initialItemId: itemId } : {}),
  };
}

export function refreshPresentation(status?: IntegrationRefresh): {
  label: string;
  detail: string;
  action: string;
  busy: boolean;
  tone: "idle" | "pending" | "success" | "error";
} {
  switch (status?.state) {
    case "queued":
      return {
        label: "Queued",
        detail: "Waiting for the refresh adapter to start.",
        action: "Queued",
        busy: true,
        tone: "pending",
      };
    case "running":
      return {
        label: "Refreshing…",
        detail: "The application is scanning its registered libraries.",
        action: "Working…",
        busy: true,
        tone: "pending",
      };
    case "succeeded":
      return {
        label: "Succeeded",
        detail: status.message ?? "The refresh completed successfully.",
        action: "Refresh again",
        busy: false,
        tone: "success",
      };
    case "failed":
      return {
        label: "Failed",
        detail: status.message ?? "The refresh did not complete.",
        action: "Retry",
        busy: false,
        tone: "error",
      };
    default:
      return {
        label: "Ready",
        detail: "No refresh is currently running.",
        action: "Refresh",
        busy: false,
        tone: "idle",
      };
  }
}

export function parseTvEpisodeFilename(
  filename: string,
): TvEpisodeFields | undefined {
  const stem = filename.replace(YEAR_MATCHER, "");
  const match = stem.match(
    /^(.*?)\s*(?:-\s*)?[Ss]([0-9]{1,3})[Ee]([0-9]{1,4})(?:\s*-\s*|\s+)?(.*)$/,
  );
  if (!match) return undefined;

  const series = match[1]
    .trim()
    .replace(/\s*-\s*$/, "")
    .trim();
  const seriesWithYear = series.match(/^(.*?)\s+\(([0-9]{4})\)$/);
  return {
    title: seriesWithYear?.[1].trim() ?? series,
    year: seriesWithYear?.[2] ?? "",
    season: match[2],
    episode: match[3],
    episodeTitle: match[4].trim().replace(/^-\s*/, ""),
  };
}
