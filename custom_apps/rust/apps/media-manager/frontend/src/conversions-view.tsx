import {
  $,
  component$,
  type QRL,
  useComputed$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, ApiError, readableError } from "./api";
import { useBackLayer } from "./back-layers";
import type {
  VideoConversionList,
  PlanListResponse,
  CatalogItem,
  TranscriptionEnvelope,
  TranscriptionJob,
} from "./api-contract.generated";
import { ConversionInput, type ConversionTask } from "./conversion-input";
import type {
  ConversionInputAccepted,
  ConversionInputs,
} from "./api-contract.generated";
import { ComicConversions } from "./comic-conversions";
import { MediaCopy } from "./media-copy";
import { VideoConversions } from "./video-conversions";
import { Icon } from "./icon";
import type {
  Conversion,
  ConversionEnvelope,
  ConversionInbox,
  IconName,
  InboxIso,
} from "./root-types";

/** Encode each segment of a shared-folder path for a Files link. */
const sharedPath = (path: string) =>
  path.split("/").map(encodeURIComponent).join("/");

type ConversionsTask = ConversionTask | "comics" | "videos" | "copy-audio";

type ProcessingJob = {
  id: string;
  name: string;
  icon: IconName;
  label: string;
  stage: string;
  percent?: number | null;
  approximate?: boolean;
  waiting?: boolean;
  cancelId?: string;
};

/** Every worker uses the original DVD card and progress track. */
const JobProgress = component$<{
  job: ProcessingJob;
  onCancel$: QRL<(id: string) => void>;
}>((props) => {
  const job = props.job;
  const percent =
    typeof job.percent === "number"
      ? Math.max(0, Math.min(100, job.percent))
      : null;
  return (
    <article class="conversion-card">
      <span class="conversion-symbol" aria-hidden="true">
        <Icon name={job.icon} size={28} />
      </span>
      <div class="conversion-copy">
        <h3>{job.name}</h3>
        <p>
          {job.label}
          {job.waiting ? ` · ${job.stage}` : ""}
        </p>
        {!job.waiting && (
          <>
            <div
              class="progress-track"
              role="progressbar"
              aria-label={`${job.label}: ${job.name}`}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={percent ?? undefined}
              aria-valuetext={
                percent === null
                  ? job.stage
                  : `${job.approximate ? "Approximately " : ""}${percent}%`
              }
            >
              <span
                class={percent === null ? "progress-track__moving" : undefined}
                style={
                  percent === null
                    ? undefined
                    : { transform: `scaleX(${percent / 100})` }
                }
              />
            </div>
            <div class="progress-meta">
              <span>{job.stage}</span>
              {percent !== null && (
                <strong class="tabular">
                  {job.approximate ? "~" : ""}
                  {percent.toFixed(0)}%
                </strong>
              )}
            </div>
          </>
        )}
        {job.cancelId && (
          <button
            type="button"
            class="text-button"
            onClick$={() => props.onCancel$(job.cancelId!)}
          >
            Cancel
          </button>
        )}
      </div>
    </article>
  );
});

const TRANSCRIPT_STAGES: Record<TranscriptionJob["state"], string> = {
  queued: "Waiting",
  extracting: "Extracting audio",
  transcribing: "Transcribing",
  cleaning: "Correcting names and misheard words",
  diarising: "Finding speakers",
  writing: "Writing transcript files",
  completed: "Finished",
  failed: "Failed",
};
const backendLabel = (job: TranscriptionJob) =>
  job.backend === "parakeet" ? "Parakeet" : "Whisper";

const tasks: {
  id: ConversionsTask;
  icon: IconName;
  title: string;
  detail: string;
}[] = [
  {
    id: "copy-audio",
    icon: "mic",
    title: "Copy video audio to another library",
    detail:
      "Save an interview as a podcast, a song as music, or narrated material as an audiobook.",
  },
  {
    id: "dvd",
    icon: "disc",
    title: "Convert a DVD",
    detail: "Turn a DVD disc image into a video in your library.",
  },
  {
    id: "transcribe",
    icon: "mic",
    title: "Transcribe audio or video",
    detail: "Get a written transcript of what is said.",
  },
  {
    id: "subtitles",
    icon: "captions",
    title: "Make subtitles",
    detail: "Create subtitles for a video in your library.",
  },
  {
    id: "comics",
    icon: "book",
    title: "Fix comics that can't be edited",
    detail: "Converts CBR comics to CBZ.",
  },
  {
    id: "videos",
    icon: "video",
    title: "Convert videos",
    detail: "Make videos load faster and play in browsers and on more devices.",
  },
];

/** Authoring-tool defaults that say nothing about which disc this is. */
const GENERIC_VOLUME_LABELS = new Set([
  "CDROM",
  "DVD",
  "DVDVOLUME",
  "DVD_VIDEO",
  "VIDEO_TS",
  "UNDEFINED",
]);

/** One readable name per disc: the volume label, else the file name without `.iso`. */
function isoTitle(iso: InboxIso): string {
  const label = iso.volumeId?.trim();
  return label && !GENERIC_VOLUME_LABELS.has(label.toUpperCase())
    ? label
    : iso.name.replace(/\.iso$/i, "");
}

