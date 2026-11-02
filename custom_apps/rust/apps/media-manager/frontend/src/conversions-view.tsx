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
  expanded?: boolean;
}>((props) => {
  const hasQueued = props.queuedEntry.length > 0;
  const hasActive = !!(props.conversion?.title || props.conversion?.sourceIso);
  if (!hasActive && !hasQueued) {
    return (
      <EmptyState
        title="No ISO files being converted"
        detail="Drop an ISO into the shared inbox to start a conversion."
      />
    );
  }
  const percent = Math.max(0, Math.min(100, props.conversion.percent ?? 0));
  const isoName = props.conversion.sourceIso ?? "";
  return (
    <div class={{ "conversion-list": true, expanded: props.expanded }}>
      {props.conversion.title && (
        <article class="conversion-card">
          <div class="disc-visual">
            <span />
            <span />
          </div>
          <div class="conversion-copy">
            <h4>{props.conversion.title}</h4>
            <p>
              Converting {isoName}{" "}
              {props.conversion.detail
                ? `— ${props.conversion.detail}`
                : "— Encoding a Jellyfin-compatible MKV"}
            </p>
            <div class="progress-track" aria-label={`${percent}% complete`}>
              <span style={{ transform: `scaleX(${percent / 100})` }} />
            </div>
            <div class="progress-meta">
              <span>Converting</span>
              <strong class="tabular">{percent.toFixed(0)}%</strong>
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
                  {item.title}{" "}
                  <span class="conversion-queue__file">({item.isoName})</span>
                </span>
              </li>
            ))}
          </ol>
        </div>
      )}
    </div>
  );
});

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
  }>({
    conversions: props.initial,
    inbox: undefined,
    error: "",
    transcriptionError: "",
  });
  const logDialog = useSignal<string>("");

  useTask$(({ cleanup, track }) => {
    const transcribe = track(() => props.transcriptionAvailable);
    let stopped = false;
    const load = async () => {
      try {
        const [conversions, inbox] = await Promise.all([
          api<ConversionEnvelope>("/conversions"),
          api<ConversionInbox>("/conversions/inbox"),
        ]);
        if (stopped) return;
        conv.conversions = conversions;
        conv.inbox = inbox;
        conv.error = "";
        if (transcribe) {
          try {
            const result = await api<TranscriptionEnvelope>("/transcriptions");
            if (!stopped) {
              conv.transcriptions = result;
              conv.transcriptionError = "";
            }
          } catch (error) {
            if (!stopped) {
              if (error instanceof ApiError && error.status === 503)
                conv.transcriptions = undefined;
              else conv.transcriptionError = readableError(error);
            }
          }
        }
      } catch (error) {
        if (!stopped) conv.error = readableError(error);
      }
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
  const statusLabel = working ? "Working" : "Idle";

  const inboxPending = conv.inbox?.pending ?? [];
  const inboxProcessed = conv.inbox?.processed ?? [];
  const inboxFailed = conv.inbox?.failed ?? [];
  const filesBaseUrl = conv.inbox?.filesBaseUrl ?? "";
  const transcripts = conv.transcriptions?.jobs ?? [];
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
          <button type="button" onClick$={() => (conv.error = "")}>
            ×
          </button>
        </div>
      )}
      <div class="conv-main">
        {props.transcriptionAvailable && (
          <section class="panel transcription-panel">
            <div class="panel-heading">
              <h3>Audio transcription</h3>
            </div>
            <div class="setup-body">
              <p class="setup-ready">
                Drop audio or video into your <code>_Transcribe/parakeet/</code>{" "}
                or <code>_Transcribe/whisper/</code> folder. Files must stay
                unchanged for one minute. Results appear in{" "}
                <code>_Transcripts/</code>; your source is retained.
              </p>
              <details class="transcript-options">
                <summary>Subtitle and speaker options</summary>
                <p>
                  For <code>lecture.wav</code>, save{" "}
                  <code>lecture.transcribe.request.json</code> first, then copy
                  the media file:
                </p>
                <pre>
                  {JSON.stringify(
                    {
                      version: 1,
                      output: { formats: ["txt", "srt", "vtt"], diarize: true },
                    },
                    null,
                    2,
                  )}
                </pre>
                <p>
                  Whisper also accepts language and vocabulary hints.
                  Unsupported options appear with the result.
                </p>
              </details>
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
          </section>
        )}
        <section class="panel">
          <div class="panel-heading">
            <div>
              <h3>DVD ISO converter</h3>
            </div>
            <span
              class={{
                "status-badge": true,
                live: working,
              }}
            >
              {statusLabel}
            </span>
          </div>
          <div class="setup-body">
            {inboxReady ? (
              <p class="setup-ready">
                The converter is watching{" "}
                {dvdLink ? (
                  <a href={dvdLink} target="_blank" rel="noopener noreferrer">
                    the shared inbox
                  </a>
                ) : (
                  "the shared inbox"
                )}
                .
                {working
                  ? " An ISO is being converted right now."
                  : " Drop an ISO in the inbox to start a conversion."}
              </p>
            ) : (
              <p class="setup-missing">
                No ISO files are queued for conversion at the moment. Copy a DVD
                ISO into the shared inbox at _Shared/_ISO/_DVDs to start a
                conversion.
              </p>
            )}
            <ol class="setup-steps">
              <li>
                Copy a DVD ISO into the shared inbox at _Shared/_ISO/_DVDs.
              </li>
              <li>
                Leave the ISO untouched for about one minute so the server picks
                it up.
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
        </section>
        <section class="panel">
          <div class="panel-heading">
            <div>
              <h3>Active conversions</h3>
            </div>
            <span class={{ "status-badge": true, live: working }}>
              {working ? "Working" : "Idle"}
            </span>
          </div>
          <ConversionList
            conversion={activeConversions[0] ?? ({} as Conversion)}
            queuedEntry={queuedEntries}
            expanded
          />
        </section>
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
        <h3 id="processed-heading">Processed</h3>
        <small>Completed conversions and transcripts</small>
      </div>
    </div>
    <div
      class="side-panel-body"
      role="region"
      aria-labelledby="processed-heading"
      tabIndex={0}
    >
      {props.isos.length === 0 && props.transcripts.length === 0 ? (
        <p class="quiet-copy">Nothing has been processed yet.</p>
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
              <span class="side-item-name">
                <strong>{iso.volumeId || iso.name}</strong>
                <small>{iso.name}</small>
              </span>
              {iso.outputDir && props.filesBaseUrl ? (
                <a
                  class="side-item-link"
                  href={`${props.filesBaseUrl}/files/_Shared/${iso.outputDir}`}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  <Icon name="folder" size={12} />
                  &ensp;Open output
                </a>
              ) : iso.outputDir ? (
                <span class="side-item-path">
                  <Icon name="folder" size={12} />
                  &ensp;
                  {iso.outputDir}
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
        <h3 id="failed-heading">Failed</h3>
        <small>Conversions and transcripts needing attention</small>
      </div>
    </div>
    <div
      class="side-panel-body"
      role="region"
      aria-labelledby="failed-heading"
      tabIndex={0}
    >
      {props.isos.length === 0 && props.transcripts.length === 0 ? (
        <p class="quiet-copy">No failed conversions.</p>
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
              <span class="side-item-name">
                <strong>{iso.volumeId || iso.name}</strong>
                <small>{iso.name}</small>
              </span>
              {iso.hasErrorLog && (
                <button
                  type="button"
                  class="side-item-log-btn"
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

function formatModified(modifiedNs: number): string {
  if (!Number.isFinite(modifiedNs) || modifiedNs <= 0) return "—";
  return new Date(modifiedNs / 1e6).toLocaleString(undefined, {
    dateStyle: "medium",
    timeStyle: "short",
  });
}
