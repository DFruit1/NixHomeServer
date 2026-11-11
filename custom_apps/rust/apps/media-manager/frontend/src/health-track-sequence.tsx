import {
  $,
  component$,
  useStore,
  useSignal,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, ApiError, catalogItems, readableError } from "./api";
import type {
  CatalogItem,
  ItemMetadata,
  MetadataHealthResult,
  MutationPreview,
  PlanStatus,
  TrackOrderFileRow,
} from "./api-contract.generated";
import "./health-track-sequence.css";
import { revealWhenMounted } from "./reveal";

function numberedTitle(file: TrackOrderFileRow, index: number, count: number) {
  const stem = file.fileName.replace(/\.[^.]+$/, "");
  const title =
    file.filenameNumber == null
      ? stem
      : stem.replace(
          /^(?:(?:disc|disk|cd|d)[ ._-]*\d+[ ._-]*)?(?:(?:part|track|trk)[ ._#-]*)?\d+[ ._-]*/i,
          "",
        );
  const number = String(index + 1).padStart(
    Math.max(2, String(count).length),
    "0",
  );
  return title ? `${number} - ${title}` : number;
}

export const HealthTrackSequence = component$<{
  target: MetadataHealthResult;
  canEdit: boolean;
}>((props) => {
  const state = useStore({
    open: false,
    busy: false,
    files: [] as TrackOrderFileRow[],
    items: [] as CatalogItem[],
    plans: [] as MutationPreview[],
    warnings: [] as string[],
    error: "",
    notice: "",
    submitted: false,
  });
  const previewElement = useSignal<HTMLElement>();
  const feedbackElement = useSignal<HTMLElement>();
  useVisibleTask$(({ track }) => {
    const plans = track(() => state.plans.length);
    const feedback = track(() => state.error || state.notice);
    const busy = track(() => state.busy);
    if (busy) return;
    if (feedback) revealWhenMounted(() => feedbackElement.value);
    else if (plans) revealWhenMounted(() => previewElement.value);
  });
  const load$ = $(async () => {
    if (state.busy) return;
    state.notice = "";
    state.warnings = [];
    state.open = true;
    state.busy = true;
    state.error = "";
    try {
      const [metadata, catalog] = await Promise.all([
        api<ItemMetadata>(
          `/items/${encodeURIComponent(props.target.itemId)}/metadata`,
        ),
        catalogItems(props.target.rootId, () => true),
      ]);
      const report = metadata.trackOrder;
      if (
        !report ||
        report.files.length !== report.fileCount ||
        !report.fileCount
      )
        throw new Error(
          "A complete folder track list is unavailable. Refresh the library and try again.",
        );
      if (metadata.inspectionWarnings.length)
        throw new Error(
          `Track inspection is incomplete: ${metadata.inspectionWarnings.join(" ")}`,
        );
      state.files = [...report.files].sort(
        (a, b) => a.effectivePosition - b.effectivePosition,
      );
      state.items = catalog.items;
      state.warnings = report.playlistName
        ? [
            `${report.playlistName} is not rewritten. Update its file references after renaming.`,
          ]
        : [];
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.busy = false;
    }
  });
  const move$ = $((index: number, delta: number) => {
    const files = [...state.files];
    const [file] = files.splice(index, 1);
    files.splice(index + delta, 0, file);
    state.files = files;
    state.plans = [];
    state.error = "";
    state.notice = "";
  });
  const preview$ = $(async () => {
    if (state.busy || !props.canEdit || state.submitted) return;
    state.busy = true;
    state.error = "";
    state.notice = "";
    state.plans = [];
    try {
      const parent = props.target.relativePath
        .split("/")
        .slice(0, -1)
        .join("/");
      const plans: MutationPreview[] = [];
      const destinations = new Set<string>();
      for (let index = 0; index < state.files.length; index++) {
        const file = state.files[index];
        const path = parent ? `${parent}/${file.fileName}` : file.fileName;
        const item = state.items.find(
          (candidate) => candidate.relativePath === path,
        );
        if (!item)
          throw new Error(
            `Refresh the library first: ${file.fileName} is not in the catalog.`,
          );
        const plan = await api<MutationPreview>("/plans", {
          method: "POST",
          body: JSON.stringify({
            itemIds: [item.id],
            operation: {
              kind: "canonicalize_names",
              profile: "filename",
              title: numberedTitle(file, index, state.files.length),
              organizeFolders: false,
            },
          }),
        }).catch((error: unknown) => {
          if (error instanceof ApiError && error.code === "no_change")
            return null;
          throw error;
        });
        if (!plan) continue;
        for (const action of plan.actions) {
          const destination = action.destinationRelativePath;
          if (!destination)
            throw new Error("The server did not return a filename preview.");
          if (destinations.has(destination))
            throw new Error(
              "Two tracks would receive the same filename. Adjust the order before retrying.",
            );
          destinations.add(destination);
          if (
            destination !== path &&
            state.items.some(
              (candidate) => candidate.relativePath === destination,
            )
          )
            throw new Error(
              `A file already uses ${destination}. Rename that file in Review metadata first; no files have been changed.`,
            );
        }
        if (
          plan.actions.some(
            (action) =>
              action.destinationRelativePath !== action.sourceRelativePath,
          )
        )
          plans.push(plan);
      }
      state.plans = plans;
      if (!plans.length)
        state.notice = "The filenames already match this sequence.";
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.busy = false;
    }
  });
  const confirm$ = $(async () => {
    if (state.busy || !props.canEdit || !state.plans.length) return;
    state.busy = true;
    state.error = "";
    let queued = 0;
    try {
      for (const plan of state.plans) {
        const result = await api<PlanStatus>(
          `/plans/${encodeURIComponent(plan.id)}/confirm`,
          {
            method: "POST",
            headers: { "if-match": `"${plan.digest}"` },
          },
        );
        if (!["queued", "running", "completed"].includes(result.state))
          throw new Error(result.error || `The plan was ${result.state}.`);
        queued++;
      }
      state.notice = `${queued} filename changes queued. Check Activity for completion, then rescan the library and refresh your player.`;
    } catch (error) {
      state.error = `${queued} changes queued before stopping. ${readableError(error)} Check Activity before preparing another sequence.`;
    } finally {
      // A partial submission must never be silently resubmitted with stale item IDs.
      state.submitted = true;
      state.busy = false;
    }
  });
  return (
    <section
      class="health-track-sequence"
      aria-label="Continuous track numbers"
    >
      {!state.open ? (
        <button type="button" onClick$={load$}>
          Renumber tracks…
        </button>
      ) : (
        <>
          <h4>Renumber tracks from 01</h4>
          <p>
            Choose the file order, then preview continuous filename numbers.
            Embedded tags stay unchanged; players that prefer tags may still use
            their order.
          </p>
          {state.busy && (
            <p role="status">
              {state.plans.length
                ? "Queuing changes…"
                : "Preparing track sequence…"}
            </p>
          )}
          {!!state.files.length && (
            <>
              <label class="health-track-sort">
                Starting order
                <select
                  disabled={state.busy || state.submitted}
                  onChange$={(_, select) => {
                    const field = select.value;
                    state.files = [...state.files].sort((a, b) => {
                      if (field === "filename")
                        return a.fileName.localeCompare(b.fileName, undefined, {
                          numeric: true,
                        });
                      if (field === "playlist")
                        return (
                          (a.playlistPosition ?? Infinity) -
                            (b.playlistPosition ?? Infinity) ||
                          a.effectivePosition - b.effectivePosition
                        );
                      return a.effectivePosition - b.effectivePosition;
                    });
                    state.plans = [];
                    state.error = "";
                    state.notice = "";
                  }}
                >
                  <option value="effective">
                    Current playback order (disc, then track)
                  </option>
                  <option value="filename">Filename order</option>
                  {state.files.some(
                    (file) => file.playlistPosition != null,
                  ) && <option value="playlist">Playlist order</option>}
                </select>
              </label>
              <ol class="health-track-list">
                {state.files.map((file, index) => (
                  <li key={file.fileName}>
                    <span class="health-track-name">
                      <span>{file.fileName}</span>
                      <strong>
                        {numberedTitle(file, index, state.files.length)}
                        {file.fileName.match(/\.[^.]+$/)?.[0]}
                      </strong>
                    </span>
                    <span class="health-track-move">
                      <button
                        type="button"
                        aria-label={`Move ${file.fileName} up`}
                        disabled={index === 0 || state.busy || state.submitted}
                        onClick$={() => move$(index, -1)}
                      >
                        ↑
                      </button>
                      <button
                        type="button"
                        aria-label={`Move ${file.fileName} down`}
                        disabled={
                          index === state.files.length - 1 ||
                          state.busy ||
                          state.submitted
                        }
                        onClick$={() => move$(index, 1)}
                      >
                        ↓
                      </button>
                    </span>
                  </li>
                ))}
              </ol>
            </>
          )}
          {state.warnings.map((warning) => (
            <p key={warning}>{warning}</p>
          ))}
          {state.plans.length > 0 && !state.submitted && (
            <div class="health-track-preview" ref={previewElement}>
              <h4>Filename changes to confirm</h4>
              <ul>
                {state.plans.flatMap((plan) =>
                  plan.actions.map((action, index) => (
                    <li key={`${plan.id}-${index}`}>
                      {action.sourceRelativePath} →{" "}
                      <strong>{action.destinationRelativePath}</strong>
                    </li>
                  )),
                )}
              </ul>
              {[...new Set(state.plans.flatMap((plan) => plan.warnings))].map(
                (warning) => (
                  <p key={warning}>{warning}</p>
                ),
              )}
            </div>
          )}
          <div class="health-track-feedback" ref={feedbackElement}>
            {state.error && <p role="alert">{state.error}</p>}
            {state.notice && <p role="status">{state.notice}</p>}
          </div>
          <div class="health-track-actions">
            {state.submitted ? (
              <a href="?view=activity">View Activity</a>
            ) : (
              <>
                {props.canEdit ? (
                  <button
                    type="button"
                    disabled={state.busy || !state.files.length}
                    onClick$={state.plans.length ? confirm$ : preview$}
                  >
                    {state.plans.length
                      ? `Confirm ${state.plans.length} filename changes`
                      : "Preview filename changes"}
                  </button>
                ) : (
                  <p>Editing is unavailable for this account or server.</p>
                )}
                <button
                  type="button"
                  disabled={state.busy}
                  onClick$={() => {
                    state.open = false;
                    state.files = [];
                    state.plans = [];
                  }}
                >
                  Cancel
                </button>
              </>
            )}
          </div>
        </>
      )}
    </section>
  );
});