function finishedAt(iso: InboxIso): string {
  if (!iso.finishedNs) return "";
  return new Date(iso.finishedNs / 1e6).toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}

interface QueuedConversion {
  title: string;
  isoName: string;
}

type DvdArchive = "_Processed" | "_Failed";
/** Per-disc requeue state, keyed by archive folder and file name. */
type Requeues = Record<
  string,
  { busy?: boolean; queued?: boolean; error?: string }
>;

const RequeueAction = component$<{
  iso: InboxIso;
  archive: DvdArchive;
  requeues: Requeues;
  onRequeue$: QRL<(archive: DvdArchive, iso: InboxIso) => void>;
}>((props) => {
  const state = props.requeues[`${props.archive}/${props.iso.name}`];
  if (state?.queued)
    return <small class="side-item-status">Moved back to the queue</small>;
  return (
    <>
      <button
        type="button"
        class="text-button side-item-requeue"
        disabled={state?.busy}
        aria-label={`${props.archive === "_Failed" ? "Try again" : "Convert again"}: ${isoTitle(props.iso)}`}
        onClick$={() => props.onRequeue$(props.archive, props.iso)}
      >
        <Icon name="refresh" size={14} />
        {state?.busy
          ? "Queuing…"
          : props.archive === "_Failed"
            ? "Try again"
            : "Convert again"}
      </button>
      {state?.error && (
        <p class="message error side-item-error" role="alert">
          {state.error}
        </p>
      )}
    </>
  );
});

const LogDialog = component$<{
  iso: InboxIso;
  onClose$: QRL<() => void>;
}>((props) => {
  const log = useSignal<string>("");
  const loading = useSignal(true);
  const error = useSignal("");

  useTask$(() => {
    const load = async () => {
      try {
        log.value = (
          await api<{ content: string }>(
            `/conversions/inbox/error?name=${encodeURIComponent(props.iso.name)}`,
          )
        ).content;
      } catch (e) {
        error.value = readableError(e);
      } finally {
        loading.value = false;
      }
    };
    void load();
  });

  return (
    <div class="dialog-backdrop" onClick$={props.onClose$}>
      <div
        class="dialog"
        role="dialog"
        aria-labelledby="failure-dialog-heading"
        onClick$={(e) => e.stopPropagation()}
      >
        <div class="dialog-header">
          <h3 id="failure-dialog-heading">Why {isoTitle(props.iso)} failed</h3>
          <button
            type="button"
            class="dialog-close"
            onClick$={props.onClose$}
            aria-label="Close"
          >
            ×
          </button>
        </div>
        <div class="dialog-body">
          <p class="dialog-iso-name">{props.iso.name}</p>
          {props.iso.failureSummary && (
            <p class="failure-summary">{props.iso.failureSummary}</p>
          )}
          {props.iso.failureHint && (
            <p class="failure-hint">{props.iso.failureHint}</p>
          )}
          {loading.value ? (
            <p class="quiet-copy">Loading details…</p>
          ) : error.value ? (
            <p class="message error" role="alert">
              {error.value}
            </p>
          ) : (
            <details class="failure-details" open={!props.iso.failureSummary}>
              <summary>Converter output</summary>
              <pre class="log-content">{log.value}</pre>
            </details>
          )}
        </div>
      </div>
    </div>
  );
});

