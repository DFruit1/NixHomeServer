import type {
  RootProps,
  TvEpisodeFields,
  View,
  IntegrationRefresh,
} from "./root-types";
import { stripProviderIdTags } from "./display-names";

const YEAR_MATCHER = /\.[^.]+$/;

export function viewFromSearch(search: string): View {
  const view = new URLSearchParams(search).get("view") as View | null;
  return view && ROOT_VIEWS.has(view) ? view : "library";
}

const ROOT_VIEWS: Set<View> = new Set<View>([
  "library",
  "health",
  "conversions",
  "activity",
  "accounts",
  "refresh",
  "player",
  "videos",
  "images",
  "transcript",
]);

export function rootFromSearch(search: string): string {
  return new URLSearchParams(search).get("root") ?? "";
}

export function itemFromSearch(search: string): string {
  return new URLSearchParams(search).get("item") ?? "";
}

export function pathFromSearch(search: string): string {
  return new URLSearchParams(search).get("path") ?? "";
}

export function initialRouteFromSearch(search: string): RootProps {
  const itemId = itemFromSearch(search);
  return {
    initialView: viewFromSearch(search),
    initialRootId: rootFromSearch(search),
    ...(itemId ? { initialItemId: itemId } : {}),
    ...(pathFromSearch(search) ? { initialPath: pathFromSearch(search) } : {}),
  };
}

/** "just now", "12 min ago", "3 hr ago", then a short date and time. */
export function formatLastRun(seconds: number, now = Date.now()): string {
  const elapsed = Math.max(0, Math.round(now / 1000 - seconds));
  if (elapsed < 60) return "just now";
  if (elapsed < 3600) return `${Math.round(elapsed / 60)} min ago`;
  if (elapsed < 86_400) return `${Math.round(elapsed / 3600)} hr ago`;
  return new Intl.DateTimeFormat(undefined, {
    day: "numeric",
    month: "short",
    hour: "numeric",
    minute: "2-digit",
  }).format(new Date(seconds * 1000));
}

/** What a refresh row says. An app that has never been refreshed says
 * nothing; a finished refresh says when it last ran. */
export function refreshPresentation(
  status?: IntegrationRefresh,
  now = Date.now(),
): {
  label: string;
  detail: string;
  busy: boolean;
  tone: "idle" | "pending" | "success" | "error";
} {
  const when =
    status?.finishedAt !== undefined
      ? ` ${formatLastRun(status.finishedAt, now)}`
      : "";
  switch (status?.state) {
    case "queued":
      return {
        label: "Waiting to start…",
        detail: "",
        busy: true,
        tone: "pending",
      };
    case "running":
      return { label: "Refreshing…", detail: "", busy: true, tone: "pending" };
    case "succeeded":
      return {
        label: `Last refreshed${when}`,
        detail: "",
        busy: false,
        tone: "success",
      };
    case "failed":
      return {
        label: `Last refresh failed${when}`,
        detail: status.message ?? "",
        busy: false,
        tone: "error",
      };
    default:
      return { label: "", detail: "", busy: false, tone: "idle" };
  }
}

export function parseTvEpisodeFilename(
  filename: string,
): TvEpisodeFields | undefined {
  // Provider tags such as `[tmdbid-799]` identify the show; they are never
  // part of its title.
  const stem = stripProviderIdTags(filename.replace(YEAR_MATCHER, ""));
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
