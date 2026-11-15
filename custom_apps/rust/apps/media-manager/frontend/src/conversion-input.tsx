import {
  component$,
  useSignal,
  useStore,
  useTask$,
  useVisibleTask$,
  $,
  type QRL,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import { useBackLayer } from "./back-layers";
import type {
  ConversionInputs,
  ConversionInputAccepted,
  ConversionInputJob,
  ConversionFiles,
  ConversionInputOptions,
} from "./api-contract.generated";
import { Icon } from "./icon";

export type ConversionTask = "dvd" | "transcribe" | "subtitles";

const ISO_FILE = /\.iso$/i;
const VIDEO_FILE = /\.(mp4|mkv|webm|mov|avi|m4v|mpeg|mpg|ts)$/i;

const taskCopy: Record<
  ConversionTask,
  {
    heading: string;
    browseHeading: string;
    placeholder: string;
    serverNote: string;
    submit: string;
    accept: string;
    nextStep: string;
    afterFinish: string;
  }
> = {
  dvd: {
    heading: "Choose a DVD image",
    browseHeading: "Choose a DVD image on the server",
    placeholder: "Full path to a .iso file",
    serverNote: "Moves into the shared DVD inbox for conversion.",
    submit: "Start conversion",
    accept: ".iso",
    nextStep: "The converted video will appear in the shared video library.",
    afterFinish: "",
  },
  transcribe: {
    heading: "Choose audio or video",
    browseHeading: "Choose audio or video on the server",
    placeholder: "Full path to an audio or video file",
    serverNote: "Your original stays in place.",
    submit: "Generate transcript",
    accept: "audio/*,video/*,.mkv,.m4b,.flac,.opus,.wma,.aiff,.ts",
    nextStep: "Text, SRT and VTT files will appear under Completed.",
    afterFinish: "",
  },
  subtitles: {
    heading: "Choose a video",
    browseHeading: "Choose a video in your library",
    placeholder: "Full path to a video in your library",
    serverNote: "Your original stays in place.",
    submit: "Generate subtitles",
    accept: "",
    nextStep:
      "When it finishes, open the video in Library, expand Subtitles and pick it under Use a transcript.",
    afterFinish:
      "Open the video in Library, expand Subtitles and pick it under Use a transcript.",
  },
};

/** Whether a browser entry can be used for the chosen task. */
function entryFits(task: ConversionTask, name: string, directory: boolean) {
  if (directory) return true;
  if (task === "dvd") return ISO_FILE.test(name);
  if (task === "subtitles") return VIDEO_FILE.test(name);
  return !ISO_FILE.test(name);
}

const jobStateLabels: Record<ConversionInputJob["state"], string> = {
  queued: "Waiting to start",
  submitting: "Copying file",
  processing: "Processing",
  saving: "Saving library copy",
  completed: "Completed",
  failed: "Needs attention",
};

/** Modal folder browser for picking one server file for the chosen task. */
const ServerFileDialog = component$<{
  task: ConversionTask;
  roots: ConversionInputs["roots"];
  initialRootId: string;
  onChoose$: QRL<(path: string) => void>;
  onClose$: QRL<() => void>;
}>((props) => {
  const view = useStore({
    rootId: props.initialRootId,
    folder: "",
    loading: false,
    error: "",
    manualPath: "",
  });
  const listing = useSignal<ConversionFiles>();
  const firstControl = useSignal<HTMLSelectElement>();
  const copy = taskCopy[props.task];
  // Back climbs to the parent folder, then closes the browser.
  const mounted = useSignal(true);
  useBackLayer(
    "server-file-browser",
    mounted,
    $(async () => {
      if (!view.folder) return props.onClose$();
      view.folder = view.folder.split("/").slice(0, -1).join("/");
      return false;
    }),
  );
  useVisibleTask$(() => {
    firstControl.value?.focus();
  });
  useTask$(({ track, cleanup }) => {
    const rootId = track(() => view.rootId);
    const path = track(() => view.folder);
    let stopped = false;
    cleanup(() => {
      stopped = true;
    });
    if (!rootId) return;
    view.loading = true;
    view.error = "";
    listing.value = undefined;
    void api<ConversionFiles>(
      `/conversions/files?${new URLSearchParams({ rootId, path })}`,
    )
      .then((result) => {
        if (!stopped) listing.value = result;
      })
      .catch((error) => {
        if (!stopped) view.error = readableError(error);
      })
      .finally(() => {
        if (!stopped) view.loading = false;
      });
  });
  const entries = (listing.value?.entries ?? []).filter((entry) =>
    entryFits(props.task, entry.name, entry.directory),
  );
  const root = props.roots.find((r) => r.id === view.rootId);
  return (
    <div class="dialog-backdrop" onClick$={props.onClose$}>
      <div
        class="dialog server-file-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="server-file-dialog-heading"
        onClick$={(event) => event.stopPropagation()}
        onKeyDown$={(event) => {
          if (event.key === "Escape") props.onClose$();
        }}
      >
        <div class="dialog-header">
          <h3 id="server-file-dialog-heading">{copy.browseHeading}</h3>
          <button
            type="button"
            class="dialog-close"
            aria-label="Close"
            onClick$={props.onClose$}
          >
            ×
          </button>
        </div>
        <div class="dialog-body server-file-dialog__body">
          <div class="server-file-dialog__place">
            <label class="sr-only" for="server-file-root">
              Folder
            </label>
            <select
              ref={firstControl}
              id="server-file-root"
              value={view.rootId}
              onChange$={(_, el) => {
                view.rootId = el.value;
                view.folder = "";
              }}
            >
              {props.roots.map((r) => (
                <option value={r.id} key={r.id}>
                  {r.label}
                </option>
              ))}
            </select>
            <button
              type="button"
              class="secondary-button"
              disabled={!view.folder}
              onClick$={() => {
                view.folder = view.folder.split("/").slice(0, -1).join("/");
              }}
            >
              Up one folder
            </button>
          </div>
          <p class="server-file-dialog__location">
            {root?.label}
            {view.folder ? ` / ${view.folder.split("/").join(" / ")}` : ""}
          </p>
          {view.error && (
            <p class="message error" role="alert">
              {view.error}
            </p>
          )}
          {view.loading ? (
            <p class="server-file-dialog__note" role="status">
              Loading files…
            </p>
          ) : listing.value && entries.length === 0 ? (
            <p class="server-file-dialog__note">
              No matching files or subfolders.
            </p>
          ) : (
            <ul class="server-file-dialog__list" aria-label="Server files">
              {entries.map((entry) => (
                <li key={entry.name}>
                  <button
                    type="button"
                    class="server-file-dialog__entry"
                    onClick$={async () => {
                      if (entry.directory) {
                        view.folder = [view.folder, entry.name]
                          .filter(Boolean)
                          .join("/");
                        return;
                      }
                      await props.onChoose$(
                        [root?.path, view.folder, entry.name]
                          .filter(Boolean)
                          .join("/"),
                      );
                    }}
                  >
                    <Icon
                      name={entry.directory ? "folder" : "file"}
                      size={18}
                    />
                    <span>{entry.name}</span>
                    {entry.directory && <span class="sr-only"> (folder)</span>}
                  </button>
                </li>
              ))}
            </ul>
          )}
          {listing.value?.truncated && (
            <p class="server-file-dialog__note">
              Showing the first 200 entries. Enter a full path below to choose
              another file.
            </p>
          )}
          <details class="server-file-dialog__manual">
            <summary>Enter a full path instead</summary>
            <form
              class="server-file-dialog__manual-form"
              preventdefault:submit
              onSubmit$={async () => {
                const path = view.manualPath.trim();
                if (!path.startsWith("/")) {
                  view.error = "Enter the full path, starting with /.";
                  return;
                }
                await props.onChoose$(path);
              }}
            >
              <label class="sr-only" for="server-file-manual">
                Full server path
              </label>
              <input
                id="server-file-manual"
                type="text"
                value={view.manualPath}
                placeholder={copy.placeholder}
                onInput$={(_, el) => {
                  view.manualPath = el.value;
                }}
              />
              <button type="submit" class="secondary-button">
                Use path
              </button>
            </form>
          </details>
        </div>
      </div>
    </div>
  );
});

export const ConversionInput = component$<{
  task: ConversionTask;
  inputs?: ConversionInputs;
  transcriptionAvailable?: boolean;
  error?: string;
  onQueued$: QRL<(job: ConversionInputJob) => void>;
  onTask$: QRL<(task: ConversionTask) => void>;
}>((props) => {
  const form = useStore({
    source: "" as "" | "server" | "upload",
    path: "",
    backend: "parakeet",
    diarize: false,
    language: "",
    storageRootId: "",
    storageFolder: "",
    browsing: false,
    busy: false,
    message: "",
    lastJobId: "",
    error: "",
  });
  const fileInput = useSignal<HTMLInputElement>();
  const serverButton = useSignal<HTMLButtonElement>();
  const fileName = useSignal("");
  const resetFeedback = $(() => {
    form.message = "";
    form.lastJobId = "";
    form.error = "";
  });
  // The chosen file is kept across tasks so a misplaced file can move to the
  // matching task; subtitles take library videos only, never uploads.
  useTask$(({ track }) => {
    const task = track(() => props.task);
    form.browsing = false;
    form.error = "";
    if (task === "subtitles" && form.source === "upload") {
      form.source = "";
      fileName.value = "";
      if (fileInput.value) fileInput.value.value = "";
    }
  });
  const closeBrowser = $(() => {
    form.browsing = false;
    serverButton.value?.focus();
  });
  const submittedJob = props.inputs?.jobs.find(
    (job) => job.id === form.lastJobId,
  );
  const selectedName =
    form.source === "upload"
      ? fileName.value
      : form.source === "server"
        ? (form.path.trim().split("/").at(-1) ?? "")
        : "";
  const copy = taskCopy[props.task];
  const kind = props.task === "dvd" ? "iso" : "transcription";
  const selectedIso = ISO_FILE.test(selectedName);
  const wrongFile = !!selectedName && (kind === "iso") !== selectedIso;
  const transcriptionUnavailable =
    kind === "transcription" && !props.transcriptionAvailable;
  const video = VIDEO_FILE.test(selectedName);
  const allRoots = props.inputs?.roots ?? [];
  const videoRoots = allRoots.filter((root) => root.category === "videos");
  const browseRoots =
    props.task === "subtitles" && videoRoots.length ? videoRoots : allRoots;
  const defaultRootId =
    (props.task === "dvd"
      ? browseRoots.find((root) => root.category === "iso")
      : undefined
    )?.id ??
    browseRoots[0]?.id ??
    "";
  const storageRoots = (props.inputs?.roots ?? []).filter((root) =>
    video
      ? root.category === "videos"
      : ["music", "audiobooks", "podcasts"].includes(root.category),
  );
  return (
    <section
      class="panel conversion-input"
      aria-labelledby="conversion-input-heading"
    >
      <header class="panel-heading">
        <h2 id="conversion-input-heading">{copy.heading}</h2>
      </header>
      {props.error && (
        <p class="message error conversion-input__notice" role="alert">
          {props.error}
        </p>
      )}
      {!props.inputs && !props.error ? (
        <p class="conversion-input__notice">Loading available folders…</p>
      ) : props.inputs && !props.inputs.canSubmit ? (
        <p class="conversion-input__notice">
          Adding files requires editor access and enabled changes.
        </p>
      ) : props.inputs ? (
        <form
          class="conversion-input__form"
          preventdefault:submit
          onSubmit$={async () => {
            if (form.busy) return;
            form.error = "";
            form.message = "";
            form.lastJobId = "";
            if (transcriptionUnavailable) {
              form.error = "Transcription is unavailable right now.";
              return;
            }
            if (wrongFile) return;
            const file = fileInput.value?.files?.[0];
            const name =
              form.source === "upload"
                ? file?.name
                : form.path.trim().split("/").at(-1);
            if (
              !name ||
              (form.source === "server" && !form.path.trim().startsWith("/"))
            ) {
              form.error = "Choose a file from the server or upload one.";
              return;
            }
            if (
              form.source === "upload" &&
              file &&
              file.size > (props.inputs?.maxUploadBytes ?? 0)
            ) {
              form.error = "Files must be no larger than 64 GiB.";
              return;
            }
            const options: ConversionInputOptions = {
              name,
              kind,
              backend: form.backend as "parakeet" | "whisper",
              diarize: kind === "transcription" && form.diarize,
              language:
                kind === "transcription" &&
                form.backend === "whisper" &&
                form.language.trim()
                  ? form.language.trim()
                  : null,
              storageRootId:
                form.source === "upload" &&
                kind === "transcription" &&
                form.storageRootId
                  ? form.storageRootId
                  : null,
              storageFolder:
                form.source === "upload" &&
                kind === "transcription" &&
                form.storageRootId
                  ? form.storageFolder.trim()
                  : "",
            };
            form.busy = true;
            try {
              const result =
                form.source === "upload"
                  ? await api<ConversionInputAccepted>(
                      `/conversions/uploads?${new URLSearchParams({ options: JSON.stringify(options) })}`,
                      {
                        method: "POST",
                        headers: { "content-type": "application/octet-stream" },
                        body: file,
                      },
                      60 * 60 * 1000,
                    )
                  : await api<ConversionInputAccepted>(
                      "/conversions/jobs",
                      {
                        method: "POST",
                        body: JSON.stringify({
                          serverPath: form.path.trim(),
                          options,
                        }),
                      },
                      60 * 60 * 1000,
                    );
              form.lastJobId = result.job.id;
              await props.onQueued$(result.job);
              form.message = `${name} is queued. ${copy.nextStep}`;
              if (fileInput.value) fileInput.value.value = "";
              fileName.value = "";
              form.source = "";
              form.path = "";
              form.storageRootId = "";
              form.storageFolder = "";
            } catch (error) {
              form.error = readableError(error);
            } finally {
              form.busy = false;
            }
          }}
        >
          <fieldset disabled={form.busy} class="conversion-input__fields">
            <legend class="sr-only">File and processing options</legend>
            <div
              class="conversion-source"
              role="group"
              aria-label="Choose a file"
            >
              <button
                ref={serverButton}
                type="button"
                class="conversion-source__option"
                aria-haspopup="dialog"
                onClick$={() => {
                  form.browsing = true;
                }}
              >
                <Icon name="folder" size={22} />
                <span>
                  <strong>
                    {props.task === "subtitles"
                      ? "Choose from library"
                      : "Choose from server"}
                  </strong>
                  <small>Browse the server's folders</small>
                </span>
              </button>
              {props.task !== "subtitles" && (
                <>
                  <input
                    ref={fileInput}
                    id="conversion-upload"
                    class="sr-only conversion-source__file"
                    type="file"
                    accept={copy.accept}
                    onChange$={async (_, el) => {
                      const name = el.files?.[0]?.name ?? "";
                      if (!name) return;
                      form.source = "upload";
                      fileName.value = name;
                      form.storageRootId = "";
                      form.storageFolder = "";
                      await resetFeedback();
                    }}
                  />
                  <label
                    for="conversion-upload"
                    class="conversion-source__option"
                  >
                    <Icon name="upload" size={22} />
                    <span>
                      <strong>Upload from this device</strong>
                      <small>Up to 64 GiB</small>
                    </span>
                  </label>
                </>
              )}
            </div>
            {selectedName && (
              <div class="conversion-selected" aria-live="polite">
                <Icon name="file" size={18} />
                <span class="conversion-selected__copy">
                  <strong>{selectedName}</strong>
                  {form.source === "server" && <small>{form.path}</small>}
                  <small>
                    {form.source === "upload"
                      ? "Keep this page open until the upload finishes."
                      : copy.serverNote}
                  </small>
                </span>
              </div>
            )}
            {wrongFile && (
              <div class="conversion-mismatch" role="status">
                <span>
                  {selectedIso
                    ? "This is a DVD image."
                    : "This is not a DVD image (.iso)."}
                </span>
                <button
                  type="button"
                  class="secondary-button"
                  onClick$={() =>
                    props.onTask$(selectedIso ? "dvd" : "transcribe")
                  }
                >
                  {selectedIso ? "Convert this DVD" : "Transcribe it instead"}
                </button>
              </div>
            )}
            {kind === "transcription" && (
              <div class="conversion-field">
                <label for="conversion-engine">Transcription engine</label>
                <select
                  id="conversion-engine"
                  value={form.backend}
                  onChange$={(_, el) => {
                    form.backend = el.value;
                  }}
                >
                  <option value="parakeet">Parakeet</option>
                  <option value="whisper">Whisper</option>
                </select>
              </div>
            )}
            {kind === "transcription" ? (
              <details class="conversion-advanced">
                <summary>Transcript options</summary>
                <div class="conversion-field">
                  <label class="conversion-checkbox">
                    <input
                      type="checkbox"
                      checked={form.diarize}
                      onChange$={(_, el) => {
                        form.diarize = el.checked;
                      }}
                    />
                    Identify speakers
                  </label>
                  {form.backend === "whisper" && (
                    <>
                      <label for="conversion-language">
                        Language (optional)
                      </label>
                      <input
                        id="conversion-language"
                        value={form.language}
                        placeholder="Auto-detect, or enter a code such as en"
                        maxLength={16}
                        onInput$={(_, el) => {
                          form.language = el.value;
                        }}
                      />
                    </>
                  )}
                </div>
              </details>
            ) : (
              <p class="quiet-copy">
                Converted videos appear in the shared video library. The ISO is
                then kept in the shared DVD archive.
              </p>
            )}
            {props.task === "subtitles" && (
              <p class="quiet-copy">
                Timed transcripts are saved beside server videos and library
                copies. Open Transcript in the video player to search and jump
                to dialogue.
              </p>
            )}
            {form.source === "upload" && kind === "transcription" && (
              <div class="conversion-field">
                <label for="conversion-storage">After transcription</label>
                <select
                  id="conversion-storage"
                  value={form.storageRootId}
                  onChange$={(_, el) => {
                    form.storageRootId = el.value;
                  }}
                >
                  <option value="">Keep source in the job inbox</option>
                  {storageRoots.map((root) => (
                    <option key={root.id} value={root.id}>
                      {`Save a copy to ${root.label.toLowerCase()}`}
                    </option>
                  ))}
                </select>
                {form.storageRootId && (
                  <>
                    <label for="conversion-storage-folder">
                      Library subfolder (optional)
                    </label>
                    <input
                      id="conversion-storage-folder"
                      value={form.storageFolder}
                      placeholder="e.g. Interviews/2026"
                      onInput$={(_, el) => {
                        form.storageFolder = el.value;
                      }}
                    />
                    <small>
                      The library copy is saved after success. Existing files
                      are never replaced; the job inbox copy is retained.
                    </small>
                  </>
                )}
              </div>
            )}
            {transcriptionUnavailable && (
              <p class="quiet-copy">Transcription is unavailable right now.</p>
            )}
            <button
              type="submit"
              class="primary-button conversion-submit"
              disabled={transcriptionUnavailable || wrongFile}
            >
              {form.busy
                ? form.source === "upload"
                  ? "Uploading…"
                  : kind === "iso"
                    ? "Queuing…"
                    : "Copying server file…"
                : copy.submit}
            </button>
          </fieldset>
          <div
            class="conversion-input__feedback"
            aria-live="polite"
            aria-atomic="true"
          >
            {form.busy && kind === "transcription" && (
              <p class="quiet-copy">
                {selectedName} —{" "}
                {form.source === "upload"
                  ? "uploading"
                  : "copying to the job inbox"}
                …
              </p>
            )}
            {form.message && submittedJob?.state !== "failed" && (
              <p class="message success" role="status">
                {submittedJob?.state === "completed"
                  ? `${submittedJob.name} finished.${submittedJob.savedPath ? ` Saved: ${submittedJob.savedPath}` : ""}${copy.afterFinish ? ` ${copy.afterFinish}` : ""}`
                  : form.message}
              </p>
            )}
          </div>
          {submittedJob?.error && (
            <p class="message error" role="alert">
              {submittedJob.name}: {submittedJob.error}
            </p>
          )}
          {form.error && (
            <p class="message error" role="alert">
              {form.error}
            </p>
          )}
        </form>
      ) : null}
      {form.browsing && (
        <ServerFileDialog
          task={props.task}
          roots={browseRoots}
          initialRootId={defaultRootId}
          onClose$={closeBrowser}
          onChoose$={async (path) => {
            form.source = "server";
            form.path = path;
            form.storageRootId = "";
            form.storageFolder = "";
            fileName.value = "";
            if (fileInput.value) fileInput.value.value = "";
            await resetFeedback();
            await closeBrowser();
          }}
        />
      )}
    </section>
  );
});

/** Files submitted from this page, newest first. */
export const RecentSubmissions = component$<{ jobs: ConversionInputJob[] }>(
  (props) =>
    props.jobs.length ? (
      <details class="conversion-submissions">
        <summary>Recent submissions</summary>
        <ul>
          {props.jobs.map((job) => (
            <li key={job.id}>
              <div class="conversion-submission-heading">
                <strong>{job.name}</strong>
                <span>{jobStateLabels[job.state]}</span>
              </div>
              {job.error && <p class="message error">{job.error}</p>}
              {job.savedPath && <small>Saved: {job.savedPath}</small>}
            </li>
          ))}
        </ul>
      </details>
    ) : null,
);
