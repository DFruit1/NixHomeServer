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

const jobStateLabels: Record<ConversionInputJob["state"], string> = {
  queued: "Waiting to start",
  submitting: "Copying file",
  processing: "Processing",
  saving: "Saving library copy",
  completed: "Completed",
  failed: "Needs attention",
};

export const ConversionInput = component$<{
  inputs?: ConversionInputs;
  transcriptionAvailable?: boolean;
  error?: string;
  onQueued$: QRL<(job: ConversionInputJob) => void>;
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
  const kind = /\.iso$/i.test(selectedName) ? "iso" : "transcription";
  const transcriptionUnavailable =
    kind === "transcription" && !props.transcriptionAvailable;
  const video = /\.(mp4|mkv|webm|mov|avi|m4v|mpeg|mpg|ts)$/i.test(selectedName);
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
        <h2 id="conversion-input-heading">Transcribe or convert</h2>
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
              form.error =
                "Transcription is unavailable. Choose a DVD ISO to convert instead.";
              return;
            }
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
              form.message = `${name} is queued. Processing starts automatically after the inbox check.`;
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
                    placeholder="Full path to an audio, video or ISO file"
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
                      if (!form.rootId)
                        form.rootId = props.inputs?.roots[0]?.id ?? "";
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
                      {props.inputs.roots.map((root) => (
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
                        {listing.value?.entries.map((entry) => (
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
                    {listing.value?.entries.length === 0 && (
                      <p>No supported files or subfolders.</p>
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
                  accept="audio/*,video/*,.iso,.mkv,.m4b,.flac,.opus,.wma,.aiff,.ts"
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
                  <small>Results include text, SRT and VTT files.</small>
                </div>
              </details>
            ) : (
              <p class="quiet-copy">
                Converted videos appear in the shared video library. The source
                ISO is retained in the shared DVD archive.
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
              <p class="quiet-copy">
                Transcription is unavailable. You can still convert a DVD ISO.
              </p>
            )}
            <button
              type="submit"
              class="primary-button conversion-submit"
              disabled={transcriptionUnavailable}
            >
              {form.busy
                ? form.source === "upload"
                  ? "Uploading…"
                  : "Copying server file…"
                : kind === "iso"
                  ? "Start conversion"
                  : "Generate transcript"}
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
                  ? `${submittedJob.name} finished.${submittedJob.savedPath ? ` Library copy: ${submittedJob.savedPath}` : ""}`
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
      {!!props.inputs?.jobs.length && (
        <details class="conversion-submissions">
          <summary>Recent submissions</summary>
          <ul>
            {props.inputs.jobs.map((job) => (
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
      )}
    </section>
  );
});
