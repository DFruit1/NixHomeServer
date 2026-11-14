import {
  component$,
  useSignal,
  useStore,
  useTask$,
  $,
  type QRL,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import type {
  ConversionInputs,
  ConversionInputAccepted,
  ConversionInputJob,
  ConversionFiles,
  ConversionInputOptions,
} from "./api-contract.generated";

export type ConversionTask = "dvd" | "transcribe" | "subtitles";

const ISO_FILE = /\.iso$/i;
const VIDEO_FILE = /\.(mp4|mkv|webm|mov|avi|m4v|mpeg|mpg|ts)$/i;

const taskCopy: Record<
  ConversionTask,
  {
    heading: string;
    placeholder: string;
    submit: string;
    accept: string;
    nextStep: string;
    afterFinish: string;
  }
> = {
  dvd: {
    heading: "Choose a DVD image",
    placeholder: "Full path to a .iso file",
    submit: "Start conversion",
    accept: ".iso",
    nextStep: "The converted video will appear in the shared video library.",
    afterFinish: "",
  },
  transcribe: {
    heading: "Choose audio or video",
    placeholder: "Full path to an audio or video file",
    submit: "Generate transcript",
    accept: "audio/*,video/*,.mkv,.m4b,.flac,.opus,.wma,.aiff,.ts",
    nextStep: "Text, SRT and VTT files will appear under Completed.",
    afterFinish: "",
  },
  subtitles: {
    heading: "Choose a video",
    placeholder: "Full path to a video in your library",
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

export const ConversionInput = component$<{
  task: ConversionTask;
  inputs?: ConversionInputs;
  transcriptionAvailable?: boolean;
  error?: string;
  onQueued$: QRL<(job: ConversionInputJob) => void>;
  onTask$: QRL<(task: ConversionTask) => void>;
}>((props) => {
  const form = useStore({
    source: "server",
    path: "",
    backend: "parakeet",
    diarize: false,
    language: "",
    storageRootId: "",
    storageFolder: "",
    rootId: "",
    folder: "",
    browsing: false,
    browseLoading: false,
    browseError: "",
    busy: false,
    message: "",
    lastJobId: "",
    error: "",
  });
  const fileInput = useSignal<HTMLInputElement>();
  const serverPathInput = useSignal<HTMLInputElement>();
  const fileName = useSignal("");
  const listing = useSignal<ConversionFiles>();
  const resetFeedback = $(() => {
    form.message = "";
    form.lastJobId = "";
    form.error = "";
  });
  // A new task starts its browser at that task's folder; the chosen path is
  // kept so a misplaced file can move to the matching task.
  useTask$(({ track }) => {
    const task = track(() => props.task);
    form.browsing = false;
    form.rootId = "";
    form.folder = "";
    form.error = "";
    if (task === "subtitles" && form.source === "upload") {
      form.source = "server";
      fileName.value = "";
    }
  });
  useTask$(({ track, cleanup }) => {
    const browsing = track(() => form.browsing);
    const rootId = track(() => form.rootId);
    const path = track(() => form.folder);
    let stopped = false;
    cleanup(() => {
      stopped = true;
    });
    if (!browsing || !rootId) return;
    form.browseLoading = true;
    form.browseError = "";
    listing.value = undefined;
    void api<ConversionFiles>(
      `/conversions/files?${new URLSearchParams({ rootId, path })}`,
    )
      .then((result) => {
        if (!stopped) listing.value = result;
      })
      .catch((error) => {
        if (!stopped) form.browseError = readableError(error);
      })
      .finally(() => {
        if (!stopped) form.browseLoading = false;
      });
  });
  const submittedJob = props.inputs?.jobs.find(
    (job) => job.id === form.lastJobId,
  );
  const selectedName =
    form.source === "upload"
      ? fileName.value
      : (form.path.trim().split("/").at(-1) ?? "");
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
  const entries = (listing.value?.entries ?? []).filter((entry) =>
    entryFits(props.task, entry.name, entry.directory),
  );
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
              form.error = "Select a file or enter its full server path.";
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
            {props.task === "subtitles" ? null : (
              <div
                class="conversion-source"
                role="group"
                aria-label="File location"
              >
                <button
                  type="button"
                  class="secondary-button"
                  aria-pressed={form.source === "server"}
                  onClick$={async () => {
                    form.source = "server";
                    form.storageRootId = "";
                    form.storageFolder = "";
                    fileName.value = "";
                    await resetFeedback();
                  }}
                >
                  Server file
                </button>
                <button
                  type="button"
                  class="secondary-button"
                  aria-pressed={form.source === "upload"}
                  onClick$={async () => {
                    form.source = "upload";
                    form.storageRootId = "";
                    form.storageFolder = "";
                    await resetFeedback();
                  }}
                >
                  Upload file
                </button>
              </div>
            )}
            {form.source === "server" ? (
              <div class="conversion-field">
                <label for="conversion-server-path">Server file path</label>
                <div class="conversion-path-control">
                  <input
                    ref={serverPathInput}
                    id="conversion-server-path"
                    aria-describedby="conversion-server-note"
                    type="text"
                    required
                    value={form.path}
                    placeholder={copy.placeholder}
                    onInput$={async (_, el) => {
                      form.path = el.value;
                      await resetFeedback();
                    }}
                  />
                  <button
                    type="button"
                    class="secondary-button"
                    aria-expanded={form.browsing}
                    aria-controls="conversion-browser"
                    onClick$={() => {
                      form.browsing = !form.browsing;
                      if (!form.rootId) form.rootId = defaultRootId;
                    }}
                  >
                    Browse
                  </button>
                </div>
                <small id="conversion-server-note">
                  Your original stays in place.
                </small>
                {form.browsing && (
                  <div id="conversion-browser" class="conversion-browser">
                    <label for="conversion-source-root">Folder</label>
                    <select
                      id="conversion-source-root"
                      value={form.rootId}
                      onChange$={(_, el) => {
                        form.rootId = el.value;
                        form.folder = "";
                      }}
                    >
                      {browseRoots.map((root) => (
                        <option value={root.id} key={root.id}>
                          {root.label}
                        </option>
                      ))}
                    </select>
                    <div class="conversion-browser__location">
                      <span>{form.folder || "/"}</span>
                      <button
                        type="button"
                        class="secondary-button"
                        disabled={!form.folder}
                        onClick$={() => {
                          form.folder = form.folder
                            .split("/")
                            .slice(0, -1)
                            .join("/");
                        }}
                      >
                        Up one folder
                      </button>
                    </div>
                    {form.browseError && (
                      <p class="message error" role="alert">
                        {form.browseError}
                      </p>
                    )}
                    {form.browseLoading ? (
                      <p role="status">Loading files…</p>
                    ) : (
                      <ul aria-label="Server files">
                        {entries.map((entry) => (
                          <li key={entry.name}>
                            <button
                              type="button"
                              class="conversion-browser__entry"
                              onClick$={async () => {
                                if (entry.directory) {
                                  form.folder = [form.folder, entry.name]
                                    .filter(Boolean)
                                    .join("/");
                                  return;
                                }
                                const root = props.inputs?.roots.find(
                                  (r) => r.id === form.rootId,
                                );
                                form.path = [
                                  root?.path,
                                  form.folder,
                                  entry.name,
                                ]
                                  .filter(Boolean)
                                  .join("/");
                                await resetFeedback();
                                form.browsing = false;
                                serverPathInput.value?.focus();
                              }}
                            >
                              <span aria-hidden="true">
                                {entry.directory ? "▸" : "·"}
                              </span>
                              {entry.name}
                              {entry.directory && (
                                <span class="sr-only"> (folder)</span>
                              )}
                            </button>
                          </li>
                        ))}
                      </ul>
                    )}
                    {listing.value && entries.length === 0 && (
                      <p>No matching files or subfolders.</p>
                    )}
                    {listing.value?.truncated && (
                      <p>
                        Showing the first 200 entries. Enter a full file path to
                        select another file.
                      </p>
                    )}
                  </div>
                )}
              </div>
            ) : (
              <div class="conversion-field">
                <label for="conversion-upload">File to upload</label>
                <input
                  ref={fileInput}
                  id="conversion-upload"
                  type="file"
                  required
                  accept={copy.accept}
                  onChange$={async (_, el) => {
                    fileName.value = el.files?.[0]?.name ?? "";
                    form.storageRootId = "";
                    form.storageFolder = "";
                    await resetFeedback();
                  }}
                />
                <small>
                  Up to 64 GiB. Keep this page open until the upload finishes.
                </small>
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
                Converted videos appear in the shared video library. The source
                ISO is retained in the shared DVD archive.
              </p>
            )}
            {props.task === "subtitles" && (
              <p class="quiet-copy">
                When the transcript is ready, open the video in Library, expand
                Subtitles and pick it under Use a transcript.
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
                  : "Copying server file…"
                : copy.submit}
            </button>
          </fieldset>
          <div
            class="conversion-input__feedback"
            aria-live="polite"
            aria-atomic="true"
          >
            {form.busy && (
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
                  ? `${submittedJob.name} finished.${submittedJob.savedPath ? ` Library copy: ${submittedJob.savedPath}` : ""}${copy.afterFinish ? ` ${copy.afterFinish}` : ""}`
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
              {job.savedPath && <small>Library copy: {job.savedPath}</small>}
            </li>
          ))}
        </ul>
      </details>
    ) : null,
);