export const ConversionsView = component$<{
  initial?: ConversionEnvelope;
  transcriptionAvailable?: boolean;
  canEdit?: boolean;
  /** A video to convert, from the player's or Library health's link. */
  initialItemId?: string;
  /** Signed-in username, so shared browsers keep dismissals separate. */
  viewer?: string;
}>((props) => {
  const conv = useStore<{
    conversions?: ConversionEnvelope;
    inbox?: ConversionInbox;
    error: string;
    transcriptions?: TranscriptionEnvelope;
    transcriptionError: string;
    inputs?: ConversionInputs;
    inputError: string;
    videos?: VideoConversionList;
    plans?: PlanListResponse;
    jobError: string;
    itemNames: Record<string, string>;
  }>({
    conversions: props.initial,
    inbox: undefined,
    error: "",
    transcriptionError: "",
    inputError: "",
    jobError: "",
    itemNames: {},
  });
  const comicJobs = useStore<Record<string, { name: string; stage: string }>>(
    {},
  );
  const logDialog = useSignal<string>("");
  const logDialogOpen = useComputed$(() => logDialog.value !== "");
  useBackLayer(
    "failure-log",
    logDialogOpen,
    $(() => (logDialog.value = "")),
  );
  const task = useSignal<ConversionsTask | "">(
    props.initialItemId ? "videos" : "",
  );
  const requeues = useStore<Requeues>({});
  // Archived discs move back into the inbox through the same server-file
  // submission as any other ISO, so the broker applies the same checks.
  const requeue = $(async (archive: DvdArchive, iso: InboxIso) => {
    const key = `${archive}/${iso.name}`;
    const root = conv.inputs?.roots.find((r) => r.id === "dvd-inbox");
    if (!root || requeues[key]?.busy) return;
    requeues[key] = { busy: true };
    try {
      const result = await api<ConversionInputAccepted>("/conversions/jobs", {
        method: "POST",
        body: JSON.stringify({
          serverPath: `${root.path}/${key}`,
          options: { name: iso.name, kind: "iso" },
        }),
      });
      if (conv.inputs) conv.inputs.jobs = [result.job, ...conv.inputs.jobs];
      requeues[key] = { queued: true };
    } catch (error) {
      requeues[key] = { error: readableError(error) };
    }
  });

  // Poll only in a visible browser: mobile browsers suspend background requests.
  // eslint-disable-next-line qwik/no-use-visible-task -- browser visibility owns polling
  useVisibleTask$(({ cleanup, track }) => {
    const transcribe = track(() => props.transcriptionAvailable);
    let stopped = false;
    const load = async (signal: AbortSignal) => {
      const request = <T,>(path: string) => api<T>(path, { signal });
      const [inputs, conversions, inbox, transcription, videos, plans] =
        await Promise.allSettled([
          request<ConversionInputs>("/conversions/jobs"),
          request<ConversionEnvelope>("/conversions"),
          request<ConversionInbox>("/conversions/inbox"),
          transcribe
            ? request<TranscriptionEnvelope>("/transcriptions")
            : Promise.resolve(undefined),
          request<VideoConversionList>("/video-conversions"),
          request<PlanListResponse>("/plans"),
        ]);
      if (stopped || signal.aborted) return;
      if (videos.status === "fulfilled") conv.videos = videos.value;
      if (plans.status === "fulfilled") {
        conv.plans = plans.value;
        const ids = [
          ...new Set(
            (plans.value.plans ?? [])
              .filter(
                (p) =>
                  p.operationKind === "comic_archive_to_cbz" &&
                  ["queued", "running"].includes(p.state),
              )
              .flatMap((p) => p.itemIds),
          ),
        ].filter((id) => !(id in conv.itemNames));
        await Promise.allSettled(
          ids.map(async (id) => {
            const item = await request<CatalogItem>(
              `/items/${encodeURIComponent(id)}`,
            );
            if (!stopped && !signal.aborted)
              conv.itemNames[id] =
                item.relativePath.split("/").at(-1) ?? item.relativePath;
          }),
        );
      }
      if (stopped || signal.aborted) return;
      conv.jobError = [
        ...new Set(
          [videos, plans].flatMap((result) =>
            result.status === "rejected" ? [readableError(result.reason)] : [],
          ),
        ),
      ].join(" ");
      if (inputs.status === "fulfilled") {
        conv.inputs = inputs.value;
        conv.inputError = "";
      } else conv.inputError = readableError(inputs.reason);
      if (conversions.status === "fulfilled")
        conv.conversions = conversions.value;
      if (inbox.status === "fulfilled") conv.inbox = inbox.value;
      conv.error = [
        ...new Set(
          [conversions, inbox].flatMap((result) =>
            result.status === "rejected" ? [readableError(result.reason)] : [],
          ),
        ),
      ].join(" ");
      if (transcription.status === "fulfilled") {
        conv.transcriptions = transcription.value;
        conv.transcriptionError = "";
      } else if (
        transcription.reason instanceof ApiError &&
        transcription.reason.status === 503
      ) {
        conv.transcriptions = undefined;
        conv.transcriptionError =
          "Transcription is unavailable right now, so its jobs can't be shown.";
      } else conv.transcriptionError = readableError(transcription.reason);
    };
    let timer: ReturnType<typeof setTimeout> | undefined;
    let active: AbortController | undefined;
    const pause = () => {
      clearTimeout(timer);
      active?.abort();
      active = undefined;
    };
    const tick = async () => {
      if (stopped || document.hidden || active) return;
      const controller = new AbortController();
      active = controller;
      try {
        await load(controller.signal);
      } finally {
        // A cancelled round must not schedule over a newer foreground round.
        if (active === controller) {
          active = undefined;
          if (!stopped && !document.hidden) timer = setTimeout(tick, 5000);
        }
      }
    };
    const visibility = () => {
      pause();
      if (!document.hidden) void tick();
    };
    document.addEventListener("visibilitychange", visibility);
    void tick();
    cleanup(() => {
      stopped = true;
      pause();
      document.removeEventListener("visibilitychange", visibility);
    });
  });

  const activeConversions = conv.conversions?.progress.conversions ?? [];
  const progressQueued = conv.conversions?.progress.queued ?? [];

  const inboxPending = conv.inbox?.pending ?? [];
  const inboxProcessed = conv.inbox?.processed ?? [];
  const inboxFailed = conv.inbox?.failed ?? [];
  const inboxNeedsIdentification = conv.inbox?.needsIdentification ?? [];
  const filesBaseUrl = conv.inbox?.filesBaseUrl ?? "";
  const transcripts = (conv.transcriptions?.jobs ?? []).map((job) => ({
    ...job,
    name:
      conv.inputs?.jobs.find((input) => input.transcriptId === job.id)?.name ??
      job.name,
  }));
  const activeTranscripts = transcripts.filter(
    (j) => j.state !== "completed" && j.state !== "failed",
  );
  const dismissed = useSignal<string[]>([]);
  const dismissKey = `mm-conversions-dismissed:${props.viewer ?? ""}`;
  // eslint-disable-next-line qwik/no-use-visible-task -- dismissal is a browser preference
  useVisibleTask$(() => {
    try {
      const saved = JSON.parse(localStorage.getItem(dismissKey) ?? "[]");
      if (Array.isArray(saved))
        dismissed.value = saved
          .filter((key): key is string => typeof key === "string")
          .slice(-300);
    } catch {
      // An unreadable preference simply hides nothing.
    }
  });
  const dismiss = $((key: string) => {
    if (dismissed.value.includes(key)) return;
    const next = [...dismissed.value, key].slice(-300);
    dismissed.value = next;
    try {
      localStorage.setItem(dismissKey, JSON.stringify(next));
    } catch {
      // Without storage the entry stays hidden for this page only.
    }
  });
  const completedItems = historyItems(
    inboxProcessed,
    transcripts.filter((j) => j.state === "completed"),
  );
  const failedItems = historyItems(
    inboxFailed,
    transcripts.filter((j) => j.state === "failed"),
  );

  const pendingMap = new Map<string, InboxIso>();
  for (const iso of inboxPending) {
    pendingMap.set(iso.name.replace(/\.iso$/i, ""), iso);
    pendingMap.set(iso.name, iso);
  }

  const queuedEntries: QueuedConversion[] = [];
  const seen = new Set<string>();
  for (const stem of progressQueued) {
    if (seen.has(stem)) continue;
    const cleanStem = stem.replace(/\.iso$/i, "");
    const match = pendingMap.get(stem) ?? pendingMap.get(cleanStem);
    if (match) {
      seen.add(stem);
      seen.add(cleanStem);
      seen.add(match.name);
      seen.add(match.name.replace(/\.iso$/i, ""));
      queuedEntries.push({
        title: isoTitle(match),
        isoName: match.name,
      });
    } else {
      seen.add(stem);
      queuedEntries.push({
        title: cleanStem,
        isoName: cleanStem + ".iso",
      });
    }
  }
  for (const iso of inboxPending) {
    const stem = iso.name.replace(/\.iso$/i, "");
    if (!seen.has(stem) && !seen.has(iso.name)) {
      seen.add(stem);
      queuedEntries.push({
        title: isoTitle(iso),
        isoName: iso.name,
      });
    }
  }

  const jobs: ProcessingJob[] = [
    ...Object.entries(comicJobs).map(([id, job]) => ({
      id: `comic-preparing-${id}`,
      name: job.name,
      stage: job.stage,
      icon: "book" as const,
      label: "Comic conversion",
    })),
    ...activeConversions.map((job, index) => ({
      id: `dvd-${job.sourceIso ?? index}`,
      name: job.title || job.sourceIso || "DVD",
      icon: "disc" as const,
      label: "DVD conversion",
      stage: job.detail || "Making a video for your library",
      percent: job.percent,
    })),
    ...activeTranscripts.map((job) => ({
      id: `transcript-${job.id}`,
      name: job.name,
      icon: "mic" as const,
      label: "Transcription / subtitles",
      stage: `${backendLabel(job)} · ${
        job.state === "transcribing" && job.progressPhase
          ? {
              preparing: "Preparing audio analysis",
              encoding: "Analysing audio (approx.)",
              decoding: "Decoding speech",
            }[job.progressPhase]
          : TRANSCRIPT_STAGES[job.state]
      }`,
      percent: job.progressPhase === "preparing" ? null : job.progress,
      approximate:
        job.state === "transcribing" && job.progressPhase === "encoding",
      waiting: job.state === "queued",
    })),
    ...(conv.videos?.jobs ?? [])
      .filter((job) => ["queued", "encoding", "installing"].includes(job.state))
      .map((job) => ({
        id: `video-${job.id}`,
        name: job.relativePath.split("/").at(-1) ?? job.relativePath,
        icon: "video" as const,
        label: job.destinationRootId ? "Audio copy" : "Video conversion",
        stage:
          job.state === "queued"
            ? "Waiting"
            : job.state === "installing"
              ? job.destinationRootId
                ? "Saving audio copy"
                : "Replacing the original"
              : "Encoding",
        percent:
          job.state === "encoding" && job.progress != null
            ? job.progress * 100
            : null,
        waiting: job.state === "queued",
        cancelId:
          conv.videos?.canConvert && job.state !== "installing"
            ? job.id
            : undefined,
      })),
    ...(conv.plans?.plans ?? [])
      .filter(
        (job) =>
          job.operationKind === "comic_archive_to_cbz" &&
          !job.itemIds.some((id) => comicJobs[id]) &&
          ["queued", "running"].includes(job.state),
      )
      .map((job) => ({
        id: `comic-${job.id}`,
        name: job.itemIds.map((id) => conv.itemNames[id] ?? "Comic").join(", "),
        icon: "book" as const,
        label: "Comic conversion",
        stage: job.state === "queued" ? "Waiting" : "Saving CBZ",
        waiting: job.state === "queued",
      })),
    ...(conv.inputs?.jobs ?? [])
      .filter(
        (job) =>
          !["completed", "failed"].includes(job.state) &&
          !(
            job.transcriptId &&
            transcripts.some((t) => t.id === job.transcriptId)
          ) &&
          !(
            job.kind === "iso" &&
            [
              ...activeConversions.map((c) => c.sourceIso),
              ...queuedEntries.map((q) => q.isoName),
            ].some((name) => name?.split("/").at(-1) === job.name)
          ),
      )
      .map((job) => ({
        id: `input-${job.id}`,
        name: job.name,
        icon: job.kind === "iso" ? ("disc" as const) : ("mic" as const),
        label:
          job.kind === "iso" ? "DVD conversion" : "Transcription / subtitles",
        stage: {
          queued: "Waiting",
          submitting: "Submitting",
          processing: "Processing",
          saving: "Saving results",
          completed: "Finished",
          failed: "Failed",
        }[job.state],
        waiting: job.state === "queued",
      })),
  ];
  const cancelVideo = $(async (id: string) => {
    try {
      await api(`/video-conversions/${encodeURIComponent(id)}/cancel`, {
        method: "POST",
      });
      conv.videos = await api<VideoConversionList>("/video-conversions");
    } catch (error) {
      conv.jobError = readableError(error);
    }
  });

  const canRequeue =
    !!conv.inputs?.canSubmit &&
    !!conv.inputs.roots.some((r) => r.id === "dvd-inbox");
  const failedIso = logDialog.value
    ? inboxFailed.find((iso) => iso.name === logDialog.value)
    : undefined;

  const shown = (items: HistoryItem[]) =>
    items.some((item) => !dismissed.value.includes(item.key));
  const hasSidebar =
    inboxNeedsIdentification.length > 0 ||
    shown(completedItems) ||
    shown(failedItems);
  // The panel exists to show work in progress (or why it could not start);
  // with neither, the task choice stays the only thing asking for attention.
  const processingErrors = [
    ...new Set([conv.jobError, conv.inputError]),
  ].filter(Boolean);
  const hasProcessing =
    jobs.length > 0 || queuedEntries.length > 0 || processingErrors.length > 0;

  return (
    <section
      class={{
        "conversions-layout": true,
        "conversions-layout--single": !hasSidebar,
      }}
    >
      {failedIso && (
        <LogDialog
          key={failedIso.name}
          iso={failedIso}
          onClose$={() => (logDialog.value = "")}
        />
      )}
      {conv.error && (
        <div class="message error conv-error" role="alert">
          <Icon name="alert" size={18} />
          <span>{conv.error}</span>
          <button
            type="button"
            aria-label="Dismiss conversion error"
            onClick$={() => {
              conv.error = "";
            }}
          >
            ×
          </button>
        </div>
      )}
      <div
        class="conv-main"
        role="region"
        aria-label="Current conversion work"
        tabIndex={0}
      >
        <section
          class="conversion-tasks"
          aria-labelledby="conversion-task-heading"
        >
          <h2 id="conversion-task-heading">What would you like to do?</h2>
          <div class="conversion-task-list">
            {tasks.map((option) => {
              const unavailable =
                (option.id === "transcribe" || option.id === "subtitles") &&
                !props.transcriptionAvailable;
              return (
                <button
                  key={option.id}
                  type="button"
                  class="conversion-task"
                  aria-pressed={task.value === option.id}
                  disabled={unavailable}
                  onClick$={() => {
                    task.value = option.id;
                  }}
                >
                  <span class="conversion-task__icon" aria-hidden="true">
                    <Icon name={option.icon} size={24} />
                  </span>
                  <span class="conversion-task__copy">
                    <strong>{option.title}</strong>
                    <span>
                      {unavailable
                        ? "Transcription is unavailable right now."
                        : option.detail}
                    </span>
                  </span>
                </button>
              );
            })}
          </div>
        </section>
        {task.value === "copy-audio" && (
          <MediaCopy
            canEdit={props.canEdit ?? false}
            jobs={conv.videos?.jobs}
          />
        )}
        {task.value === "comics" && (
          <ComicConversions
            canEdit={props.canEdit ?? false}
            onProcessing$={(id, name, stage) => {
              if (stage) comicJobs[id] = { name, stage };
              else delete comicJobs[id];
            }}
          />
        )}
        {task.value === "videos" && (
          <VideoConversions
            initialItemId={props.initialItemId}
            hideActiveJobs
          />
        )}
        {/* Only transcription work depends on the transcription service. */}
        {(task.value === "transcribe" || task.value === "subtitles") &&
          props.transcriptionAvailable &&
          conv.transcriptionError && (
            <p class="quiet-copy" role="status">
              {conv.transcriptionError}
            </p>
          )}
        {task.value &&
          task.value !== "comics" &&
          task.value !== "videos" &&
          task.value !== "copy-audio" && (
            <ConversionInput
              task={task.value}
              inputs={conv.inputs}
              error={conv.inputError}
              transcriptionAvailable={props.transcriptionAvailable}
              onQueued$={(job) => {
                if (conv.inputs) conv.inputs.jobs = [job, ...conv.inputs.jobs];
              }}
              onTask$={(next) => {
                task.value = next;
              }}
            />
          )}
        {hasProcessing && (
          <section
            class="panel conversion-focus"
            aria-labelledby="processing-heading"
          >
            <header class="panel-heading">
              <h2 id="processing-heading">Processing jobs</h2>
              <span class="conversion-state">
                {jobs.some((job) => !job.waiting)
                  ? "Processing"
                  : jobs.length || queuedEntries.length
                    ? "Waiting"
                    : "Nothing running"}
              </span>
            </header>
            {processingErrors.map((error) => (
              <p key={error} class="message error" role="alert">
                {error}
              </p>
            ))}
            <div class="conversion-list">
              {jobs.map((job) => (
                <JobProgress key={job.id} job={job} onCancel$={cancelVideo} />
              ))}
              {queuedEntries.length > 0 && (
                <div class="conversion-queue" aria-label="DVD discs waiting">
                  <span class="conversion-queue__heading">
                    In queue ({queuedEntries.length})
                  </span>
                  <ol class="conversion-queue__list">
                    {queuedEntries.map((job, index) => (
                      <li key={job.isoName}>
                        <span class="conversion-queue__number">
                          {index + 1}.
                        </span>
                        <Icon name="disc" size={16} />
                        <span class="conversion-queue__title">
                          {job.title} <small>· DVD conversion · Waiting</small>
                        </span>
                      </li>
                    ))}
                  </ol>
                </div>
              )}
            </div>
          </section>
        )}
      </div>
      {hasSidebar && (
        <aside class="conv-sidebar">
          {inboxNeedsIdentification.length > 0 && (
            <NeedsIdentificationCard
              isos={inboxNeedsIdentification}
              filesBaseUrl={filesBaseUrl}
              canRename={!!conv.inputs?.canSubmit}
            />
          )}
          <HistoryCard
            headingId="processed-heading"
            title="Completed"
            archive="_Processed"
            items={completedItems}
            filesBaseUrl={filesBaseUrl}
            canRequeue={canRequeue}
            requeues={requeues}
            dismissed={dismissed.value}
            onDismiss$={dismiss}
            onShowLog$={(name) => (logDialog.value = name)}
            onRequeue$={requeue}
          />
          <HistoryCard
            headingId="failed-heading"
            title="Failed"
            archive="_Failed"
            items={failedItems}
            filesBaseUrl={filesBaseUrl}
            canRequeue={canRequeue}
            requeues={requeues}
            dismissed={dismissed.value}
            onDismiss$={dismiss}
            onShowLog$={(name) => (logDialog.value = name)}
            onRequeue$={requeue}
          />
        </aside>
      )}
    </section>
  );
});

