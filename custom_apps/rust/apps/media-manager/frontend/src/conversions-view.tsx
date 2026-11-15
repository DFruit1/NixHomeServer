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
  TranscriptionEnvelope,
  TranscriptionJob,
} from "./api-contract.generated";
import {
  ConversionInput,
  type ConversionTask,
  RecentSubmissions,
} from "./conversion-input";
import type {
  ConversionInputAccepted,
  ConversionInputs,
} from "./api-contract.generated";
import { ComicConversions } from "./comic-conversions";
import { VideoConversions } from "./video-conversions";
import { Icon } from "./icon";
import type {
  Conversion,
  ConversionEnvelope,
  ConversionInbox,
  IconName,
  InboxIso,
} from "./root-types";
import { EmptyState } from "./view-states";

/** Encode each segment of a shared-folder path for a Files link. */
const sharedPath = (path: string) =>
  path.split("/").map(encodeURIComponent).join("/");

const ConversionList = component$<{
  conversion: Conversion;
  queuedEntry: QueuedConversion[];
}>((props) => {
  const hasQueued = props.queuedEntry.length > 0;
  const hasActive = !!(props.conversion?.title || props.conversion?.sourceIso);
  if (!hasActive && !hasQueued) {
    return (
      <EmptyState
        title="No DVDs being converted"
        detail="Choose a disc image above to start."
      />
    );
  }
  const percent = Math.max(0, Math.min(100, props.conversion.percent ?? 0));
  const isoName = props.conversion.sourceIso ?? "";
  return (
    <div class="conversion-list">
      {props.conversion.title && (
        <article class="conversion-card">
          <span class="conversion-symbol" aria-hidden="true">
            <Icon name="disc" size={28} />
          </span>
          <div class="conversion-copy">
            <h3>{props.conversion.title}</h3>
            <p>
              {[
                isoName,
                props.conversion.detail || "Encoding a Jellyfin-compatible MKV",
              ]
                .filter(Boolean)
                .join(" · ")}
            </p>
            <div class="progress-row">
              <div
                class="progress-track"
                role="progressbar"
                aria-label={`Converting ${props.conversion.title}`}
                aria-valuemin={0}
                aria-valuemax={100}
                aria-valuenow={percent}
              >
                <span style={{ transform: `scaleX(${percent / 100})` }} />
              </div>
              <strong class="tabular" aria-hidden="true">
                {percent.toFixed(0)}%
              </strong>
            </div>
          </div>
        </article>
      )}
      {hasQueued && (
        <div
          class="conversion-queue"
          aria-label={`${props.queuedEntry.length} DVD discs waiting`}
        >
          <span class="conversion-queue__heading">
            In queue ({props.queuedEntry.length})
          </span>
          <ol class="conversion-queue__list">
            {props.queuedEntry.map((item, index) => (
              <li key={`${item.isoName}-${index}`}>
                <span class="conversion-queue__number">{index + 1}.</span>
                <span class="conversion-queue__title" title={item.isoName}>
                  {item.title}
                  {item.isoName.replace(/\.iso$/i, "") !== item.title && (
                    <span class="conversion-queue__file">
                      {" "}
                      ({item.isoName})
                    </span>
                  )}
                </span>
              </li>
            ))}
          </ol>
        </div>
      )}
    </div>
  );
});

type ConversionsTask = ConversionTask | "comics" | "videos";

/** What each reported transcription stage is doing, in plain language. */
const TRANSCRIPT_STAGES: Record<TranscriptionJob["state"], string> = {
  queued: "Waiting",
  extracting: "Extracting audio",
  transcribing: "Transcribing",
  diarising: "Finding speakers",
  writing: "Writing transcript files",
  completed: "Finished",
  failed: "Failed",
};

const backendLabel = (job: TranscriptionJob) =>
  job.backend === "parakeet" ? "Parakeet" : "Whisper";

/**
 * One running transcript. The bar shows the engine's own decoded position, so
 * a stage that reports no percentage (speaker detection) stays unmeasured
 * rather than showing an invented number.
 */
