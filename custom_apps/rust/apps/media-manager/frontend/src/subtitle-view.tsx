import { ProviderUsageGuide } from "./provider-setup-guide";
import type {
  InstalledSubtitle,
  InstalledSubtitleContent,
  SubtitleMatch,
  VideoSummary,
  SubtitleSearchResponse,
  SubtitleCue,
  SubtitleContent,
  BatchSubtitleResult,
  InstalledSubtitlesResponse,
  TranscriptionEnvelope,
} from "./api-contract.generated";
import {
  $,
  component$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, catalogItems, readableError } from "./api";
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
      const response = await api<InstalledSubtitlesResponse>(
        `/items/${encodeURIComponent(selectedItemId)}/subtitles`,
      );
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
      <p class="subtitle-empty">Select a file to inspect its subtitles.</p>
    );
  }
  if (selectedItem.mediaKind !== "video") {
    return (
      <p class="subtitle-empty">Subtitles are only listed for video files.</p>
    );
  }
  return (
    <section class="subtitle-section installed-subtitle-inspector">
      <div class="subtitle-section-heading">
        <h3>Installed subtitles</h3>
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
        <p class="subtitle-empty">Loading subtitles…</p>
      ) : inspector.subtitles.length === 0 ? (
        <p class="subtitle-empty">No subtitles found for this file.</p>
      ) : (
        <ul class="subtitle-list">
          {inspector.subtitles.map((subtitle, index) => {
            const filename =
              subtitle.relativePath?.split("/").at(-1) ??
              subtitle.title ??
              `Embedded stream ${subtitle.streamIndex ?? index}`;
            return (
              <li
                class="subtitle-item"
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
        <section class="subtitle-content">
          <div class="subtitle-content-heading">
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
    </section>
  );
});

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
        subtitleStem === videoStem || subtitleStem.startsWith(`${videoStem}.`)
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
                      ? (probe.subtitleLanguages?.length ?? 0) > 0
                        ? (probe.subtitleLanguages ?? []).join(", ")
                        : "Yes"
                      : "None"}
                  </td>
                  <td>
                    <div class="browse-actions">
                      {props.providerAvailable && props.session?.canEdit && (
                        <button
                          class="secondary-button"
                          type="button"
                          onClick$={() => props.onVideoSelect(item.id)}
                        >
                          <Icon name="scan" size={14} /> Search subtitles
                        </button>
                      )}
                      {!props.providerAvailable && (
                        <a class="source-setup-link" href="?view=accounts">
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
          <div class="source-results">
            {props.batchResults.map((result) => (
              <article class="source-result" key={result.itemId}>
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
  item?: CatalogItem;
  session?: Session;
  status?: Status;
}>((props) => {
  const uploadInput = useSignal<HTMLInputElement>();
  const transcriptPreview = useSignal<HTMLElement>();
  const transcriptError = useSignal("");
  const transcripts = useSignal<TranscriptionEnvelope>();
  const selectedTranscript = useSignal("");
  useTask$(async ({ track }) => {
    const available = track(() =>
      props.status?.integrations.some(
        (i) => i.id === "transcribe" && i.available,
      ),
    );
    if (!available) return;
    try {
      transcripts.value = await api<TranscriptionEnvelope>("/transcriptions");
    } catch {
      transcripts.value = undefined;
    }
  });
  const videoRoots = props.roots.filter((root) => root.category === "videos");
  const providerAvailable =
    props.status?.integrations.some(
      (integration) =>
        integration.id === "opensubtitles" && integration.available,
    ) ?? false;
  const subtitle = useStore<SubtitleState>({
    rootId: props.item?.rootId ?? videoRoots[0]?.id ?? "",
    items: props.item ? [props.item] : [],
    itemId: props.item?.id ?? "",
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

  const loadGeneration = useSignal(0);
  const loadVideos = $(async (rootId: string) => {
    const generation = ++loadGeneration.value;
    const current = () => generation === loadGeneration.value;
    subtitle.rootId = rootId;
    subtitle.loadingItems = true;
    subtitle.itemId = "";
    subtitle.results = [];
    subtitle.video = undefined;
    subtitle.videoSummary = undefined;
    subtitle.content = undefined;
    subtitle.error = "";
    try {
      for (let attempt = 0; current(); attempt += 1) {
        if (!current()) return;
        const result = await catalogItems(rootId, current, true);
        if (!current()) return;
        subtitle.items = result.items;
        subtitle.subtitleStatus = subtitleStatusMap(result.items);
        subtitle.loadingItems = false;
        if (!subtitle.itemId) {
          const firstVideo = result.items.find(
            (item) =>
              item.mediaKind === "video" &&
              subtitle.subtitleStatus[item.relativePath] === "none",
          );
          subtitle.itemId = firstVideo?.id ?? "";
        }
        if (!result.probePending) break;
        const delay = Math.min(1000 * 2 ** Math.min(attempt, 4), 15000);
        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    } catch (error) {
      if (current()) subtitle.error = readableError(error);
    } finally {
      if (current()) subtitle.loadingItems = false;
    }
  });

  useVisibleTask$(({ cleanup }) => {
    cleanup(() => {
      loadGeneration.value++;
    });
    if (!props.item && subtitle.rootId) void loadVideos(subtitle.rootId);
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
          "Exact file matches found; their timing should line up.";
      } else {
        subtitle.notice =
          "No exact file match. These are title matches; check the release name.";
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
      subtitle.notice = "The subtitle installation was queued.";
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
    <section
      class={{
        "subtitle-layout": true,
        "subtitle-layout--embedded": Boolean(props.item),
      }}
    >
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

      {!props.item && (
        <section class="subtitle-controls">
          <>
            <div class="panel-heading">
              <div>
                <h3>Catalog selection</h3>
              </div>
              <span
                class={{ "status-badge": true, live: props.session?.canEdit }}
              >
                {props.session?.canEdit ? "Editor" : "Viewer"}
              </span>
            </div>
            <div class="subtitle-mode-toggle">
              <label class="mode-toggle">
                <input
                  type="checkbox"
                  checked={subtitle.browseMode}
                  onChange$={(_, input) =>
                    (subtitle.browseMode = input.checked)
                  }
                />
                <span>
                  {subtitle.browseMode
                    ? "Browse all videos"
                    : "Single video mode"}
                </span>
              </label>
            </div>
          </>
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
              {!props.item && (
                <>
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
                      disabled={
                        subtitle.loadingItems || videoItems.length === 0
                      }
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
                </>
              )}
              {!props.item && (
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
              )}
            </div>
          )}
        </section>
      )}

      {subtitle.itemId && !subtitle.browseMode && (
        <SubtitleCard items={subtitle.items} selectedItemId={subtitle.itemId} />
      )}

      {!subtitle.browseMode && (
        <section class="subtitle-section subtitle-add">
          <h3>Add subtitles</h3>
          <div class="subtitle-options">
            <label class="source-search-short">
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
          </div>

          <div class="subtitle-group">
            <h4>OpenSubtitles</h4>
            {providerAvailable ? (
              <div class="source-search">
                <label>
                  <span>Title</span>
                  <input
                    value={subtitle.query}
                    maxLength={200}
                    placeholder="Used if the file hash has no match"
                    onInput$={(_, input) => (subtitle.query = input.value)}
                  />
                </label>
                <button
                  class="primary-button"
                  type="button"
                  disabled={
                    !props.session?.canEdit ||
                    !subtitle.itemId ||
                    !subtitle.language ||
                    subtitle.searching
                  }
                  onClick$={search}
                >
                  {subtitle.searching ? "Searching…" : "Search"}
                </button>
              </div>
            ) : (
              <p class="subtitle-setup-note">
                OpenSubtitles isn't set up.{" "}
                <a href="?view=accounts">Set up in Metadata sources</a>
              </p>
            )}
            {subtitle.video && (
              <p class="subtitle-video-facts">
                {[
                  subtitle.video.codec ?? "unknown codec",
                  subtitle.video.width && subtitle.video.height
                    ? `${subtitle.video.width}×${subtitle.video.height}`
                    : "",
                  subtitle.video.fps
                    ? `${subtitle.video.fps.toFixed(3)} fps`
                    : "",
                  subtitle.video.hasEmbeddedSubtitles
                    ? `embedded subtitles${
                        (subtitle.video.subtitleLanguages?.length ?? 0) > 0
                          ? `: ${(subtitle.video.subtitleLanguages ?? []).join(", ")}`
                          : ""
                      }`
                    : "no embedded subtitles",
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </p>
            )}
            {subtitle.results.length > 0 && (
              <div class="source-results">
                {subtitle.results.map((match) => (
                  <article
                    class="source-result subtitle-match"
                    key={`${match.providerId}-${match.fileId}`}
                  >
                    <div>
                      <strong>{match.release || match.fileName}</strong>
                      <span>
                        {[
                          match.language.toUpperCase(),
                          match.fps ? `${match.fps.toFixed(3)} fps` : "",
                          match.subFormat?.toUpperCase() ?? "",
                          match.downloadCount
                            ? `${match.downloadCount.toLocaleString()} downloads`
                            : "",
                          match.votes ? `${match.votes} votes` : "",
                          match.uploadDate
                            ? new Date(match.uploadDate).toLocaleDateString()
                            : "",
                        ]
                          .filter(Boolean)
                          .join(" · ")}
                      </span>
                      <span class="subtitle-flags">
                        {match.hashMatched && (
                          <span
                            class="subtitle-flag"
                            title="Exact file hash match"
                          >
                            Exact match
                          </span>
                        )}
                        {match.fpsCompatible === true && (
                          <span
                            class="subtitle-flag"
                            title="Frame rate matches video"
                          >
                            Frame rate matches
                          </span>
                        )}
                        {match.fpsCompatible === false && (
                          <span
                            class="subtitle-flag warning"
                            title="Frame rate mismatch - subtitle timing may drift"
                          >
                            Frame rate differs
                          </span>
                        )}
                        {match.hearingImpaired && (
                          <span
                            class="subtitle-flag"
                            title="SDH / Hearing impaired"
                          >
                            SDH
                          </span>
                        )}
                        {(match.machineTranslated || match.aiTranslated) && (
                          <span
                            class="subtitle-flag warning"
                            title="Machine translated"
                          >
                            Auto-translated
                          </span>
                        )}
                      </span>
                    </div>
                    <div class="source-result-actions">
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
                          Adjust timing
                        </button>
                      )}
                    </div>
                  </article>
                ))}
              </div>
            )}
            {subtitle.contentError && (
              <p class="error-copy" role="alert">
                {subtitle.contentError}
              </p>
            )}
            {subtitle.content && (
              <section class="subtitle-content">
                <div class="subtitle-content-heading">
                  <strong>Content preview</strong>
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
                        {formatCueTime(cue.startMs)} →{" "}
                        {formatCueTime(cue.endMs)}
                      </time>
                      <span>{cue.text || "—"}</span>
                    </li>
                  ))}
                </ol>
                {subtitle.content.truncated && (
                  <p class="quiet-copy">Showing the first 40 cues.</p>
                )}
              </section>
            )}
            {providerAvailable && (
              <ProviderUsageGuide providerId="opensubtitles" />
            )}
          </div>

          <div class="subtitle-group subtitle-upload">
            {!!transcripts.value?.jobs.some(
              (job) =>
                job.state === "completed" &&
                job.artifacts?.some(
                  (f) => f.endsWith(".srt") || f.endsWith(".vtt"),
                ),
            ) && (
              <div class="transcript-picker">
                <label for="transcript-selection">Use a transcript</label>
                <select
                  id="transcript-selection"
                  value={selectedTranscript.value}
                  onChange$={(_, element) =>
                    (selectedTranscript.value = element.value)
                  }
                >
                  <option value="">Choose subtitles</option>
                  {transcripts.value.jobs
                    .filter((job) => job.state === "completed")
                    .flatMap((job) =>
                      (job.artifacts ?? [])
                        .filter(
                          (file) =>
                            file.endsWith(".srt") || file.endsWith(".vtt"),
                        )
                        .map((file) => (
                          <option
                            key={`${job.id}/${file}`}
                            value={`${job.id}/${file}`}
                          >
                            {`${job.name} · ${job.backend} · ${file}`}
                          </option>
                        )),
                    )}
                </select>
                <button
                  class="secondary-button"
                  type="button"
                  disabled={
                    !props.session?.canEdit ||
                    !subtitle.itemId ||
                    !subtitle.language ||
                    !selectedTranscript.value ||
                    subtitle.installing
                  }
                  onClick$={async () => {
                    subtitle.installing = true;
                    subtitle.error = "";
                    subtitle.notice = "";
                    transcriptError.value = "";
                    try {
                      const [jobId, artifact] =
                        selectedTranscript.value.split("/");
                      subtitle.preview = await api<MutationPreview>(
                        `/items/${encodeURIComponent(subtitle.itemId)}/subtitles/transcript`,
                        {
                          method: "POST",
                          body: JSON.stringify({
                            jobId,
                            artifact,
                            language: subtitle.language,
                          }),
                        },
                      );
                      await new Promise<void>((resolve) =>
                        requestAnimationFrame(() => resolve()),
                      );
                      transcriptPreview.value?.scrollIntoView({
                        block: "nearest",
                      });
                      transcriptPreview.value?.focus({ preventScroll: true });
                    } catch (error) {
                      transcriptError.value = readableError(error);
                    } finally {
                      subtitle.installing = false;
                    }
                  }}
                >
                  Preview transcript installation
                </button>
                {transcriptError.value && (
                  <p class="message error" role="alert">
                    {transcriptError.value}
                  </p>
                )}
              </div>
            )}
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
              {subtitle.installing ? "Preparing…" : "Upload subtitle file"}
            </button>
            <p class="subtitle-formats">SRT, WebVTT or ASS.</p>
          </div>
        </section>
      )}

      {subtitle.preview && (
        <section
          class="subtitle-section subtitle-preview"
          ref={transcriptPreview}
          tabIndex={-1}
        >
          <div class="subtitle-section-heading">
            <h3>Confirm subtitle file</h3>
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
                <small>New subtitle file</small>
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
                This preview expires in 30 minutes. An existing subtitle is
                never replaced.
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