/** Per-disc rename draft, keyed by the ISO's current name. */
type HeldDraft = { value: string; busy?: boolean; error?: string };

/**
 * Confirm one held disc by giving its ISO the episode name the importer
 * publishes from. The server checks the name and episode count; the file
 * broker renames it, so the result appears on a later refresh.
 */
const HeldDiscConfirm = component$<{
  iso: InboxIso;
  drafts: Record<string, HeldDraft>;
}>((props) => {
  const iso = props.iso;
  const rename = iso.rename;
  const fieldId = `held-name-${encodeURIComponent(iso.name)}`;
  if (rename?.state === "queued")
    return <p class="side-item-status">Renaming to {rename.name}…</p>;
  if (rename?.state === "applied")
    return (
      <p class="side-item-status">
        Renamed. The importer publishes its videos when it is next idle.
      </p>
    );
  const draft = props.drafts[iso.name];
  const value =
    draft?.value ??
    (rename?.state === "failed"
      ? rename.name
      : (iso.suggestedName ?? iso.name));
  // Once the person edits the name, the broker's earlier refusal no longer
  // describes it; only the draft's own error shows.
  const error = draft
    ? draft.error
    : rename?.state === "failed"
      ? rename.error
      : undefined;
  return (
    <form
      class="held-confirm"
      preventdefault:submit
      onSubmit$={async () => {
        const newName = value.trim();
        if (!newName || draft?.busy) return;
        const pending: HeldDraft = { value, busy: true };
        props.drafts[iso.name] = pending;
        try {
          await api("/conversions/inbox/identify", {
            method: "POST",
            body: JSON.stringify({
              name: iso.name,
              sizeBytes: iso.sizeBytes,
              modifiedNs: iso.modifiedNs,
              newName,
            }),
          });
          // Shown until the next refresh reports the queued rename itself.
          iso.rename = { state: "queued", name: newName };
          delete props.drafts[iso.name];
        } catch (failure) {
          props.drafts[iso.name] = { value, error: readableError(failure) };
        }
      }}
    >
      <label for={fieldId}>ISO name</label>
      <div class="held-confirm__row">
        <input
          id={fieldId}
          type="text"
          value={value}
          spellcheck={false}
          autoComplete="off"
          maxLength={200}
          aria-invalid={error ? "true" : undefined}
          aria-describedby={error ? `${fieldId}-error` : undefined}
          onInput$={(_, el) => {
            props.drafts[iso.name] = { value: el.value };
          }}
        />
        <button
          type="submit"
          class="secondary-button"
          disabled={draft?.busy || !value.trim()}
        >
          {draft?.busy ? "Accepting…" : "Accept"}
        </button>
      </div>
      {error && (
        <p
          id={`${fieldId}-error`}
          class="message error side-item-error"
          role="alert"
        >
          {error}
        </p>
      )}
    </form>
  );
});