const TranscriptProgress = component$<{ job: TranscriptionJob }>((props) => {
  const percent =
    typeof props.job.progress === "number"
      ? Math.max(0, Math.min(100, props.job.progress))
      : null;
  const stage = TRANSCRIPT_STAGES[props.job.state];
  return (
    <article class="conversion-card transcript-card">
      <span class="conversion-symbol" aria-hidden="true">
        <Icon name="mic" size={28} />
      </span>
      <div class="conversion-copy">
        <h3>{props.job.name}</h3>
        <p>
          {backendLabel(props.job)} · {stage}
        </p>
        {props.job.state !== "queued" && (
          <div class="progress-row">
            <div
              class="progress-track"
              role="progressbar"
              aria-label={`${stage} ${props.job.name}`}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={percent ?? undefined}
              aria-valuetext={percent === null ? stage : `${percent}%`}
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
            {percent !== null && (
              <strong class="tabular" aria-hidden="true">
                {percent}%
              </strong>
            )}
          </div>
        )}
      </div>
    </article>
  );
});

const tasks: {
  id: ConversionsTask;
  icon: IconName;
  title: string;
  detail: string;
}[] = [
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
    title: "Make comics editable",
    detail: "Convert CBR comics to CBZ so their details can be edited.",
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
  }>({
    conversions: props.initial,
    inbox: undefined,
    error: "",
    transcriptionError: "",
    inputError: "",
  });
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

  useTask$(({ cleanup, track }) => {
    const transcribe = track(() => props.transcriptionAvailable);
    let stopped = false;
    const load = async () => {
      const [inputs, conversions, inbox, transcription] =
        await Promise.allSettled([
          api<ConversionInputs>("/conversions/jobs"),
          api<ConversionEnvelope>("/conversions"),
          api<ConversionInbox>("/conversions/inbox"),
          transcribe
            ? api<TranscriptionEnvelope>("/transcriptions")
            : Promise.resolve(undefined),
        ]);
      if (stopped) return;
      if (inputs.status === "fulfilled") {
        conv.inputs = inputs.value;
        conv.inputError = "";
      } else conv.inputError = readableError(inputs.reason);
      if (conversions.status === "fulfilled")
        conv.conversions = conversions.value;
      if (inbox.status === "fulfilled") conv.inbox = inbox.value;
      conv.error = [conversions, inbox]
        .flatMap((result) =>
          result.status === "rejected" ? [readableError(result.reason)] : [],
        )
        .join(" ");
      if (transcription.status === "fulfilled") {
        conv.transcriptions = transcription.value;
        conv.transcriptionError = "";
      } else if (
        transcription.reason instanceof ApiError &&
        transcription.reason.status === 503
      ) {
        conv.transcriptions = undefined;
        conv.transcriptionError = "Transcription is currently unavailable.";
      } else conv.transcriptionError = readableError(transcription.reason);
    };
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      await load();
      if (!stopped && typeof window !== "undefined")
        timer = setTimeout(tick, 5000);
    };
    void tick();
    cleanup(() => {
      stopped = true;
      clearTimeout(timer);
    });
  });

  const activeConversions = conv.conversions?.progress.conversions ?? [];
  const progressQueued = conv.conversions?.progress.queued ?? [];
  const working = activeConversions.length > 0;
  const inboxReady = conv.inbox?.available ?? false;

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
        title: match.volumeId || cleanStem,
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
        title: iso.volumeId || stem,
        isoName: iso.name,
      });
    }
  }

  const showDvd = task.value === "dvd" || working || queuedEntries.length > 0;
  const showTranscription =
    !!props.transcriptionAvailable &&
    (task.value === "transcribe" ||
      task.value === "subtitles" ||
      activeTranscripts.length > 0);

  const canRequeue =
    !!conv.inputs?.canSubmit &&
    !!conv.inputs.roots.some((r) => r.id === "dvd-inbox");
  const dvdLink = filesBaseUrl
    ? `${filesBaseUrl}/files/_Shared/_ISO/_DVDs/`
    : "";
  const failedIso = logDialog.value
    ? inboxFailed.find((iso) => iso.name === logDialog.value)
    : undefined;

  return (
    <section class="conversions-layout">
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
        {task.value === "comics" && (
          <ComicConversions canEdit={props.canEdit ?? false} />
        )}
        {task.value === "videos" && (
          <VideoConversions initialItemId={props.initialItemId} />
        )}
        {task.value && task.value !== "comics" && task.value !== "videos" && (
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
        {showDvd && (
          <section class="panel conversion-focus" aria-labelledby="dvd-heading">
            <header class="panel-heading">
              <h2 id="dvd-heading">DVD conversions</h2>
              <span class="conversion-state">
                {working ? "Converting" : "Idle"}
              </span>
            </header>
            {activeConversions.length ? (
              activeConversions.map((conversion, index) => (
                <ConversionList
                  key={conversion.sourceIso ?? index}
                  conversion={conversion}
                  queuedEntry={
                    index === activeConversions.length - 1 ? queuedEntries : []
                  }
                />
              ))
            ) : (
              <ConversionList
                conversion={{} as Conversion}
                queuedEntry={queuedEntries}
              />
            )}
            <details class="conversion-help">
              <summary>How to add DVDs</summary>
              <div class="setup-body">
                <p class="setup-ready">
                  {inboxReady
                    ? "The converter is watching "
                    : "Copy a DVD ISO into "}
                  {dvdLink ? (
                    <a href={dvdLink} target="_blank" rel="noopener noreferrer">
                      the shared inbox
                    </a>
                  ) : (
                    "the shared inbox"
                  )}
                  .
                </p>
                <ol class="setup-steps">
                  <li>
                    Copy a DVD ISO into the shared inbox at _Shared/_ISO/_DVDs.
                  </li>
                  <li>
                    Leave the ISO untouched for about one minute so the server
                    picks it up.
                  </li>
                  <li>
                    Finished films appear in the shared video library. Source
                    ISOs move to _Processed, or to _Failed after repeated
                    failures. TV discs whose episodes cannot be identified wait
                    in _NeedsIdentification until you rename them.
                  </li>
                  <li>
                    ISO files in the queue can be safely renamed or moved, but
                    do not modify any file that is actively being converted.
                  </li>
                </ol>
              </div>
            </details>
          </section>
        )}
        {showTranscription && (
          <section
            class="panel transcription-panel"
            aria-labelledby="transcription-heading"
          >
            <header class="panel-heading">
              <h2 id="transcription-heading">Audio transcription</h2>
            </header>
            <div class="transcription-body">
              {conv.transcriptionError && (
                <p class="message error" role="alert">
                  {conv.transcriptionError}
                </p>
              )}
              {activeTranscripts.length === 0 ? (
                <p class="quiet-copy">No transcription jobs waiting.</p>
              ) : (
                <div class="transcript-progress-list">
                  {activeTranscripts.map((job) => (
                    <TranscriptProgress key={job.id} job={job} />
                  ))}
                </div>
              )}
            </div>
            <details class="conversion-help">
              <summary>Use a watched folder instead</summary>
              <div class="setup-body">
                <p>
                  Audio and video placed in your{" "}
                  <code>_Transcribe/parakeet/</code> or{" "}
                  <code>_Transcribe/whisper/</code> folder are picked up
                  automatically after a minute. Results are saved in{" "}
                  <code>_Transcripts/</code>; sources are retained.
                </p>
              </div>
            </details>
          </section>
        )}
        <RecentSubmissions jobs={conv.inputs?.jobs ?? []} />
      </div>
      <aside class="conv-sidebar">
        {inboxNeedsIdentification.length > 0 && (
          <NeedsIdentificationCard
            isos={inboxNeedsIdentification}
            filesBaseUrl={filesBaseUrl}
          />
        )}
        <HistoryCard
          headingId="processed-heading"
          title="Completed"
          empty="No completed jobs yet."
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
          empty="No failed jobs."
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
    </section>
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
}>((props) => {
  const folder = "_ISO/_DVDs/_NeedsIdentification";
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
        <p class="side-panel-instruction">
          Rename the ISO in{" "}
          {props.filesBaseUrl ? (
            <a
              href={`${props.filesBaseUrl}/files/_Shared/${sharedPath(folder)}/`}
              target="_blank"
              rel="noopener noreferrer"
            >
              {folder}
            </a>
          ) : (
            <code>{folder}</code>
          )}{" "}
          to the show, season and episodes, such as{" "}
          <code>Show (1978) S01E05-E06.iso</code>. Within a minute its videos
          move into the TV library without re-encoding.
        </p>
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
                {iso.suggestedName && (
                  <p class="side-item-suggestion">
                    Suggested name: <code>{iso.suggestedName}</code>
                  </p>
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
  empty: string;
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
        {visible.length === 0 ? (
          <p class="quiet-copy">
            {props.items.length > 0 ? "All results dismissed." : props.empty}
          </p>
        ) : (
          <>
            {recent.length > 0 && Rows(recent)}
            {older.length > 0 && (
              <details class="history-archive">
                <summary>Older than 3 days ({older.length})</summary>
                {Rows(older)}
              </details>
            )}
          </>
        )}
      </div>
    </section>
  );
});
