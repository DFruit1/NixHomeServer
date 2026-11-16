import {
  $,
  component$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import type {
  VideoConversionCandidate,
  VideoConversionFormatId,
  VideoConversionJob,
  VideoConversionList,
  VideoConversionQueued,
} from "./api-contract.generated";
import { formatBytes } from "./item-editor-helpers";
import "./comic-archive-action.css";
import "./video-conversions.css";

type FormatCopy = {
  title: string;
  codecs: string;
  size: string;
  devices: string;
  browsers: string;
  speed: string;
  subtitles: string;
};

/** Owner request (2026-11-15): each format explains its size, device and
 * browser support and encoding speed beside the choice. */
export const FORMAT_COPY: Record<VideoConversionFormatId, FormatCopy> = {
  "compatible-mp4": {
    title: "Compatible MP4",
    codecs: "H.264 video, AAC audio",
    size: "Largest of the four, about the size of a typical DVD or Blu-ray rip.",
    devices:
      "Practically everything: iPhone, iPad, Android, smart TVs, streaming sticks, game consoles and devices from about 2010 on.",
    browsers: "Every browser, including Safari on iPhone.",
    speed:
      "Fastest. Videos that are already H.264 only have their audio converted, which takes minutes.",
    subtitles:
      "Text subtitles are kept. Picture-based subtitles from DVDs and Blu-rays cannot be stored in MP4 and stay only in the original.",
  },
  "compatible-mkv": {
    title: "Compatible MKV",
    codecs: "H.264 video, AAC audio",
    size: "Same as MP4.",
    devices:
      "Jellyfin apps (including on iPhone), Android, Kodi, VLC and most smart TVs and streaming sticks. Apple's own video apps cannot open MKV.",
    browsers:
      "Chrome, Edge and Firefox. Safari cannot open MKV, so Jellyfin repackages it as it plays.",
    speed: "Fast, the same as MP4.",
    subtitles: "Keeps every subtitle track, including picture-based ones.",
  },
  "efficient-hevc": {
    title: "Efficient HEVC",
    codecs: "H.265 video, AAC audio, MKV",
    size: "About half the size of H.264 at similar quality.",
    devices:
      "Most phones, TVs and streaming sticks from about 2016 on. Older devices cannot decode it, so Jellyfin has to convert it while they play.",
    browsers:
      "Chrome and Edge on hardware that decodes HEVC. Not Firefox, and not Safari, which cannot open MKV.",
    speed: "Slow: several times longer than H.264, often hours for a film.",
    subtitles: "Keeps every subtitle track, including picture-based ones.",
  },
  "modern-av1": {
    title: "Modern AV1",
    codecs: "AV1 video, Opus audio, MKV",
    size: "Smallest: around half the size of H.264, often less.",
    devices:
      "Recent devices only, mostly from 2020 on (iPhone 15 Pro and later). Older devices need Jellyfin to convert it while they play.",
    browsers: "Chrome, Edge and Firefox. Not Safari.",
    speed: "Slowest: a film can take many hours at the server's low priority.",
    subtitles: "Keeps every subtitle track, including picture-based ones.",
  },
};

const FORMAT_ORDER: VideoConversionFormatId[] = [
  "compatible-mp4",
  "compatible-mkv",
  "efficient-hevc",
  "modern-av1",
];

const ACTIVE = new Set(["queued", "encoding", "installing"]);

function fileName(path: string): string {
  return path.split("/").at(-1) ?? path;
}

function folder(path: string): string {
  return path.split("/").slice(0, -1).join("/");
}

function jobStatus(job: VideoConversionJob): string {
  switch (job.state) {
    case "queued":
      return "Waiting";
    case "encoding":
      return "Converting";
    case "installing":
      return "Replacing the original";
    case "completed": {
      const sizes =
        job.outputBytes != null
          ? ` · ${formatBytes(job.sourceBytes)} → ${formatBytes(job.outputBytes)}`
          : "";
      return `Saved as ${fileName(job.outputRelativePath ?? job.relativePath)}${sizes}`;
    }
    case "cancelled":
      return "Cancelled";
    default:
      return job.error || "The conversion failed.";
  }
}

/**
 * Conversions → Convert videos: videos browsers cannot play, a per-conversion
 * format choice, and the caller's conversion queue. `initialItemId` (from the
 * player's link) lists that video first even when it already plays.
 */
export const VideoConversions = component$<{
  initialItemId?: string;
  hideActiveJobs?: boolean;
}>((props) => {
  const state = useStore({
    list: undefined as VideoConversionList | undefined,
    error: "",
    format: "compatible-mp4" as VideoConversionFormatId,
    busy: [] as string[],
    confirmAll: false,
    notice: "",
    actionError: "",
  });

  const target = useSignal<HTMLElement>();
  // Arriving from the player or Library health: show that video, not the
  // task chooser above it, once the list has loaded.
  useVisibleTask$(({ track }) => {
    const row = track(() => target.value);
    if (row) row.scrollIntoView({ block: "center" });
  });

  const load = $(async () => {
    const query = props.initialItemId
      ? `?itemId=${encodeURIComponent(props.initialItemId)}`
      : "";
    try {
      state.list = await api<VideoConversionList>(`/video-conversions${query}`);
      state.error = "";
    } catch (error) {
      state.error = readableError(error);
    }
  });

  useTask$(({ cleanup }) => {
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      await load();
      const list = state.list;
      const waiting =
        !!list &&
        (list.probePending > 0 ||
          list.jobs.some((job) => ACTIVE.has(job.state)));
      if (!stopped && typeof window !== "undefined")
        timer = setTimeout(tick, waiting ? 5000 : 30000);
    };
    void tick();
    cleanup(() => {
      stopped = true;
      clearTimeout(timer);
    });
  });

  const queue$ = $(async (itemIds: string[]) => {
    if (!itemIds.length) return;
    state.busy = [...state.busy, ...itemIds];
    state.actionError = "";
    state.notice = "";
    try {
      const result = await api<VideoConversionQueued>("/video-conversions", {
        method: "POST",
        body: JSON.stringify({ itemIds, format: state.format }),
      });
      const queued = result.jobs.length;
      state.notice = [
        queued
          ? `${queued} video${queued === 1 ? "" : "s"} queued as ${FORMAT_COPY[state.format].title}.`
          : "",
        ...result.skipped.map((skip) => skip.reason),
      ]
        .filter(Boolean)
        .join(" ");
      state.confirmAll = false;
      await load();
    } catch (error) {
      state.actionError = readableError(error);
    } finally {
      state.busy = state.busy.filter((id) => !itemIds.includes(id));
    }
  });

  const cancel$ = $(async (job: VideoConversionJob) => {
    state.busy = [...state.busy, job.id];
    state.actionError = "";
    try {
      await api(`/video-conversions/${encodeURIComponent(job.id)}/cancel`, {
        method: "POST",
      });
      await load();
    } catch (error) {
      state.actionError = readableError(error);
    } finally {
      state.busy = state.busy.filter((id) => id !== job.id);
    }
  });

  const list = state.list;
  // The linked video leads the list, even when browsers already play it.
  const candidates = [
    ...(list?.selected ? [list.selected] : []),
    ...(list?.candidates ?? []).filter(
      (c) => c.itemId !== list?.selected?.itemId,
    ),
  ];
  const queuedPaths = new Set(
    (list?.jobs ?? [])
      .filter((job) => ACTIVE.has(job.state))
      .map((job) => `${job.rootId}/${job.relativePath}`),
  );
  const convertible = (list?.candidates ?? []).filter(
    (c) => !queuedPaths.has(`${c.rootId}/${c.relativePath}`),
  );
  const canQueue = !!list?.available && !!list.canConvert;
  const jobs = [...(list?.jobs ?? [])]
    .filter((job) => !props.hideActiveJobs || !ACTIVE.has(job.state))
    .sort(
      (a, b) =>
        Number(ACTIVE.has(b.state)) - Number(ACTIVE.has(a.state)) ||
        (ACTIVE.has(a.state)
          ? a.createdAt - b.createdAt
          : (b.finishedAt ?? b.createdAt) - (a.finishedAt ?? a.createdAt)),
    );
  const copy = FORMAT_COPY[state.format];

  const row = (candidate: VideoConversionCandidate) => {
    const queued = queuedPaths.has(
      `${candidate.rootId}/${candidate.relativePath}`,
    );
    const busy = state.busy.includes(candidate.itemId);
    return (
      <li
        key={candidate.itemId}
        ref={candidate.itemId === props.initialItemId ? target : undefined}
        class={{
          "video-conversions__selected":
            candidate.itemId === props.initialItemId,
        }}
      >
        <div class="comic-conversions__name">
          <strong>{fileName(candidate.relativePath)}</strong>
          <small>
            {[candidate.rootLabel, folder(candidate.relativePath)]
              .filter(Boolean)
              .join(" · ")}
          </small>
          {candidate.reasons.length > 0 && (
            <small>{candidate.reasons.join(" ")}</small>
          )}
          {candidate.imageSubtitles && state.format === "compatible-mp4" && (
            <small class="video-conversions__caution">
              Its picture-based subtitles will not be in the MP4.
            </small>
          )}
        </div>
        <button
          type="button"
          class="secondary-button"
          disabled={!canQueue || queued || busy}
          onClick$={() => queue$([candidate.itemId])}
        >
          {queued ? "Queued" : busy ? "Queuing…" : "Convert"}
        </button>
      </li>
    );
  };

  return (
    <section
      class="panel comic-conversions video-conversions"
      aria-labelledby="video-conversions-heading"
    >
      <header class="panel-heading">
        <h2 id="video-conversions-heading">Convert videos</h2>
      </header>
      <div class="comic-conversions__body">
        {state.error && (
          <p class="message error" role="alert">
            {state.error}
          </p>
        )}
        {list && !list.available && (
          <p class="message error">
            Video conversion is unavailable on this server.
          </p>
        )}
        {list && list.available && !list.canConvert && (
          <p class="quiet-copy">
            Converting videos requires the Media Manager editor group.
          </p>
        )}
        <fieldset class="video-formats">
          <legend>Convert to</legend>
          {FORMAT_ORDER.map((id) => (
            <label key={id} class="video-format">
              <input
                type="radio"
                name="video-format"
                value={id}
                checked={state.format === id}
                onChange$={() => {
                  state.format = id;
                  state.confirmAll = false;
                }}
              />
              <span>
                <strong>{FORMAT_COPY[id].title}</strong>
                <small>{FORMAT_COPY[id].codecs}</small>
              </span>
            </label>
          ))}
        </fieldset>
        <dl class="video-format-details" aria-live="polite">
          <dt>Size</dt>
          <dd>{copy.size}</dd>
          <dt>Devices</dt>
          <dd>{copy.devices}</dd>
          <dt>Browsers</dt>
          <dd>{copy.browsers}</dd>
          <dt>Speed</dt>
          <dd>{copy.speed}</dd>
          <dt>Subtitles</dt>
          <dd>{copy.subtitles}</dd>
        </dl>
        <p class="video-conversions__note">
          The conversion replaces the video in its library, and the original is
          moved to <code>_Originals/Videos</code> in your folder.
        </p>
        {(state.notice || state.actionError) && (
          <p
            class={`message ${state.actionError ? "error" : "success"}`}
            role={state.actionError ? "alert" : "status"}
          >
            {state.actionError || state.notice}
          </p>
        )}
        {jobs.length > 0 && (
          <div class="video-conversions__group">
            <h3>Your conversions</h3>
            <ul class="comic-conversions__list">
              {jobs.map((job) => {
                const percent = Math.round((job.progress ?? 0) * 100);
                return (
                  <li key={job.id} class={`video-job video-job--${job.state}`}>
                    <div class="comic-conversions__name">
                      <strong>{fileName(job.relativePath)}</strong>
                      <small>
                        {FORMAT_COPY[job.format].title} ·{" "}
                        {[job.rootLabel, folder(job.relativePath)]
                          .filter(Boolean)
                          .join(" · ")}
                      </small>
                      <small
                        class={{
                          "video-job__status": true,
                          "video-job__status--error": job.state === "failed",
                        }}
                      >
                        {jobStatus(job)}
                      </small>
                      {job.state === "encoding" && (
                        <div class="progress-row">
                          <div
                            class="progress-track"
                            role="progressbar"
                            aria-label={`Converting ${fileName(job.relativePath)}`}
                            aria-valuemin={0}
                            aria-valuemax={100}
                            aria-valuenow={percent}
                          >
                            <span
                              style={{
                                transform: `scaleX(${percent / 100})`,
                              }}
                            />
                          </div>
                          <strong class="tabular" aria-hidden="true">
                            {percent}%
                          </strong>
                        </div>
                      )}
                      {job.state === "completed" && (
                        <small>
                          Original kept in <code>{job.archivedPath}</code>
                          {job.droppedSubtitles > 0 &&
                            `, with ${job.droppedSubtitles} picture-based subtitle track${job.droppedSubtitles === 1 ? "" : "s"} the MP4 could not hold`}
                          .
                        </small>
                      )}
                    </div>
                    {(job.state === "queued" || job.state === "encoding") &&
                      list?.canConvert && (
                        <button
                          type="button"
                          class="secondary-button"
                          disabled={state.busy.includes(job.id)}
                          onClick$={() => cancel$(job)}
                        >
                          Cancel
                        </button>
                      )}
                  </li>
                );
              })}
            </ul>
          </div>
        )}
        <div class="video-conversions__group">
          <div class="video-conversions__heading">
            <h3>Videos browsers cannot play</h3>
            {convertible.length > 1 && !state.confirmAll && (
              <button
                type="button"
                class="primary-button"
                disabled={!canQueue}
                onClick$={() => {
                  state.confirmAll = true;
                }}
              >
                Convert all {convertible.length}
              </button>
            )}
          </div>
          {state.confirmAll && (
            <div class="video-conversions__confirm" role="group">
              <p>
                Convert all {convertible.length} videos to {copy.title}? They
                are converted one at a time, and each original moves to your{" "}
                <code>_Originals</code> folder.
              </p>
              <div class="comic-archive-action__buttons">
                <button
                  type="button"
                  class="primary-button"
                  disabled={state.busy.length > 0}
                  onClick$={() => queue$(convertible.map((c) => c.itemId))}
                >
                  {state.busy.length > 0 ? "Queuing…" : "Convert all"}
                </button>
                <button
                  type="button"
                  class="secondary-button"
                  onClick$={() => {
                    state.confirmAll = false;
                  }}
                >
                  Cancel
                </button>
              </div>
            </div>
          )}
          {!list && !state.error ? (
            <p class="quiet-copy">Looking for videos…</p>
          ) : candidates.length === 0 ? (
            <p class="quiet-copy">
              {list && list.probePending > 0
                ? "No videos need converting so far."
                : "Every video in your libraries plays in browsers."}
            </p>
          ) : (
            <ul class="comic-conversions__list">{candidates.map(row)}</ul>
          )}
          {list && list.probePending > 0 && (
            <p class="quiet-copy">
              Checking {list.probePending} more video
              {list.probePending === 1 ? "" : "s"}…
            </p>
          )}
          {list?.truncated && (
            <p class="quiet-copy">
              Only the first 20,000 items in each library are checked.
            </p>
          )}
        </div>
      </div>
    </section>
  );
});