/**
 * TV discs the importer encoded but held back because it could not match
 * their episodes. Shown only while some exist: it is a to-do list, unlike
 * the Completed and Failed history.
 */
const NeedsIdentificationCard = component$<{
  isos: InboxIso[];
  filesBaseUrl: string;
  canRename: boolean;
}>((props) => {
  const folder = "_ISO/_DVDs/_NeedsIdentification";
  const drafts = useStore<Record<string, HeldDraft>>({});
  const folderLink = props.filesBaseUrl ? (
    <a
      href={`${props.filesBaseUrl}/files/_Shared/${sharedPath(folder)}/`}
      target="_blank"
      rel="noopener noreferrer"
    >
      {folder}
    </a>
  ) : (
    <code>{folder}</code>
  );
  return (
    <section class="panel side-panel">
      <div class="panel-heading">
        <div>
          <h2 id="identify-heading">Process, needs identifying</h2>
        </div>
      </div>
      <div
        class="side-panel-body"
        role="region"
        aria-labelledby="identify-heading"
        tabIndex={0}
      >
        {props.canRename ? (
          <p class="side-panel-instruction">
            Name each disc with the show, season and episodes, such as{" "}
            <code>Show (1978) S01E05-E06.iso</code>, and accept it, or rename
            the ISO in {folderLink}. Within a minute its videos move into the TV
            library without re-encoding.
          </p>
        ) : (
          <p class="side-panel-instruction">
            Rename the ISO in {folderLink} to the show, season and episodes,
            such as <code>Show (1978) S01E05-E06.iso</code>. Within a minute its
            videos move into the TV library without re-encoding.
          </p>
        )}
        <ul class="side-list">
          {props.isos.map((iso) => {
            const title = isoTitle(iso);
            const fileDiffers = iso.name.replace(/\.iso$/i, "") !== title;
            const detail = [
              fileDiffers ? iso.name : "",
              iso.finishedNs ? `Held ${finishedAt(iso)}` : "",
            ]
              .filter(Boolean)
              .join(" · ");
            return (
              <li key={iso.name}>
                <span class="side-item-name" title={iso.name}>
                  <strong>{title}</strong>
                  {detail && <small>{detail}</small>}
                </span>
                {iso.summary && <p class="side-item-reason">{iso.summary}</p>}
                {props.canRename ? (
                  <HeldDiscConfirm iso={iso} drafts={drafts} />
                ) : (
                  iso.suggestedName && (
                    <p class="side-item-suggestion">
                      Suggested name: <code>{iso.suggestedName}</code>
                    </p>
                  )
                )}
                {iso.heldDir && props.filesBaseUrl ? (
                  <a
                    class="side-item-link"
                    href={`${props.filesBaseUrl}/files/_Shared/${sharedPath(iso.heldDir)}`}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    <Icon name="folder" size={14} />
                    <span>{iso.heldDir}</span>
                  </a>
                ) : iso.heldDir ? (
                  <span class="side-item-path">
                    <Icon name="folder" size={14} />
                    <span>{iso.heldDir}</span>
                  </span>
                ) : null}
              </li>
            );
          })}
        </ul>
      </div>
    </section>
  );
});

