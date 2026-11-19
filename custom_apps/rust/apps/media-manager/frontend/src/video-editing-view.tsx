import {
  $,
  component$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, catalogItems, readableError } from "./api";
import type {
  ConversionInputAccepted,
  ConversionInputs,
  ImmichAlbumList,
  VideoClip,
  VideoConversionFormatId,
  VideoConversionJob,
  VideoConversionList,
  VideoConversionQueued,
} from "./api-contract.generated";
import { displayVideoTitleFromFileName } from "./display-names";
import { Icon } from "./icon";
import { MediaCopy } from "./media-copy";
import type { CatalogItem, MediaRoot, Session, Status } from "./root-types";
import { thumbnailSizes, thumbnailSrc, thumbnailSrcset } from "./thumbnail";
import { FORMAT_COPY } from "./video-conversions";
import { SubtitleView } from "./subtitle-view";
import "./video-editing.css";

type EditFormat = Exclude<VideoConversionFormatId, "audio-mp3">;

const EDIT_FORMATS: EditFormat[] = [
  "compatible-mp4",
  "compatible-mkv",
  "efficient-hevc",
  "modern-av1",
];

const EDIT_EXTENSION: Record<EditFormat, string> = {
  "compatible-mp4": "mp4",
  "compatible-mkv": "mkv",
  "efficient-hevc": "mkv",
  "modern-av1": "mkv",
};

const ACTIVE_STATES = new Set(["queued", "encoding", "installing"]);
const CLIP_MAX_SECONDS = 30;

function fileName(path: string): string {
  return path.split("/").at(-1) ?? path;
}

function fileStem(path: string): string {
  const name = fileName(path);
  return name.replace(/\.[^.]+$/, "");
}

function copyName(item: CatalogItem, format: EditFormat): string {
  return `${fileStem(item.relativePath)} (edited).${EDIT_EXTENSION[format]}`;
}

function clockTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00";
  const whole = Math.floor(seconds);
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`;
}

function jobState(job: VideoConversionJob): string {
  switch (job.state) {
    case "queued":
      return "Waiting to start";
    case "encoding":
      return "Saving a copy";
    case "installing":
      return "Finishing the copy";
    case "completed":
      return job.outputRelativePath
        ? `Saved as ${fileName(job.outputRelativePath)}`
        : "Saved";
    case "cancelled":
      return "Cancelled";
    default:
      return job.error || "The copy could not be saved.";
  }
}

/**
 * The per-video editing workspace. Every action here writes a new artifact
 * (or a sidecar); the selected original is never replaced or archived.
 */
export const VideoEditingView = component$<{
  roots: MediaRoot[];
  initialItemId?: string;
  immichUrl?: string;
  session?: Session;
  status?: Status;
}>((props) => {
  const videoRef = useSignal<HTMLVideoElement>();
  const jobRefresh = useSignal(0);
  const state = useStore({
    items: [] as CatalogItem[],
    selected: undefined as CatalogItem | undefined,
    query: "",
    loading: true,
    error: "",
    start: 0,
    end: 0,
    duration: 0,
    format: "compatible-mp4" as EditFormat,
    outputName: "",
    saving: false,
    notice: "",
    actionError: "",
    jobs: [] as VideoConversionJob[],
    conversionRoots: [] as ConversionInputs["roots"],
    conversionAvailable: false,
    transcriptBackend: "parakeet" as "parakeet" | "whisper",
    transcriptDiarize: false,
    transcriptCleanup: true,
    transcriptBusy: false,
    transcriptNotice: "",
    transcriptError: "",
    subtitleKey: 0,
    gifStart: 0,
    gifSeconds: 5,
    gifAlbums: [] as ImmichAlbumList["albums"],
    gifAlbumId: "",
    gifAlbumName: "GIF",
    gifBusy: false,
    gifNotice: "",
    gifError: "",
  });

  const chooseVideo = $((item: CatalogItem) => {
    if (state.selected?.id === item.id) return;
    state.selected = item;
    state.start = 0;
    state.end = 0;
    state.duration = 0;
    state.outputName = copyName(item, state.format);
    state.notice = "";
    state.actionError = "";
    state.jobs = [];
    state.gifStart = 0;
    state.gifNotice = "";
    state.gifError = "";
    state.transcriptNotice = "";
    state.transcriptError = "";
  });

  const loadItems = $(async () => {
    state.loading = true;
    state.error = "";
    try {
      const roots = props.roots.filter(
        (root) => root.category === "videos" && root.available,
      );
      const results = await Promise.all(
        roots.map((root) => catalogItems(root.id, () => true, false)),
      );
      const items = results
        .flatMap((result) => result.items)
        .filter((item) => item.mediaKind === "video")
        .sort((a, b) => a.relativePath.localeCompare(b.relativePath));
      if (
        props.initialItemId &&
        !items.some((item) => item.id === props.initialItemId)
      ) {
        try {
          const item = await api<CatalogItem>(
            `/items/${encodeURIComponent(props.initialItemId)}`,
          );
          if (item.mediaKind === "video") items.unshift(item);
        } catch {
          // The linked video may have moved or been removed.
        }
      }
      state.items = items;
      const selected =
        (state.selected &&
          items.find((item) => item.id === state.selected?.id)) ??
        items.find((item) => item.id === props.initialItemId) ??
        items[0];
      if (selected) await chooseVideo(selected);
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.loading = false;
    }
  });

  useTask$(async ({ track }) => {
    track(() => props.initialItemId);
    track(() =>
      props.roots
        .map((root) => `${root.id}:${root.available}:${root.category}`)
        .join("|"),
    );
    await loadItems();
  });

  useTask$(async () => {
    try {
      const inputs = await api<ConversionInputs>("/conversions/jobs");
      state.conversionRoots = inputs.roots;
      state.conversionAvailable = inputs.canSubmit;
    } catch {
      // The transcript form explains that its folders are unavailable.
    }
  });

  useTask$(async () => {
    if (!props.immichUrl) return;
    try {
      const payload = await api<ImmichAlbumList>(
        "/provider-lookups/immich/albums",
      );
      state.gifAlbums = payload.albums;
      const gif = payload.albums.find(
        (album) => album.name.trim().toLowerCase() === "gif",
      );
      if (gif) {
        state.gifAlbumId = gif.id;
        state.gifAlbumName = gif.name;
      }
    } catch (error) {
      // A missing album list must not block the default GIF album.
      state.gifError = readableError(error);
    }
  });

  useVisibleTask$(({ track, cleanup }) => {
    const itemId = track(() => state.selected?.id ?? "");
    track(() => jobRefresh.value);
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      if (stopped || !itemId) return;
      try {
        const list = await api<VideoConversionList>(
          "/video-conversions?jobsOnly=true",
        );
        if (stopped || (state.selected?.id ?? "") !== itemId) return;
        state.jobs = list.jobs.filter((job) => job.itemId === itemId);
        if (state.jobs.some((job) => ACTIVE_STATES.has(job.state)))
          timer = setTimeout(tick, 5000);
      } catch (error) {
        if (!stopped) state.actionError = readableError(error);
      }
    };
    void tick();
    cleanup(() => {
      stopped = true;
      clearTimeout(timer);
    });
  });

  const chooseFormat = $((value: string) => {
    const format = value as EditFormat;
    if (!EDIT_FORMATS.includes(format)) return;
    const previous = `.${EDIT_EXTENSION[state.format]}`;
    state.format = format;
    if (state.selected && state.outputName.endsWith(previous)) {
      state.outputName =
        state.outputName.slice(0, -previous.length) +
        `.${EDIT_EXTENSION[format]}`;
    }
  });

  const setFromPlayback = $((which: "start" | "end") => {
    const video = videoRef.value;
    const at = Math.max(0, Math.round((video?.currentTime ?? 0) * 10) / 10);
    if (which === "start") {
      state.start = at;
      if (state.end > 0 && state.end <= state.start)
        state.end = Math.min(state.duration, state.start + 1);
      return;
    }
    state.end = state.duration > 0 ? Math.min(at, state.duration) : at;
    if (state.end <= state.start) state.end = state.start + 1;
  });

  const saveCopy = $(async () => {
    const item = state.selected;
    if (!item || state.saving) return;
    state.notice = "";
    state.actionError = "";
    const duration =
      state.duration > 0
        ? state.duration
        : Number.isFinite(videoRef.value?.duration)
          ? videoRef.value!.duration
          : 0;
    const end = state.end > 0 ? state.end : duration;
    if (!state.outputName.trim()) {
      state.actionError = "Choose a name for the copy.";
      return;
    }
    if (!Number.isFinite(state.start) || state.start < 0) {
      state.actionError = "Choose a valid start time.";
      return;
    }
    const trimmed =
      state.start > 0.05 || (duration > 0 && end > 0 && end < duration - 0.05);
    if (trimmed && (!(end > 0) || end - state.start < 1)) {
      state.actionError =
        "Choose an end time at least one second after the start.";
      return;
    }
    state.saving = true;
    try {
      const body: Record<string, unknown> = {
        itemIds: [item.id],
        format: state.format,
        mode: "copy",
        outputName: state.outputName.trim(),
      };
      if (trimmed) {
        body.trimStartSeconds = state.start;
        body.trimEndSeconds = end;
      }
      const result = await api<VideoConversionQueued>("/video-conversions", {
        method: "POST",
        body: JSON.stringify(body),
      });
      if (result.jobs.length) {
        state.notice = `Saving ${state.outputName.trim()} beside the original.`;
        state.jobs = [...result.jobs, ...state.jobs];
        jobRefresh.value++;
      } else {
        state.actionError =
          result.skipped.map((skip) => skip.reason).join(" ") ||
          "The copy could not be queued.";
      }
    } catch (error) {
      state.actionError = readableError(error);
    } finally {
      state.saving = false;
    }
  });

  const createGif = $(async () => {
    const item = state.selected;
    if (!item || state.gifBusy) return;
    const seconds = Math.min(
      CLIP_MAX_SECONDS,
      Math.max(1, Math.floor(state.gifSeconds)),
    );
    state.gifSeconds = seconds;
    const start = Math.max(0, state.gifStart);
    state.gifBusy = true;
    state.gifNotice = "";
    state.gifError = "";
    try {
      const created = await api<VideoClip>(
        `/items/${encodeURIComponent(item.id)}/clips`,
        {
          method: "POST",
          body: JSON.stringify({
            startSeconds: start,
            durationSeconds: seconds,
            albumId: state.gifAlbumId || null,
            albumName: state.gifAlbumName || "GIF",
          }),
        },
        180_000,
      );
      state.gifNotice = `GIF saved to ${created.albumName}.`;
    } catch (error) {
      state.gifError = readableError(error);
    } finally {
      state.gifBusy = false;
    }
  });

  const queueTranscript = $(async () => {
    const item = state.selected;
    if (!item || state.transcriptBusy) return;
    const root = state.conversionRoots.find(
      (entry) => entry.id === item.rootId,
    );
    if (!root) {
      state.transcriptError =
        "This video's library is not available for transcripts.";
      return;
    }
    state.transcriptBusy = true;
    state.transcriptNotice = "";
    state.transcriptError = "";
    try {
      await api<ConversionInputAccepted>("/conversions/jobs", {
        method: "POST",
        body: JSON.stringify({
          serverPath: `${root.path.replace(/\/+$/, "")}/${item.relativePath}`,
          options: {
            name: fileName(item.relativePath),
            kind: "transcription",
            backend: state.transcriptBackend,
            diarize: state.transcriptDiarize,
            cleanup: state.transcriptCleanup,
            language: null,
            storageRootId: null,
            storageFolder: "",
          },
        }),
      });
      state.transcriptNotice =
        "Transcript queued. When it finishes, refresh the transcript choices below.";
    } catch (error) {
      state.transcriptError = readableError(error);
    } finally {
      state.transcriptBusy = false;
    }
  });

  const transcriptionAvailable = () =>
    props.status?.integrations.some(
      (integration) => integration.id === "transcribe" && integration.available,
    ) ?? false;
  const canEdit = () => props.session?.canEdit ?? false;
  const query = state.query.trim().toLowerCase();
  const visibleItems = query
    ? state.items.filter(
        (item) =>
          item.relativePath.toLowerCase().includes(query) ||
          displayVideoTitleFromFileName(fileName(item.relativePath))
            .toLowerCase()
            .includes(query),
      )
    : state.items;
  const selected = () => state.selected;
  const selectedTitle = () =>
    selected()
      ? displayVideoTitleFromFileName(fileName(selected()!.relativePath))
      : "";
  const selectedRootPath = () => {
    const item = selected();
    if (!item) return "";
    return (
      state.conversionRoots.find((root) => root.id === item.rootId)?.path ?? ""
    );
  };

  return (
    <section class="video-editing-page" aria-label="Video editing">
      <aside class="video-edit-picker" aria-label="Videos to edit">
        <label class="video-library-filter">
          <span class="sr-only">Filter videos by title or folder</span>
          <input
            type="search"
            placeholder="Filter videos"
            value={state.query}
            onInput$={(_, element) => (state.query = element.value)}
          />
        </label>
        {state.loading ? (
          <p class="video-library-empty">Loading videos…</p>
        ) : state.error ? (
          <p class="message error video-library-error" role="alert">
            {state.error}
          </p>
        ) : visibleItems.length === 0 ? (
          <p class="video-library-empty">No videos found.</p>
        ) : (
          <ul class="video-list">
            {visibleItems.map((item) => (
              <li
                key={item.id}
                class={{ active: item.id === state.selected?.id }}
              >
                <button
                  type="button"
                  aria-current={
                    item.id === state.selected?.id ? "true" : undefined
                  }
                  onClick$={() => chooseVideo(item)}
                >
                  <span class="video-list-icon">
                    <Icon name="video" />
                    <img
                      src={thumbnailSrc(
                        `/api/v1/items/${encodeURIComponent(item.id)}/image`,
                      )}
                      srcset={thumbnailSrcset(
                        `/api/v1/items/${encodeURIComponent(item.id)}/image`,
                      )}
                      sizes={thumbnailSizes("76px")}
                      alt=""
                      loading="lazy"
                      onError$={(_, image) => {
                        image.hidden = true;
                      }}
                    />
                  </span>
                  <span class="video-list-copy">
                    <strong title={fileName(item.relativePath)}>
                      {displayVideoTitleFromFileName(
                        fileName(item.relativePath),
                      )}
                    </strong>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </aside>

      <div class="video-edit-main">
        {selected() ? (
          <>
            <section class="video-edit-preview" aria-label="Selected video">
              <video
                key={selected()!.id}
                ref={videoRef}
                controls
                playsInline
                preload="metadata"
                src={`/api/v1/items/${encodeURIComponent(selected()!.id)}/stream`}
                onLoadedMetadata$={(_, element) => {
                  state.duration = Number.isFinite(element.duration)
                    ? element.duration
                    : 0;
                  if (!(state.end > 0) || state.end > state.duration)
                    state.end = state.duration;
                }}
              />
              <div class="video-edit-identity">
                <h2>{selectedTitle()}</h2>
                <p>{selected()!.relativePath}</p>
              </div>
            </section>

            <section
              class="video-edit-section"
              aria-labelledby="save-copy-heading"
            >
              <h2 id="save-copy-heading">Save a copy</h2>
              <p class="quiet-copy">
                Every edit is written to a new file beside the original. The
                original is never changed.
              </p>
              {!canEdit() && (
                <p class="quiet-copy">
                  Editing requires the Media Manager editor group.
                </p>
              )}
              <div class="video-edit-times">
                <label>
                  <span>Start</span>
                  <input
                    type="number"
                    min={0}
                    step={0.1}
                    value={state.start}
                    onInput$={(_, element) => {
                      state.start = Math.max(0, Number(element.value) || 0);
                    }}
                  />
                  <small>{clockTime(state.start)}</small>
                  <button
                    type="button"
                    class="text-button"
                    onClick$={() => setFromPlayback("start")}
                  >
                    Use current time
                  </button>
                </label>
                <label>
                  <span>End</span>
                  <input
                    type="number"
                    min={0}
                    step={0.1}
                    value={state.end}
                    onInput$={(_, element) => {
                      state.end = Math.max(0, Number(element.value) || 0);
                    }}
                  />
                  <small>{clockTime(state.end)}</small>
                  <button
                    type="button"
                    class="text-button"
                    onClick$={() => setFromPlayback("end")}
                  >
                    Use current time
                  </button>
                </label>
              </div>
              <div class="video-edit-fields">
                <label>
                  <span>Format</span>
                  <select
                    value={state.format}
                    onChange$={(_, element) => chooseFormat(element.value)}
                  >
                    {EDIT_FORMATS.map((format) => (
                      <option key={format} value={format}>
                        {FORMAT_COPY[format].title}
                      </option>
                    ))}
                  </select>
                </label>
                <label>
                  <span>New file name</span>
                  <input
                    value={state.outputName}
                    onInput$={(_, element) => {
                      state.outputName = element.value;
                    }}
                  />
                </label>
              </div>
              <button
                type="button"
                class="primary-button"
                disabled={state.saving || !canEdit()}
                onClick$={saveCopy}
              >
                {state.saving ? "Queuing…" : "Save a copy"}
              </button>
              {state.notice && (
                <p class="message success" role="status">
                  {state.notice}
                </p>
              )}
              {state.actionError && (
                <p class="message error" role="alert">
                  {state.actionError}
                </p>
              )}
              {state.jobs.length > 0 && (
                <ul class="video-edit-jobs" aria-label="Edits for this video">
                  {state.jobs.map((job) => (
                    <li key={job.id}>
                      <div>
                        <strong>
                          {job.format === "audio-mp3"
                            ? "Audio copy"
                            : job.mode === "copy"
                              ? "Edited copy"
                              : "Conversion"}
                        </strong>
                        <span>{jobState(job)}</span>
                      </div>
                      {ACTIVE_STATES.has(job.state) && (
                        <div
                          class="video-edit-progress"
                          role="progressbar"
                          aria-label="Saving a copy"
                          aria-valuemin={0}
                          aria-valuemax={100}
                          aria-valuenow={
                            typeof job.progress === "number"
                              ? Math.round(job.progress * 100)
                              : undefined
                          }
                        >
                          <span
                            style={{
                              transform: `scaleX(${job.progress ?? 0})`,
                            }}
                          />
                        </div>
                      )}
                    </li>
                  ))}
                </ul>
              )}
            </section>

            {props.immichUrl && (
              <section
                class="video-edit-section"
                aria-labelledby="create-gif-heading"
              >
                <h2 id="create-gif-heading">Create a GIF</h2>
                <p class="quiet-copy">
                  Saves the clip to an Immich album. The video is not changed.
                </p>
                <div class="video-edit-times">
                  <label>
                    <span>Start</span>
                    <input
                      type="number"
                      min={0}
                      step={0.1}
                      value={state.gifStart}
                      onInput$={(_, element) => {
                        state.gifStart = Math.max(
                          0,
                          Number(element.value) || 0,
                        );
                      }}
                    />
                    <small>{clockTime(state.gifStart)}</small>
                    <button
                      type="button"
                      class="text-button"
                      onClick$={() => {
                        state.gifStart =
                          Math.round((videoRef.value?.currentTime ?? 0) * 10) /
                          10;
                      }}
                    >
                      Use current time
                    </button>
                  </label>
                  <label>
                    <span>Length (seconds)</span>
                    <input
                      type="number"
                      min={1}
                      max={CLIP_MAX_SECONDS}
                      value={state.gifSeconds}
                      onInput$={(_, element) => {
                        state.gifSeconds = Number(element.value) || 1;
                      }}
                    />
                  </label>
                </div>
                <label class="video-edit-album">
                  <span>Album</span>
                  <select
                    value={state.gifAlbumId}
                    disabled={state.gifBusy}
                    onChange$={(_, element) => {
                      state.gifAlbumId = element.value;
                      state.gifAlbumName =
                        state.gifAlbums.find(
                          (album) => album.id === element.value,
                        )?.name ?? "GIF";
                    }}
                  >
                    {state.gifAlbums.map((album) => (
                      <option key={album.id} value={album.id}>
                        {album.name}
                      </option>
                    ))}
                    {!state.gifAlbums.some(
                      (album) => album.name.trim().toLowerCase() === "gif",
                    ) && <option value="">GIF (new album)</option>}
                  </select>
                </label>
                <button
                  type="button"
                  class="primary-button"
                  disabled={state.gifBusy || !canEdit()}
                  onClick$={createGif}
                >
                  {state.gifBusy ? "Creating GIF…" : "Create GIF"}
                </button>
                {state.gifNotice && (
                  <p class="message success" role="status">
                    {state.gifNotice}
                  </p>
                )}
                {state.gifError && (
                  <p class="message error" role="alert">
                    {state.gifError}
                  </p>
                )}
              </section>
            )}

            <section
              class="video-edit-section"
              aria-labelledby="copy-audio-heading"
            >
              <h2 id="copy-audio-heading">Copy audio</h2>
              <MediaCopy
                key={selected()!.id}
                initialItemId={selected()!.id}
                embedded
                canEdit={props.session?.canEdit ?? false}
                jobs={state.jobs}
                onQueued$={() => {
                  jobRefresh.value++;
                }}
              />
            </section>

            <section
              class="video-edit-section"
              aria-labelledby="transcript-heading"
            >
              <h2 id="transcript-heading">Transcript and subtitles</h2>
              <div class="video-edit-transcript">
                <p class="quiet-copy">
                  Transcripts become subtitle choices below. Editing makes new
                  files; the video is not changed.
                </p>
                <label>
                  <span>Engine</span>
                  <select
                    value={state.transcriptBackend}
                    disabled={!transcriptionAvailable()}
                    onChange$={(_, element) => {
                      state.transcriptBackend =
                        element.value === "whisper" ? "whisper" : "parakeet";
                    }}
                  >
                    <option value="parakeet">English only (Parakeet)</option>
                    <option value="whisper">Any language (Whisper)</option>
                  </select>
                </label>
                <label class="video-edit-check">
                  <input
                    type="checkbox"
                    checked={state.transcriptDiarize}
                    disabled={!transcriptionAvailable()}
                    onChange$={(_, element) => {
                      state.transcriptDiarize = element.checked;
                    }}
                  />
                  <span>Identify speakers</span>
                </label>
                <label class="video-edit-check">
                  <input
                    type="checkbox"
                    checked={state.transcriptCleanup}
                    disabled={!transcriptionAvailable()}
                    onChange$={(_, element) => {
                      state.transcriptCleanup = element.checked;
                    }}
                  />
                  <span>Correct names and misheard words</span>
                </label>
                <div class="video-edit-inline-actions">
                  <button
                    type="button"
                    class="secondary-button"
                    disabled={
                      state.transcriptBusy ||
                      !transcriptionAvailable() ||
                      !state.conversionAvailable ||
                      !selectedRootPath()
                    }
                    onClick$={queueTranscript}
                  >
                    {state.transcriptBusy
                      ? "Queuing transcript…"
                      : "Create transcript"}
                  </button>
                  <a
                    class="text-button"
                    href={`?${new URLSearchParams({
                      view: "transcript",
                      root: selected()!.rootId,
                      path: selected()!.relativePath,
                    })}`}
                  >
                    View transcript
                  </a>
                  <button
                    type="button"
                    class="text-button"
                    onClick$={() => state.subtitleKey++}
                  >
                    Refresh transcript list
                  </button>
                </div>
                {!transcriptionAvailable() && (
                  <p class="quiet-copy">
                    Transcription is unavailable right now.
                  </p>
                )}
                {transcriptionAvailable() && !state.conversionAvailable && (
                  <p class="quiet-copy">
                    Creating transcripts requires the Media Manager editor
                    group.
                  </p>
                )}
                {state.transcriptNotice && (
                  <p class="message success" role="status">
                    {state.transcriptNotice}
                  </p>
                )}
                {state.transcriptError && (
                  <p class="message error" role="alert">
                    {state.transcriptError}
                  </p>
                )}
              </div>
              <SubtitleView
                key={`${selected()!.id}-${state.subtitleKey}`}
                item={selected()}
                roots={props.roots}
                session={props.session}
                status={props.status}
              />
            </section>
          </>
        ) : (
          <p class="quiet-copy">
            {state.loading ? "Loading videos…" : "Choose a video to edit."}
          </p>
        )}
      </div>
    </section>
  );
});
