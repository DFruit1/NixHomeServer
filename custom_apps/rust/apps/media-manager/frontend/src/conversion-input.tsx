import {
  component$,
  useSignal,
  useStore,
  useTask$,
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

export const ConversionInput = component$<{
  inputs?: ConversionInputs;
  transcriptionAvailable?: boolean;
  onQueued$: QRL<(job: ConversionInputJob) => void>;
}>((props) => {
  const form = useStore({
    source: "server",
    path: "",
    kind: "transcription",
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
  const fileName = useSignal("");
  const listing = useSignal<ConversionFiles>();
  useTask$(({ track }) => {
    const available = track(() => props.transcriptionAvailable);
    if (!available) form.kind = "iso";
    else if (!form.path && !fileName.value) form.kind = "transcription";
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
      : (form.path.split("/").at(-1) ?? "");
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
        <h2 id="conversion-input-heading">Start a job</h2>
      </header>
      {!props.inputs ? (
        <p class="conversion-input__notice">Loading available folders…</p>
      ) : !props.inputs.canSubmit ? (
        <p class="conversion-input__notice">
          Adding files requires editor access and enabled changes.
        </p>
      ) : (
        <form
          class="conversion-input__form"
          preventdefault:submit
          onSubmit$={async () => {
            if (form.busy) return;
            form.error = "";
            form.message = "";
            const file = fileInput.value?.files?.[0];
            const name =
              form.source === "upload"
                ? file?.name
                : form.path.split("/").at(-1);
            if (
              !name ||
              (form.source === "server" && !form.path.startsWith("/"))
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
              kind: form.kind as "iso" | "transcription",
              backend: form.backend as "parakeet" | "whisper",
              diarize: form.kind === "transcription" && form.diarize,
              language:
                form.kind === "transcription" &&
                form.backend === "whisper" &&
                form.language.trim()
                  ? form.language.trim()
                  : null,
              storageRootId:
                form.source === "upload" &&
                form.kind === "transcription" &&
                form.storageRootId
                  ? form.storageRootId
                  : null,
              storageFolder:
                form.source === "upload" &&
                form.kind === "transcription" &&
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
                aria-pressed={form.source === "server"}
                onClick$={() => {
                  form.source = "server";
                  form.message = "";
                  form.lastJobId = "";
                  form.error = "";
                }}
              >
                Server file
              </button>
              <button
                type="button"
                aria-pressed={form.source === "upload"}
                onClick$={() => {
                  form.source = "upload";
                  form.message = "";
                  form.lastJobId = "";
                  form.error = "";
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
                    id="conversion-server-path"
                    type="text"
                    required
                    value={form.path}
                    placeholder="Full path to an audio, video or ISO file"
                    onInput$={(_, el) => {
                      form.path = el.value;
                      if (/\.iso$/i.test(el.value)) form.kind = "iso";
                      else if (props.transcriptionAvailable)
                        form.kind = "transcription";
                    }}
                  />
                  <button
                    type="button"
                    aria-expanded={form.browsing}
                    onClick$={() => {
                      form.browsing = !form.browsing;
                      if (!form.rootId)
                        form.rootId = props.inputs?.roots[0]?.id ?? "";
                    }}
                  >
                    Browse
                  </button>
                </div>
                <small>
                  Your own folders and shared media folders. The original stays
                  in place.
                </small>
                {form.browsing && (
                  <div class="conversion-browser">
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
                              onClick$={() => {
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
                                form.kind =
                                  /\.iso$/i.test(entry.name) ||
                                  !props.transcriptionAvailable
                                    ? "iso"
                                    : "transcription";
                                form.browsing = false;
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
                  onChange$={(_, el) => {
                    fileName.value = el.files?.[0]?.name ?? "";
                    form.kind =
                      /\.iso$/i.test(fileName.value) ||
                      !props.transcriptionAvailable
                        ? "iso"
                        : "transcription";
                    form.storageRootId = "";
                    form.storageFolder = "";
                  }}
                />
                <small>
                  Up to 64 GiB. Keep this page open until the upload finishes.
                </small>
              </div>
            )}
            <div class="conversion-options-row">
              <div class="conversion-field">
                <label for="conversion-kind">Action</label>
                <select
                  id="conversion-kind"
                  value={form.kind}
                  onChange$={(_, el) => {
                    form.kind = el.value;
                  }}
                >
                  {props.transcriptionAvailable && (
                    <option value="transcription">Generate transcript</option>
                  )}
                  <option value="iso">Convert DVD ISO to MKV</option>
                </select>
              </div>
              {form.kind === "transcription" && (
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
            </div>
            {form.kind === "transcription" ? (
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
            {form.source === "upload" && form.kind === "transcription" && (
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
            <button type="submit" class="primary-button conversion-submit">
              {form.busy
                ? form.source === "upload"
                  ? "Uploading…"
                  : "Copying server file…"
                : form.kind === "iso"
                  ? "Start conversion"
                  : "Generate transcript"}
            </button>
          </fieldset>
          <div aria-live="polite" aria-atomic="true">
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
              <p class="message success">
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
      )}
      {!!props.inputs?.jobs.length && (
        <details class="conversion-submissions">
          <summary>Submitted files</summary>
          <ul>
            {props.inputs.jobs.map((job) => (
              <li key={job.id}>
                <strong>{job.name}</strong>
                <span>
                  {job.state === "processing" ? "Sent to converter" : job.state}
                </span>
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