/** How long recently finished work stays in the main Completed and Failed lists. */
const HISTORY_WINDOW_MS = 3 * 24 * 60 * 60 * 1000;

type HistoryItem =
  | {
      kind: "transcript";
      key: string;
      finishedMs: number;
      job: TranscriptionJob;
    }
  | { kind: "iso"; key: string; finishedMs: number; iso: InboxIso };

/** Discs and transcripts that finished, newest first, from either archive. */
function historyItems(
  isos: InboxIso[],
  transcripts: TranscriptionJob[],
): HistoryItem[] {
  const items: HistoryItem[] = [
    ...isos.map((iso) => {
      const finished = iso.finishedNs ?? iso.modifiedNs;
      return {
        kind: "iso" as const,
        key: `iso:${iso.name}:${finished}`,
        finishedMs: Math.floor(finished / 1e6),
        iso,
      };
    }),
    ...transcripts.map((job) => ({
      kind: "transcript" as const,
      key: `transcript:${job.id}`,
      // Job records use seconds; the list is ordered and aged in milliseconds.
      finishedMs: job.updatedAt * 1000,
      job,
    })),
  ];
  return items.sort((left, right) => right.finishedMs - left.finishedMs);
}

/**
 * Completed or Failed history. Work from the last three days stays visible;
 * older work folds behind one disclosure so the panels stay a useful recent
 * log. Each entry can be dismissed, which hides it in this browser without
 * touching the archived ISO or the transcript files.
 */
