import {
  component$,
  type QRL,
  useSignal,
  useStore,
  useTask$,
} from "@builder.io/qwik";
import { api, ApiError, readableError } from "./api";
import type {
  TranscriptionEnvelope,
  TranscriptionJob,
} from "./api-contract.generated";
import { ConversionInput } from "./conversion-input";
import type { ConversionInputs } from "./api-contract.generated";
import { Icon } from "./icon";
import type {
  Conversion,
  ConversionEnvelope,
  ConversionInbox,
  InboxIso,
} from "./root-types";
import { EmptyState } from "./view-states";

const ConversionList = component$<{
  conversion: Conversion;
  queuedEntry: QueuedConversion[];
}>((props) => {
  const hasQueued = props.queuedEntry.length > 0;
  const hasActive = !!(props.conversion?.title || props.conversion?.sourceIso);
  if (!hasActive && !hasQueued) {
    return (
      <EmptyState
        title="No ISO files being converted"
        detail="Choose a server file or upload one above."
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

/** One readable name per disc: the volume label, else the file name without `.iso`. */
function isoTitle(iso: InboxIso): string {
  return iso.volumeId || iso.name.replace(/\.iso$/i, "");
}

interface QueuedConversion {
  title: string;
  isoName: string;
}

const LogDialog = component$<{
  isoName: string;
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
            `/conversions/inbox/error?name=${encodeURIComponent(props.isoName)}`,
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
        aria-label={`Error log for ${props.isoName}`}
        onClick$={(e) => e.stopPropagation()}
      >
        <div class="dialog-header">
          <h3>Conversion Error Log</h3>
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
          <p class="dialog-iso-name">
            <strong>{props.isoName}</strong>
          </p>
          {loading.value ? (
            <p class="quiet-copy">Loading log…</p>
          ) : error.value ? (
            <p class="message error" role="alert">
              {error.value}
            </p>
          ) : (
            <pre class="log-content">{log.value}</pre>
          )}
        </div>
      </div>
    </div>
  );
});

export const ConversionsView = component$<{
  initial?: ConversionEnvelope;
  transcriptionAvailable?: boolean;
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

  const dvdLink = filesBaseUrl
    ? `${filesBaseUrl}/files/_Shared/_ISO/_DVDs/`
    : "";

  return (
    <section class="conversions-layout">
      {logDialog.value && (
        <LogDialog
          isoName={logDialog.value}
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
        <ConversionInput
          inputs={conv.inputs}
          error={conv.inputError}
          transcriptionAvailable={props.transcriptionAvailable}
          onQueued$={(job) => {
            if (conv.inputs) conv.inputs.jobs = [job, ...conv.inputs.jobs];
          }}
        />
        <section class="conversion-focus" aria-labelledby="dvd-heading">
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
                  Finished films appear in the shared video library. Source ISOs
                  move to _Processed, or to _Failed after repeated failures.
                </li>
                <li>
                  ISO files in the queue can be safely renamed or moved, but do
                  not modify any file that is actively being converted.
                </li>
              </ol>
            </div>
          </details>
        </section>
        {props.transcriptionAvailable && (
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
                <ul class="side-list" aria-label="Transcription jobs">
                  {activeTranscripts.map((job) => (
                    <li key={job.id} class="transcript-job">
                      <div class="side-item-name">
                        <strong>{job.name}</strong>
                        <small>
                          {job.backend} · {job.state}
                        </small>
                        {job.state !== "queued" && (
                          <progress aria-label={`${job.state}: ${job.name}`} />
                        )}
                      </div>
                    </li>
                  ))}
                </ul>
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
      </div>
      <aside class="conv-sidebar">
        <ProcessedCard
          isos={inboxProcessed}
          filesBaseUrl={filesBaseUrl}
          transcripts={transcripts.filter((j) => j.state === "completed")}
        />
        <FailedCard
          isos={inboxFailed}
          onShowLog$={(name) => (logDialog.value = name)}
          transcripts={transcripts.filter((j) => j.state === "failed")}
        />
      </aside>
    </section>
  );
});

const ProcessedCard = component$<{
  isos: InboxIso[];
  filesBaseUrl: string;
  transcripts: TranscriptionJob[];
}>((props) => (
  <section class="panel side-panel">
    <div class="panel-heading">
      <div>
        <h2 id="processed-heading">Completed</h2>
      </div>
    </div>
    <div
      class="side-panel-body"
      role="region"
      aria-labelledby="processed-heading"
      tabIndex={0}
    >
      {props.isos.length === 0 && props.transcripts.length === 0 ? (
        <p class="quiet-copy">No completed jobs yet.</p>
      ) : (
        <ul class="side-list">
          {props.transcripts.map((job) => (
            <li key={job.id} class="transcript-job">
              <div class="side-item-name">
                <strong>{job.name}</strong>
                <small>{job.backend}</small>
                <div class="transcript-artifacts">
                  {job.artifacts?.map((file) => (
                    <a
                      key={file}
                      href={`/api/v1/transcriptions/${encodeURIComponent(job.id)}/artifacts/${encodeURIComponent(file)}`}
                    >
                      {file}
                    </a>
                  ))}
                </div>
                {!!job.ignored?.length && (
                  <details>
                    <summary>Some options were ignored</summary>
                    <ul>
                      {job.ignored.map((warning) => (
                        <li key={warning.field}>
                          {warning.field}: {warning.reason}
                        </li>
                      ))}
                    </ul>
                  </details>
                )}
              </div>
            </li>
          ))}
          {props.isos.map((iso) => (
            <li key={iso.name}>
              <span class="side-item-name" title={iso.name}>
                <strong>{isoTitle(iso)}</strong>
              </span>
              {iso.outputDir && props.filesBaseUrl ? (
                <a
                  class="side-item-link"
                  href={`${props.filesBaseUrl}/files/_Shared/${iso.outputDir}`}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  <Icon name="folder" size={14} />
                  <span>{iso.outputDir}</span>
                </a>
              ) : iso.outputDir ? (
                <span class="side-item-path">
                  <Icon name="folder" size={14} />
                  <span>{iso.outputDir}</span>
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </div>
  </section>
));

const FailedCard = component$<{
  isos: InboxIso[];
  onShowLog$: QRL<(name: string) => void>;
  transcripts: TranscriptionJob[];
}>((props) => (
  <section class="panel side-panel">
    <div class="panel-heading">
      <div>
        <h2 id="failed-heading">Failed</h2>
      </div>
    </div>
    <div
      class="side-panel-body"
      role="region"
      aria-labelledby="failed-heading"
      tabIndex={0}
    >
      {props.isos.length === 0 && props.transcripts.length === 0 ? (
        <p class="quiet-copy">No failed jobs.</p>
      ) : (
        <ul class="side-list">
          {props.transcripts.map((job) => (
            <li key={job.id} class="transcript-job">
              <span class="side-item-name">
                <strong>{job.name}</strong>
                <small>
                  {job.backend} ·{" "}
                  {job.error?.replaceAll("_", " ") ?? "Transcription failed"}
                </small>
              </span>
            </li>
          ))}
          {props.isos.map((iso) => (
            <li key={iso.name}>
              <span class="side-item-name" title={iso.name}>
                <strong>{isoTitle(iso)}</strong>
              </span>
              {iso.hasErrorLog && (
                <button
                  type="button"
                  class="text-button danger side-item-log-btn"
                  aria-label={`Show error log for ${isoTitle(iso)}`}
                  onClick$={() => props.onShowLog$(iso.name)}
                >
                  Show log
                </button>
              )}
            </li>
          ))}
        </ul>
      )}
    </div>
  </section>
));
