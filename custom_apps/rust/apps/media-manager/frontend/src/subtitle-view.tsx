import {
  $,
  component$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import { Icon } from "./icon";
import type {
  CatalogItem,
  MediaRoot,
  MetadataConsumer,
  MutationPreview,
  Session,
  Status,
  VideoProbe,
} from "./root-types";

interface InstalledSubtitle {
  source: "external" | "embedded";
  itemId?: string;
  relativePath?: string;
  streamIndex?: number;
  sizeBytes?: number;
  format?: string | null;
  language?: string | null;
  title?: string | null;
  isDefault: boolean;
  isForced: boolean;
  isHearingImpaired: boolean;
  isPreviewable: boolean;
}

interface InstalledSubtitleContent {
  cues: SubtitleCue[];
  truncated: boolean;
  validation: {
    cueCount: number;
    issueCount: number;
    issues: Array<{ cueIndex: number; kind: string; message: string }>;
  };
}

export const SubtitleCard = component$<{
  items: CatalogItem[];
  selectedItemId: string;
}>((props) => {
  const inspector = useStore<{
    loading: boolean;
    subtitles: InstalledSubtitle[];
    consumers: MetadataConsumer[];
    selected?: InstalledSubtitle;
    content?: InstalledSubtitleContent;
    error: string;
  }>({ loading: false, subtitles: [], consumers: [], error: "" });
  const selectedItem = props.items.find(
    (item) => item.id === props.selectedItemId,
  );
  useTask$(async ({ track }) => {
    const selectedItemId = track(() => props.selectedItemId);
    inspector.subtitles = [];
    inspector.consumers = [];
    inspector.selected = undefined;
    inspector.content = undefined;
    inspector.error = "";
    if (!selectedItemId) return;
    const item = props.items.find(
      (candidate) => candidate.id === selectedItemId,
    );
    if (item?.mediaKind !== "video") return;
    inspector.loading = true;
    try {
      const response = await api<{
        subtitles?: InstalledSubtitle[];
        consumers?: MetadataConsumer[];
      }>(`/items/${encodeURIComponent(selectedItemId)}/subtitles`);
      if (props.selectedItemId !== selectedItemId) return;
      inspector.subtitles = response.subtitles ?? [];
      inspector.consumers = response.consumers ?? [];
    } catch (error) {
      if (props.selectedItemId === selectedItemId)
        inspector.error = readableError(error);
    } finally {
      if (props.selectedItemId === selectedItemId) inspector.loading = false;
    }
  });

  const inspectContent = $(async (subtitle: InstalledSubtitle) => {
    if (!subtitle.itemId || !subtitle.isPreviewable) return;
    inspector.selected = subtitle;
    inspector.content = undefined;
    inspector.error = "";
    try {
      inspector.content = await api<InstalledSubtitleContent>(
        `/items/${encodeURIComponent(props.selectedItemId)}/subtitles/installed/${encodeURIComponent(subtitle.itemId)}/content`,
      );
    } catch (error) {
      inspector.error = readableError(error);
    }
  });

  if (!selectedItem) {
    return (
      <div class="subtitle-card-body">
        <div class="subtitle-empty">
          <Icon name="captions" size={24} />
          <span>Select a file to inspect its subtitles.</span>
        </div>
      </div>
    );
  }
  if (selectedItem.mediaKind !== "video") {
    return (
      <div class="subtitle-card-body">
        <div class="subtitle-empty">
          <Icon name="captions" size={24} />
          <span>Subtitles are only listed for video files.</span>
        </div>
      </div>
    );
  }
  return (
    <div class="subtitle-card-body installed-subtitle-inspector">
      <div class="installed-subtitle-heading">
        <div>
          <h3>Installed subtitles</h3>
          <p>
            External files and embedded streams, including flags and validation.
          </p>
        </div>
        {inspector.consumers[0]?.nativeUrl && (
          <a
            class="secondary-button"
            href={inspector.consumers[0].nativeUrl}
            target="_blank"
            rel="noreferrer"
          >
            Manage in {inspector.consumers[0].label}
          </a>
        )}
      </div>
      {inspector.error && <p class="error-copy">{inspector.error}</p>}
      {inspector.loading ? (
        <div class="subtitle-empty">
          <Icon name="refresh" size={24} />
          <span>Inspecting subtitle streams and files…</span>
        </div>
      ) : inspector.subtitles.length === 0 ? (
        <div class="subtitle-empty">
          <Icon name="captions" size={24} />
          <span>No subtitles found for this file</span>
        </div>
      ) : (
        <ul class="subtitle-list">
          {inspector.subtitles.map((subtitle, index) => {
            const filename =
              subtitle.relativePath?.split("/").at(-1) ??
              subtitle.title ??
              `Embedded stream ${subtitle.streamIndex ?? index}`;
            return (
              <li
                class="subtitle-item installed-subtitle-row"
                key={
                  subtitle.itemId ?? `stream-${subtitle.streamIndex ?? index}`
                }
              >
                <span class="subtitle-lang">
                  {(subtitle.language ?? "und").toUpperCase()}
                </span>
                <span class="subtitle-filename">
                  <strong>{filename}</strong>
                  <small>
                    {[
                      subtitle.source,
                      subtitle.format?.toUpperCase(),
                      subtitle.isDefault ? "default" : "",
                      subtitle.isForced ? "forced" : "",
                      subtitle.isHearingImpaired ? "SDH/CC" : "",
                    ]
                      .filter(Boolean)
                      .join(" · ")}
                  </small>
                </span>
                {subtitle.isPreviewable && (
                  <button
                    class="secondary-button"
                    type="button"
                    onClick$={() => inspectContent(subtitle)}
                  >
                    Inspect cues
                  </button>
                )}
              </li>
            );
          })}
        </ul>
      )}
      {inspector.content && (
        <section class="installed-subtitle-content">
          <div>
            <strong>
              {inspector.content.validation.cueCount} cues ·{" "}
              {inspector.content.validation.issueCount} issues
            </strong>
            <button
              class="close-button"
              type="button"
              aria-label="Close installed subtitle preview"
              onClick$={() => (inspector.content = undefined)}
            >
              ×
            </button>
          </div>
          {inspector.content.validation.issues.length > 0 && (
            <ul class="subtitle-validation-list">
              {inspector.content.validation.issues.map((issue) => (
                <li key={`${issue.cueIndex}-${issue.kind}`}>
                  Cue {issue.cueIndex}: {issue.message}
                </li>
              ))}
            </ul>
          )}
          <ol class="subtitle-cue-list">
            {inspector.content.cues.map((cue) => (
              <li class="subtitle-cue" key={`${cue.index}-${cue.startMs}`}>
                <time>
                  {formatCueTime(cue.startMs)} → {formatCueTime(cue.endMs)}
                </time>
                <span>{cue.text || "—"}</span>
              </li>
            ))}
          </ol>
        </section>
      )}
    </div>
  );
});

interface SubtitleMatch {
  providerId: string;
  fileId: number;
  fileName: string;
  language: string;
  release: string;
  downloadCount: number;
  fps?: number;
  votes?: number;
  uploadDate?: string;
  subFormat?: string;
  hearingImpaired: boolean;
  hashMatched: boolean;
  machineTranslated: boolean;
  aiTranslated: boolean;
  fpsCompatible?: boolean | null;
}

interface VideoSummary {
  codec?: string;
  width?: number;
  height?: number;
  fps?: number;
}

interface SubtitleSearchResponse {
  provider: string;
  query: string;
  languages: string;
  matchMethod: "movie-hash" | "title-fallback";
  results: SubtitleMatch[];
  video?: VideoProbe | null;
  videoSummary?: VideoSummary;
  requestId: string;
}

interface SubtitleCue {
  index: number;
  startMs: number;
  endMs: number;
  text: string;
}

interface SubtitleContent {
  provider: string;
  fileId: number;
  cues: SubtitleCue[];
  truncated: boolean;
  requestId: string;
}

interface BatchSubtitleResult {
  itemId: string;
  relativePath: string;
  videoSummary: VideoSummary;
  results: SubtitleMatch[];
  matchMethod: string;
}

interface SubtitleState {
  rootId: string;
  items: CatalogItem[];
  itemId: string;
  language: string;
  query: string;
  hearingImpaired: boolean;
  showWithSubtitles: boolean;
  subtitleStatus: Record<string, "none" | "sidecar" | "embedded" | "both">;
  loadingItems: boolean;
  searching: boolean;
  installing: boolean;
  confirming: boolean;
  loadingContent: boolean;
  results: SubtitleMatch[];
  video?: VideoProbe | null;
  videoSummary?: VideoSummary;
  content?: SubtitleContent;
  contentError: string;
  preview?: MutationPreview;
  error: string;
  notice: string;
  browseMode: boolean;
  browseFilter: "all" | "none" | "sidecar" | "embedded" | "both";
  batchResults: BatchSubtitleResult[];
}

type SubtitleStatus = "none" | "sidecar" | "embedded" | "both";

function subtitleStatusMap(
  items: CatalogItem[],
): Record<string, SubtitleStatus> {
  const statuses: Record<string, SubtitleStatus> = {};
  const subtitleItems = items.filter((item) => item.mediaKind === "subtitle");
  for (const item of items) {
    if (item.mediaKind !== "video") continue;
    const videoPath = item.relativePath;
    const videoStem = videoPath.replace(/\.[^/.]+$/, "");
    const hasSidecar = subtitleItems.some((subtitle) => {
      const subtitleStem = subtitle.relativePath.replace(/\.[^/.]+$/, "");
      return (
        subtitleStem === videoStem ||
        subtitleStem.startsWith(`${videoStem}.`) ||
        videoStem.startsWith(`${subtitleStem}.`)
      );
    });
    const hasEmbedded = item.videoProbe?.hasEmbeddedSubtitles === true;
    statuses[videoPath] =
      hasSidecar && hasEmbedded
        ? "both"
        : hasSidecar
          ? "sidecar"
          : hasEmbedded
            ? "embedded"
            : "none";
  }
  return statuses;
}

function subtitleStatusLabel(status: SubtitleStatus | undefined): string {
  switch (status) {
    case "sidecar":
      return " (has subtitles)";
    case "embedded":
      return " (embedded subtitles)";
    case "both":
      return " (subtitles + embedded)";
    default:
      return "";
  }
}

interface BrowseViewProps {
  items: CatalogItem[];
  subtitleStatus: Record<string, SubtitleStatus>;
  browseFilter: "all" | "none" | "sidecar" | "embedded" | "both";
  onFilterChange: (
    filter: "all" | "none" | "sidecar" | "embedded" | "both",
  ) => void;
  onVideoSelect: (itemId: string) => void;
  language: string;
  hearingImpaired: boolean;
  providerAvailable: boolean;
  session?: Session;
  status?: Status;
  loadVideos: (rootId: string) => Promise<void>;
  videoRoots: MediaRoot[];
  search: () => Promise<void>;
  selectProviderSubtitle: (match: SubtitleMatch) => Promise<void>;
  viewContent: (match: SubtitleMatch) => Promise<void>;
  adjustSubtitleTiming: (
    match: SubtitleMatch,
    videoFps: number,
  ) => Promise<void>;
  batchSearchSubtitles: (itemIds: string[]) => Promise<void>;
  batchResults: BatchSubtitleResult[];
  onBatchResultSelect: (result: BatchSubtitleResult) => void;
}

const BrowseView = component$<BrowseViewProps>((props) => {
  const videoItems = props.items.filter((item) => item.mediaKind === "video");
  const filteredItems = videoItems.filter((item) => {
    const status = props.subtitleStatus[item.relativePath] ?? "none";
    if (props.browseFilter === "all") return true;
    return status === props.browseFilter;
  });

  const counts = {
    all: videoItems.length,
    none: videoItems.filter(
      (i) => (props.subtitleStatus[i.relativePath] ?? "none") === "none",
    ).length,
    sidecar: videoItems.filter(
      (i) => (props.subtitleStatus[i.relativePath] ?? "none") === "sidecar",
    ).length,
    embedded: videoItems.filter(
      (i) => (props.subtitleStatus[i.relativePath] ?? "none") === "embedded",
    ).length,
    both: videoItems.filter(
      (i) => (props.subtitleStatus[i.relativePath] ?? "none") === "both",
    ).length,
  };

  return (
    <div class="browse-view">
      <div class="browse-toolbar">
        <div class="browse-filters"></div>
        <div class="browse-actions">
          {props.providerAvailable &&
            props.session?.canEdit &&
            filteredItems.length > 0 && (
              <button
                class="primary-button"
                type="button"
                onClick$={() =>
                  props.batchSearchSubtitles(filteredItems.map((i) => i.id))
                }
              >
                <Icon name="scan" size={16} /> Batch search subtitles (
                {filteredItems.length})
              </button>
            )}
          <button
            class={`filter-button ${props.browseFilter === "all" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("all")}
          >
            All ({counts.all})
          </button>
          <button
            class={`filter-button ${props.browseFilter === "none" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("none")}
          >
            No subtitles ({counts.none})
          </button>
          <button
            class={`filter-button ${props.browseFilter === "sidecar" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("sidecar")}
          >
            External subtitles ({counts.sidecar})
          </button>
          <button
            class={`filter-button ${props.browseFilter === "embedded" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("embedded")}
          >
            Embedded subtitles ({counts.embedded})
          </button>
          <button
            class={`filter-button ${props.browseFilter === "both" ? "active" : ""}`}
            type="button"
            onClick$={() => props.onFilterChange("both")}
          >
            Both ({counts.both})
          </button>
        </div>
      </div>

      <div class="browse-table-container">
        <table class="browse-table" role="grid">
          <thead>
            <tr>
              <th>Video</th>
              <th>Resolution</th>
              <th>Codec</th>
              <th>FPS</th>
              <th>Subtitle Status</th>
              <th>Embedded Streams</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {filteredItems.map((item) => {
              const status = props.subtitleStatus[item.relativePath] ?? "none";
              const probe = item.videoProbe;
              return (
                <tr key={item.id} class={`browse-row status-${status}`}>
                  <td class="video-name">
                    <span class="filename">
                      {item.relativePath.split("/").pop()}
                    </span>
                    <span class="path">
                      {item.relativePath.replace(/\/[^/]+$/, "")}
                    </span>
                  </td>
                  <td>
                    {probe?.width && probe?.height
                      ? `${probe.width}×${probe.height}`
                      : "—"}
                  </td>
                  <td>{probe?.codec ?? "—"}</td>
                  <td>{probe?.fps ? `${probe.fps.toFixed(3)}` : "—"}</td>
                  <td>
                    <span class={`status-badge status-${status}`}>
                      {status === "none" && "None"}
                      {status === "sidecar" && "External"}
                      {status === "embedded" && "Embedded"}
                      {status === "both" && "Both"}
                    </span>
                  </td>
                  <td>
                    {probe?.hasEmbeddedSubtitles
                      ? probe.subtitleLanguages?.length > 0
                        ? probe.subtitleLanguages.join(", ")
                        : "Yes"
                      : "None"}
                  </td>
                  <td>
                    <div class="browse-actions">
                      {props.providerAvailable && props.session?.canEdit && (
                        <button
                          class="secondary-button small"
                          type="button"
                          onClick$={() => props.onVideoSelect(item.id)}
                        >
                          <Icon name="scan" size={14} /> Search subtitles
                        </button>
                      )}
                      {!props.providerAvailable && (
                        <a
                          class="metadata-source-setup-link"
                          href="?view=accounts"
                        >
                          Set up OpenSubtitles
                        </a>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
        {filteredItems.length === 0 && (
          <div class="browse-empty">
            <Icon name="captions" size={32} />
            <p>No videos match the current filter.</p>
          </div>
        )}
      </div>
      {props.batchResults.length > 0 && (
        <section
          class="batch-subtitle-results"
          aria-label="Batch search results"
        >
          <div class="panel-heading">
            <div>
              <h4>Batch candidates</h4>
              <p class="quiet-copy">
                Review one video at a time. Exact hash matches are identified;
                no result is installed without its own preview and confirmation.
              </p>
            </div>
          </div>
          <div class="subtitle-results">
            {props.batchResults.map((result) => (
              <article class="subtitle-result" key={result.itemId}>
                <div>
                  <strong>{result.relativePath.split("/").pop()}</strong>
                  <span>
                    {result.results.length} candidates · {result.matchMethod}
                  </span>
                </div>
                <button
                  class="secondary-button"
                  type="button"
                  disabled={result.results.length === 0}
                  onClick$={() => props.onBatchResultSelect(result)}
                >
                  Review candidates
                </button>
              </article>
            ))}
          </div>
        </section>
      )}
    </div>
  );
});

export function formatCueTime(milliseconds: number): string {
  const total = Math.max(0, Math.floor(milliseconds));
  const hours = Math.floor(total / 3_600_000);
  const minutes = Math.floor((total % 3_600_000) / 60_000);
  const seconds = Math.floor((total % 60_000) / 1_000);
  const millis = total % 1_000;
  const pad = (value: number, width = 2) => String(value).padStart(width, "0");
  return `${pad(hours)}:${pad(minutes)}:${pad(seconds)},${pad(millis, 3)}`;
}

export const SubtitleView = component$<{
  roots: MediaRoot[];
  session?: Session;
  status?: Status;
}>((props) => {
  const uploadInput = useSignal<HTMLInputElement>();
  const videoRoots = props.roots.filter((root) => root.category === "videos");
  const providerAvailable =
    props.status?.integrations.some(
      (integration) =>
        integration.id === "opensubtitles" && integration.available,
    ) ?? false;
  const subtitle = useStore<SubtitleState>({
    rootId: videoRoots[0]?.id ?? "",
    items: [],
    itemId: "",
    language: "en",
    query: "",
    hearingImpaired: false,
    showWithSubtitles: false,
    subtitleStatus: {},
    loadingItems: false,
    searching: false,
    installing: false,
    confirming: false,
    loadingContent: false,
    results: [],
    video: undefined,
    contentError: "",
    error: "",
    notice: "",
    browseMode: false,
    browseFilter: "none",
    batchResults: [],
  });

  const loadVideos = $(async (rootId: string) => {
    subtitle.rootId = rootId;
    subtitle.loadingItems = true;
    subtitle.itemId = "";
    subtitle.results = [];
    subtitle.video = undefined;
    subtitle.videoSummary = undefined;
    subtitle.content = undefined;
    subtitle.error = "";
    try {
      let items: CatalogItem[] = [];
      for (let attempt = 0; attempt < 20; attempt += 1) {
        const result = await api<{
          items: CatalogItem[];
          probePending: boolean;
        }>(
          `/items?rootId=${encodeURIComponent(rootId)}&includeVideoProbes=true`,
        );
        items = result.items;
        if (!result.probePending) break;
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
      subtitle.items = items;
      subtitle.subtitleStatus = subtitleStatusMap(items);
      const firstVideo = items.find(
        (item) =>
          item.mediaKind === "video" &&
          subtitle.subtitleStatus[item.relativePath] === "none",
      );
      subtitle.itemId = firstVideo?.id ?? "";
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.loadingItems = false;
    }
  });

  useVisibleTask$(async () => {
    if (subtitle.rootId) await loadVideos(subtitle.rootId);
  });

  const search = $(async () => {
    if (!subtitle.itemId || subtitle.searching) return;
    subtitle.searching = true;
    subtitle.error = "";
    subtitle.notice = "";
    subtitle.preview = undefined;
    subtitle.content = undefined;
    subtitle.video = undefined;
    subtitle.videoSummary = undefined;
    try {
      const parameters = new URLSearchParams({ languages: subtitle.language });
      if (subtitle.query.trim()) parameters.set("query", subtitle.query.trim());
      const response = await api<SubtitleSearchResponse>(
        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/search?${parameters}`,
      );
      subtitle.results = response.results;
      subtitle.video = response.video ?? null;
      subtitle.videoSummary = response.videoSummary;
      if (response.results.length === 0) {
        subtitle.notice =
          "OpenSubtitles returned no matches for this title and language.";
      } else if (response.matchMethod === "movie-hash") {
        subtitle.notice =
          "These subtitles are exact file-hash matches and are the best candidates for synchronized timing.";
      } else {
        subtitle.notice =
          "No exact file-hash match was found, so these are title-based candidates. Check the release name before previewing.";
      }
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.searching = false;
    }
  });

  const viewContent = $(async (match: SubtitleMatch) => {
    if (!subtitle.itemId || subtitle.loadingContent) return;
    subtitle.loadingContent = true;
    subtitle.contentError = "";
    try {
      subtitle.content = await api<SubtitleContent>(
        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/provider/${match.fileId}/content`,
      );
    } catch (error) {
      subtitle.contentError = readableError(error);
    } finally {
      subtitle.loadingContent = false;
    }
  });

  const selectProviderSubtitle = $(async (match: SubtitleMatch) => {
    if (!subtitle.itemId || subtitle.installing) return;
    subtitle.installing = true;
    subtitle.error = "";
    subtitle.notice = "";
    try {
      subtitle.preview = await api<MutationPreview>(
        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/provider`,
        {
          method: "POST",
          body: JSON.stringify({
            fileId: match.fileId,
            language: match.language || subtitle.language,
            hearingImpaired: subtitle.hearingImpaired || match.hearingImpaired,
          }),
        },
      );
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.installing = false;
    }
  });

  const confirmInstall = $(async () => {
    if (!subtitle.preview || subtitle.confirming) return;
    subtitle.confirming = true;
    subtitle.error = "";
    try {
      await api(`/plans/${encodeURIComponent(subtitle.preview.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${subtitle.preview.digest}"` },
      });
      subtitle.notice =
        "The subtitle install was added to the global mutation queue.";
      subtitle.preview = undefined;
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.confirming = false;
    }
  });

  const adjustSubtitleTiming = $(
    async (match: SubtitleMatch, videoFps: number) => {
      if (!subtitle.itemId || !match.fps) return;
      subtitle.loadingContent = true;
      subtitle.contentError = "";
      try {
        subtitle.preview = await api<MutationPreview>(
          `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/adjust`,
          {
            method: "POST",
            body: JSON.stringify({
              fileId: match.fileId,
              sourceFps: match.fps,
              targetFps: videoFps,
              language: match.language || subtitle.language,
              hearingImpaired:
                subtitle.hearingImpaired || match.hearingImpaired,
            }),
          },
        );
        subtitle.notice = `Prepared a complete adjusted SRT from ${match.fps.toFixed(3)} fps to ${videoFps.toFixed(3)} fps. Review the destination, then confirm the staged sidecar.`;
      } catch (error) {
        subtitle.contentError = readableError(error);
      } finally {
        subtitle.loadingContent = false;
      }
    },
  );

  const batchSearchSubtitles = $(async (itemIds: string[]) => {
    if (itemIds.length === 0) return;
    subtitle.searching = true;
    subtitle.error = "";
    subtitle.notice = "";
    try {
      const response = await api<{
        batchResults: BatchSubtitleResult[];
        requestId: string;
      }>("/subtitles/batch-search", {
        method: "POST",
        body: JSON.stringify({
          itemIds,
          languages: subtitle.language,
        }),
      });
      subtitle.notice = `Batch search completed for ${response.batchResults.length} videos. Review each candidate set before staging an install.`;
      subtitle.batchResults = response.batchResults;
    } catch (error) {
      subtitle.error = readableError(error);
    } finally {
      subtitle.searching = false;
    }
  });

  const videoItems = subtitle.items.filter(
    (item) => item.mediaKind === "video",
  );
  const selectableVideos = subtitle.showWithSubtitles
    ? videoItems
    : videoItems.filter(
        (item) => subtitle.subtitleStatus[item.relativePath] === "none",
      );

  return (
    <section class="subtitle-layout">
      {subtitle.error && (
        <div class="message error" role="alert">
          <Icon name="alert" size={18} />
          <span>{subtitle.error}</span>
          <button type="button" onClick$={() => (subtitle.error = "")}>
            ×
          </button>
        </div>
      )}
      {subtitle.notice && (
        <div class="message success" role="status">
          <Icon name="check" size={18} />
          <span>{subtitle.notice}</span>
        </div>
      )}

      <section class="panel subtitle-controls">
        <div class="panel-heading">
          <div>
            <h3>Catalog selection</h3>
          </div>
          <span class={{ "status-badge": true, live: props.session?.canEdit }}>
            {props.session?.canEdit ? "Editor" : "Viewer"}
          </span>
        </div>
        <div class="subtitle-mode-toggle">
          <label class="mode-toggle">
            <input
              type="checkbox"
              checked={subtitle.browseMode}
              onChange$={(_, input) => (subtitle.browseMode = input.checked)}
            />
            <span>
              {subtitle.browseMode ? "Browse all videos" : "Single video mode"}
            </span>
          </label>
        </div>
        {subtitle.browseMode ? (
          <BrowseView
            items={subtitle.items}
            subtitleStatus={subtitle.subtitleStatus}
            browseFilter={subtitle.browseFilter}
            onFilterChange={(filter) => (subtitle.browseFilter = filter)}
            onVideoSelect={(itemId) => {
              subtitle.browseMode = false;
              subtitle.itemId = itemId;
              subtitle.results = [];
              subtitle.video = undefined;
              subtitle.videoSummary = undefined;
              subtitle.preview = undefined;
              subtitle.content = undefined;
            }}
            language={subtitle.language}
            hearingImpaired={subtitle.hearingImpaired}
            providerAvailable={providerAvailable}
            session={props.session}
            status={props.status}
            loadVideos={loadVideos}
            videoRoots={videoRoots}
            search={search}
            selectProviderSubtitle={selectProviderSubtitle}
            viewContent={viewContent}
            adjustSubtitleTiming={adjustSubtitleTiming}
            batchSearchSubtitles={batchSearchSubtitles}
            batchResults={subtitle.batchResults}
            onBatchResultSelect={(result) => {
              subtitle.browseMode = false;
              subtitle.itemId = result.itemId;
              subtitle.results = result.results;
              subtitle.videoSummary = result.videoSummary;
              subtitle.preview = undefined;
              subtitle.content = undefined;
              subtitle.notice = `${result.results.length} candidates loaded for review; choose one to preview or install.`;
            }}
          />
        ) : (
          <div class="subtitle-fields">
            <label>
              <span>Video library</span>
              <select
                value={subtitle.rootId}
                onChange$={(_, select) => loadVideos(select.value)}
              >
                {videoRoots.map((root) => (
                  <option value={root.id} key={root.id}>
                    {`${root.label}${root.available ? "" : " (unavailable)"}`}
                  </option>
                ))}
              </select>
            </label>
            <label class="video-select">
              <span>Cataloged video</span>
              <select
                value={subtitle.itemId}
                disabled={subtitle.loadingItems || videoItems.length === 0}
                onChange$={(_, select) => {
                  subtitle.itemId = select.value;
                  subtitle.results = [];
                  subtitle.video = undefined;
                  subtitle.preview = undefined;
                  subtitle.content = undefined;
                }}
              >
                <option value="">
                  {subtitle.loadingItems
                    ? "Loading videos…"
                    : videoItems.length === 0
                      ? "No supported videos found in this library"
                      : selectableVideos.length === 0
                        ? "No videos without subtitles in this library"
                        : "Choose a video…"}
                </option>
                {selectableVideos.map((item) => (
                  <option value={item.id} key={item.id}>
                    {`${item.relativePath}${subtitleStatusLabel(
                      subtitle.subtitleStatus[item.relativePath],
                    )}`}
                  </option>
                ))}
              </select>
            </label>
            <label class="language-field">
              <span>Language</span>
              <input
                value={subtitle.language}
                maxLength={15}
                placeholder="en"
                onInput$={(_, input) =>
                  (subtitle.language = input.value
                    .toLowerCase()
                    .replace(/[^a-z0-9-]/g, "")
                    .slice(0, 15))
                }
              />
            </label>
            <label class="checkbox-field">
              <input
                type="checkbox"
                checked={subtitle.hearingImpaired}
                onChange$={(_, input) =>
                  (subtitle.hearingImpaired = input.checked)
                }
              />
              <span>Prefer SDH / hearing-impaired naming</span>
            </label>
            <label class="checkbox-field">
              <input
                type="checkbox"
                checked={subtitle.showWithSubtitles}
                onChange$={(_, input) =>
                  (subtitle.showWithSubtitles = input.checked)
                }
              />
              <span>Show files that already have subtitles</span>
            </label>
          </div>
        )}
      </section>

      {subtitle.itemId && (
        <section class="panel subtitle-installed-panel">
          <SubtitleCard
            items={subtitle.items}
            selectedItemId={subtitle.itemId}
          />
        </section>
      )}

      <div class="subtitle-workflows">
        <section class="panel provider-panel">
          <div class="panel-heading">
            <div>
              <h3>OpenSubtitles</h3>
            </div>
            <span class={{ "status-badge": true, live: providerAvailable }}>
              {providerAvailable ? "Configured" : "Not configured"}
            </span>
          </div>
          <div class="setup-body">
            {providerAvailable ? (
              <p class="setup-ready">
                Online search is set up and working. Choose a cataloged video
                above, then search: the file hash is checked first for exact
                matches, with a title fallback.
              </p>
            ) : (
              <>
                <p class="setup-missing">
                  Your OpenSubtitles account is not set up. Subtitle uploads on
                  the right work without it. To enable search:
                </p>
                <ol class="setup-steps">
                  <li>
                    Create an account at
                    <a
                      class="text-button"
                      href="https://www.opensubtitles.com/en/signup"
                      target="_blank"
                      rel="noreferrer"
                    >
                      opensubtitles.com
                    </a>
                    .
                  </li>
                  <li>
                    Log in and create an application API key at
                    <a
                      class="text-button"
                      href="https://www.opensubtitles.com/consumers"
                      target="_blank"
                      rel="noreferrer"
                    >
                      opensubtitles.com/consumers
                    </a>
                    , selecting "OpenSubtitles REST API" as the API and noting
                    your account username and password.
                  </li>
                  <li>
                    Open <a href="?view=accounts">Metadata sources</a>, choose
                    OpenSubtitles, and paste the values at runtime. Saved values
                    cannot be viewed again, so retain the recovery copy in
                    Vaultwarden, KeePassXC, or another password manager.
                  </li>
                  <li>
                    Return here after saving. No NixOS rebuild or shared server
                    credential is required.
                  </li>
                </ol>
              </>
            )}
          </div>
          <div class="provider-search">
            <label>
              <span>
                Search title <small>optional override</small>
              </span>
              <input
                value={subtitle.query}
                maxLength={200}
                placeholder="Only used if the file hash has no match"
                onInput$={(_, input) => (subtitle.query = input.value)}
              />
            </label>
            <button
              class="primary-button"
              type="button"
              disabled={
                !providerAvailable ||
                !props.session?.canEdit ||
                !subtitle.itemId ||
                !subtitle.language ||
                subtitle.searching
              }
              onClick$={search}
            >
              <Icon name="scan" size={18} />
              {subtitle.searching ? "Searching…" : "Search matches"}
            </button>
          </div>
          <div class="subtitle-results">
            {subtitle.video && (
              <div class="video-summary-card">
                <h4>Video Information</h4>
                <div class="video-summary-grid">
                  <div class="video-summary-item">
                    <span class="label">Codec</span>
                    <span class="value">
                      {subtitle.video.codec ?? "unknown"}
                    </span>
                  </div>
                  <div class="video-summary-item">
                    <span class="label">Resolution</span>
                    <span class="value">
                      {subtitle.video.width && subtitle.video.height
                        ? `${subtitle.video.width}×${subtitle.video.height}`
                        : "unknown"}
                    </span>
                  </div>
                  <div class="video-summary-item">
                    <span class="label">Frame Rate</span>
                    <span class="value">
                      {subtitle.video.fps
                        ? `${subtitle.video.fps.toFixed(3)} fps`
                        : "unknown"}
                    </span>
                  </div>
                  <div class="video-summary-item">
                    <span class="label">Embedded Subtitles</span>
                    <span class="value">
                      {subtitle.video.hasEmbeddedSubtitles
                        ? subtitle.video.subtitleLanguages?.length > 0
                          ? subtitle.video.subtitleLanguages.join(", ")
                          : "Yes (embedded)"
                        : "None"}
                    </span>
                  </div>
                </div>
              </div>
            )}
            {subtitle.results.map((match) => (
              <article
                class={`subtitle-result ${match.fpsCompatible === false ? "fps-mismatch" : ""} ${match.fpsCompatible === true ? "fps-match" : ""}`}
                key={`${match.providerId}-${match.fileId}`}
              >
                <div class="subtitle-result-header">
                  <strong>{match.release || match.fileName}</strong>
                  <div class="subtitle-badges">
                    {match.fpsCompatible === false && (
                      <span
                        class="badge warning"
                        title="Frame rate mismatch - subtitle timing may drift"
                      >
                        <Icon name="alert" size={12} /> fps mismatch
                      </span>
                    )}
                    {match.fpsCompatible === true && (
                      <span
                        class="badge success"
                        title="Frame rate matches video"
                      >
                        <Icon name="check" size={12} /> fps match
                      </span>
                    )}
                    {match.hashMatched && (
                      <span class="badge info" title="Exact file hash match">
                        <Icon name="shield" size={12} /> exact match
                      </span>
                    )}
                    {match.hearingImpaired && (
                      <span class="badge info" title="SDH / Hearing impaired">
                        <Icon name="captions" size={12} /> SDH
                      </span>
                    )}
                    {match.machineTranslated ||
                      (match.aiTranslated && (
                        <span class="badge warning" title="Machine translated">
                          <Icon name="alert" size={12} /> auto-translated
                        </span>
                      ))}
                  </div>
                </div>
                <div class="subtitle-meta">
                  <span>{match.language.toUpperCase()}</span>
                  {match.fps && <span> · {match.fps.toFixed(3)} fps</span>}
                  {match.subFormat && (
                    <span> · {match.subFormat.toUpperCase()}</span>
                  )}
                  {match.downloadCount && (
                    <span>
                      {" "}
                      · {match.downloadCount.toLocaleString()} downloads
                    </span>
                  )}
                  {match.votes && <span> · {match.votes} votes</span>}
                  {match.uploadDate && (
                    <span>
                      {" "}
                      · {new Date(match.uploadDate).toLocaleDateString()}
                    </span>
                  )}
                </div>
                <div class="subtitle-result-actions">
                  <button
                    class="secondary-button"
                    type="button"
                    disabled={subtitle.installing}
                    onClick$={() => selectProviderSubtitle(match)}
                  >
                    Install
                  </button>
                  <button
                    class="secondary-button"
                    type="button"
                    disabled={subtitle.loadingContent}
                    onClick$={() => viewContent(match)}
                  >
                    {subtitle.loadingContent ? "Loading…" : "View content"}
                  </button>
                  {match.fpsCompatible === false && subtitle.video?.fps && (
                    <button
                      class="secondary-button"
                      type="button"
                      onClick$={() =>
                        adjustSubtitleTiming(match, subtitle.video!.fps!)
                      }
                    >
                      <Icon name="timer" size={16} /> Adjust timing
                    </button>
                  )}
                </div>
              </article>
            ))}
            {subtitle.results.length === 0 && (
              <p class="quiet-copy">
                Search results will show release names, language, accessibility,
                translation flags, and frame rate so an editor can choose the
                closest match.
              </p>
            )}
          </div>
          {subtitle.contentError && (
            <p class="quiet-copy content-error" role="alert">
              {subtitle.contentError}
            </p>
          )}
          {subtitle.content && (
            <section class="subtitle-content">
              <div class="panel-heading">
                <div>
                  <h4>Content preview</h4>
                </div>
                <button
                  class="close-button"
                  type="button"
                  aria-label="Close subtitle content preview"
                  onClick$={() => (subtitle.content = undefined)}
                >
                  ×
                </button>
              </div>
              <ol class="subtitle-cue-list">
                {subtitle.content.cues.map((cue) => (
                  <li class="subtitle-cue" key={cue.index}>
                    <time>
                      {formatCueTime(cue.startMs)} → {formatCueTime(cue.endMs)}
                    </time>
                    <span>{cue.text || "—"}</span>
                  </li>
                ))}
              </ol>
              {subtitle.content.truncated && (
                <p class="quiet-copy">
                  Only the first 40 cues are shown for this preview.
                </p>
              )}
            </section>
          )}
        </section>

        <section class="panel upload-panel">
          <div class="panel-heading">
            <div>
              <h3>Upload subtitle</h3>
            </div>
          </div>
          <div class="upload-copy">
            <div class="workflow-icon small">
              <Icon name="captions" size={24} />
            </div>
            <h4>SRT, WebVTT, or ASS</h4>
            <p>
              Files must be UTF-8 text and no larger than 10 MiB. The video is
              never remuxed or re-encoded.
            </p>
            <input
              ref={uploadInput}
              class="visually-hidden"
              type="file"
              accept=".srt,.vtt,.ass,application/x-subrip,text/vtt"
              onChange$={async (_, input) => {
                const file = input.files?.[0];
                if (!file || !subtitle.itemId || subtitle.installing) return;
                const format = file.name.split(".").at(-1)?.toLowerCase() ?? "";
                subtitle.installing = true;
                subtitle.error = "";
                subtitle.notice = "";
                try {
                  const parameters = new URLSearchParams({
                    language: subtitle.language,
                    format,
                    hearingImpaired: String(subtitle.hearingImpaired),
                  });
                  subtitle.preview = await api<MutationPreview>(
                    `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/upload?${parameters}`,
                    {
                      method: "POST",
                      headers: { "content-type": file.type || "text/plain" },
                      body: file,
                    },
                  );
                } catch (error) {
                  subtitle.error = readableError(error);
                } finally {
                  subtitle.installing = false;
                  input.value = "";
                }
              }}
            />
            <button
              class="secondary-button"
              type="button"
              disabled={
                !props.session?.canEdit ||
                !subtitle.itemId ||
                !subtitle.language ||
                subtitle.installing
              }
              onClick$={() => uploadInput.value?.click()}
            >
              <Icon name="folder" size={18} />
              {subtitle.installing ? "Preparing…" : "Choose subtitle file"}
            </button>
          </div>
        </section>
      </div>

      {subtitle.preview && (
        <section class="panel subtitle-preview">
          <div class="panel-heading">
            <div>
              <h3>Confirm sidecar destination</h3>
            </div>
            <button
              class="close-button"
              type="button"
              aria-label="Discard subtitle preview"
              onClick$={() => (subtitle.preview = undefined)}
            >
              ×
            </button>
          </div>
          <div class="subtitle-preview-body">
            <div class="destination-card">
              <Icon name="captions" size={21} />
              <span>
                <small>New sidecar</small>
                <strong>
                  {subtitle.preview.actions[0]?.destinationRelativePath}
                </strong>
              </span>
            </div>
            {subtitle.preview.warnings.map((warning) => (
              <p class="plan-warning" key={warning}>
                <Icon name="shield" size={16} /> {warning}
              </p>
            ))}
            <div class="plan-actions">
              <span>
                This preview expires in 30 minutes. The broker verifies the
                staged file and refuses to replace an existing subtitle.
              </span>
              <button
                class="primary-button"
                type="button"
                disabled={
                  props.status?.mutationMode !== "enabled" ||
                  subtitle.confirming
                }
                onClick$={confirmInstall}
              >
                <Icon name="check" size={18} />
                {subtitle.confirming ? "Queuing…" : "Confirm exact install"}
              </button>
            </div>
          </div>
        </section>
      )}
    </section>
  );
});