const HistoryCard = component$<{
  headingId: string;
  title: string;
  archive: DvdArchive;
  items: HistoryItem[];
  filesBaseUrl: string;
  canRequeue: boolean;
  requeues: Requeues;
  dismissed: string[];
  onDismiss$: QRL<(key: string) => void>;
  onShowLog$: QRL<(name: string) => void>;
  onRequeue$: QRL<(archive: DvdArchive, iso: InboxIso) => void>;
}>((props) => {
  const cutoff = Date.now() - HISTORY_WINDOW_MS;
  const visible = props.items.filter(
    (item) => !props.dismissed.includes(item.key),
  );
  const recent = visible.filter((item) => item.finishedMs >= cutoff);
  const older = visible.filter((item) => item.finishedMs < cutoff);
  const failed = props.archive === "_Failed";
  // An empty history says nothing worth a panel; it appears with its first result.
  if (visible.length === 0) return null;

  const Dismiss = (item: HistoryItem) => (
    <button
      type="button"
      class="text-button side-item-dismiss"
      aria-label={`Dismiss ${item.kind === "iso" ? isoTitle(item.iso) : item.job.name}`}
      onClick$={() => props.onDismiss$(item.key)}
    >
      Dismiss
    </button>
  );

  const Rows = (items: HistoryItem[]) => (
    <ul class="side-list">
      {items.map((item) =>
        item.kind === "transcript" ? (
          <li key={item.key} class="transcript-job">
            <div class="side-item-name">
              <strong>{item.job.name}</strong>
              <small>
                {backendLabel(item.job)}
                {failed
                  ? ` · ${item.job.error?.replaceAll("_", " ") ?? "Transcription failed"}`
                  : ""}
              </small>
              {!failed && (
                <div class="transcript-artifacts">
                  {item.job.artifacts?.map((file) => (
                    <a
                      key={file}
                      href={`/api/v1/transcriptions/${encodeURIComponent(item.job.id)}/artifacts/${encodeURIComponent(file)}`}
                    >
                      {file}
                    </a>
                  ))}
                </div>
              )}
              {!failed && !!item.job.ignored?.length && (
                <details>
                  <summary>Some options were ignored</summary>
                  <ul>
                    {item.job.ignored.map((warning) => (
                      <li key={warning.field}>
                        {warning.field}: {warning.reason}
                      </li>
                    ))}
                  </ul>
                </details>
              )}
            </div>
            <div class="side-item-actions">{Dismiss(item)}</div>
          </li>
        ) : (
          <li key={item.key}>
            <span class="side-item-name" title={item.iso.name}>
              <strong>{isoTitle(item.iso)}</strong>
              {item.iso.finishedNs ? (
                <small>
                  {failed ? "Failed" : "Finished"} {finishedAt(item.iso)}
                </small>
              ) : null}
            </span>
            {failed && item.iso.failureSummary && (
              <p class="side-item-reason">{item.iso.failureSummary}</p>
            )}
            <div class="side-item-actions">
              {failed ? (
                <>
                  {item.iso.hasErrorLog && (
                    <button
                      type="button"
                      class="text-button danger side-item-log-btn"
                      aria-label={`${item.iso.failureHint ? "How to fix" : "Show details for"} ${isoTitle(item.iso)}`}
                      onClick$={() => props.onShowLog$(item.iso.name)}
                    >
                      {item.iso.failureHint ? "How to fix" : "Show details"}
                    </button>
                  )}
                </>
              ) : item.iso.outputDir && props.filesBaseUrl ? (
                <a
                  class="side-item-link"
                  href={`${props.filesBaseUrl}/files/_Shared/${sharedPath(item.iso.outputDir)}`}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  <Icon name="folder" size={14} />
                  <span>{item.iso.outputDir}</span>
                </a>
              ) : item.iso.outputDir ? (
                <span class="side-item-path">
                  <Icon name="folder" size={14} />
                  <span>{item.iso.outputDir}</span>
                </span>
              ) : null}
              {props.canRequeue && (
                <RequeueAction
                  iso={item.iso}
                  archive={props.archive}
                  requeues={props.requeues}
                  onRequeue$={props.onRequeue$}
                />
              )}
              {Dismiss(item)}
            </div>
          </li>
        ),
      )}
    </ul>
  );

  return (
    <section class="panel side-panel">
      <div class="panel-heading">
        <div>
          <h2 id={props.headingId}>{props.title}</h2>
        </div>
      </div>
      <div
        class="side-panel-body"
        role="region"
        aria-labelledby={props.headingId}
        tabIndex={0}
      >
        {recent.length > 0 && Rows(recent)}
        {older.length > 0 && (
          <details class="history-archive">
            <summary>Older than 3 days ({older.length})</summary>
            {Rows(older)}
          </details>
        )}
      </div>
    </section>
  );
});
