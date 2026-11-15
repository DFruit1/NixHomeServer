import {
  $,
  component$,
  useStore,
  useSignal,
  useId,
  useVisibleTask$,
} from "@builder.io/qwik";
import { api, catalogItems, readableError } from "./api";
import type {
  CatalogItem,
  ItemMetadata,
  MetadataHealthResult,
  MutationPreview,
  PlanStatus,
  TrackOrderFileRow,
} from "./api-contract.generated";
import "./health-track-sequence.css";
import { HealthPlayButton } from "./health-playback";
import { revealWhenMounted } from "./reveal";
import {
  hasCompleteTrackMetadata,
  hasCompletePlaylist,
  recommendedTrackOrder,
  sortTrackSequence,
  type TrackSequenceOrder,
} from "./track-sequence-order";

export const HealthTrackSequence = component$<{
  target: MetadataHealthResult;
  canEdit: boolean;
}>((props) => {
  const state = useStore({
    open: false,
    order: "recommended" as TrackSequenceOrder,
    busy: false,
    files: [] as TrackOrderFileRow[],
    items: [] as CatalogItem[],
    plans: [] as MutationPreview[],
    error: "",
    notice: "",
    submitted: false,
  });
  const orderId = useId();
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
    state.open = true;
    state.busy = true;
    state.error = "";
    try {
      const parent = props.target.relativePath
        .split("/")
        .slice(0, -1)
        .join("/");
      const [metadata, catalog] = await Promise.all([
        api<ItemMetadata>(
          `/folders/metadata?rootId=${encodeURIComponent(props.target.rootId)}&relativePath=${encodeURIComponent(parent)}`,
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
      state.order = "recommended";
      state.files = sortTrackSequence(report.files, "recommended");
      state.items = catalog.items;
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.busy = false;
    }
  });
  const move$ = $((index: number, delta: number) => {
    if (state.busy || state.submitted || !props.canEdit) return;
    if (index + delta < 0 || index + delta >= state.files.length) return;
    state.order = "custom";
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
      const itemIds = state.files.map((file) => {
        const path = parent ? `${parent}/${file.fileName}` : file.fileName;
        const item = state.items.find(
          (candidate) => candidate.relativePath === path,
        );
        if (!item)
          throw new Error(
            `Refresh the library first: ${file.fileName} is not in the catalog.`,
          );
        return item.id;
      });
      const plan = await api<MutationPreview>(
        "/plans",
        {
          method: "POST",
          body: JSON.stringify({
            itemIds,
            operation: { kind: "sequence_tracks" },
          }),
        },
        300_000,
      );
      if (!plan.trackSequence?.length)
        throw new Error(
          "The server did not return a complete track sequence preview. No changes were confirmed.",
        );
      state.plans = [plan];
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.busy = false;
    }
  });
  const confirm$ = $(async () => {
    if (state.busy || state.submitted || !props.canEdit || !state.plans.length)
      return;
    state.busy = true;
    state.error = "";
    let queued = false;
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
        queued = true;
      }
      state.notice = `Track order queued for ${state.files.length} files. Check Activity for completion, then rescan the library and refresh your players.`;
    } catch (error) {
      state.error = `${queued ? "Track order was queued." : "Track order could not be confirmed."} ${readableError(error)} Check Activity before preparing another sequence.`;
    } finally {
      // A partial submission must never be silently resubmitted with stale item IDs.
      state.submitted = true;
      state.busy = false;
    }
  });
  return (
    <section
      class={{ "health-track-sequence": true, "is-open": state.open }}
      aria-label="Choose and write track numbers"
    >
      {!state.open ? (
        <button type="button" onClick$={load$}>
          Choose track order…
        </button>
      ) : (
        <>
          <h4>Choose track order</h4>
          <p>
            Choose where the order comes from, check the new numbers, then
            preview and write the changes to the files.
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
              <fieldset
                class="health-track-sort"
                disabled={state.busy || state.submitted || !props.canEdit}
              >
                <legend>Order to use</legend>
                {(
                  [
                    [
                      "recommended",
                      "Use recommended order",
                      recommendedTrackOrder(state.files).reason,
                      true,
                    ],
                    [
                      "metadata",
                      "Use order in metadata",
                      hasCompleteTrackMetadata(state.files)
                        ? "Sort by embedded disc number, then track number."
                        : "Unavailable: some track tags are missing or duplicated. Choose another source or set a custom order.",
                      hasCompleteTrackMetadata(state.files),
                    ],
                    [
                      "filename",
                      "Use numbering in filenames",
                      "Sort whole filenames naturally (2 before 10), including numbers within names. Names without numbers sort alphabetically.",
                      true,
                    ],
                    [
                      "playlist",
                      "Use playlist order",
                      hasCompletePlaylist(state.files)
                        ? "Follow the folder’s existing playlist."
                        : "Unavailable: no playlist lists every file once.",
                      hasCompletePlaylist(state.files),
                    ],
                    [
                      "custom",
                      "Set a custom order",
                      "Start with the list below. Enter a new position or use the arrows to move a file.",
                      true,
                    ],
                  ] as const
                ).map(([value, label, description, available]) => (
                  <label key={value} class="health-track-choice">
                    <input
                      type="radio"
                      name={orderId}
                      value={value}
                      checked={state.order === value}
                      disabled={!available}
                      onChange$={() => {
                        state.order = value;
                        state.files = sortTrackSequence(state.files, value);
                        state.plans = [];
                        state.error = "";
                        state.notice = "";
                      }}
                    />
                    <span>
                      <strong>{label}</strong>
                      <small>{description}</small>
                    </span>
                  </label>
                ))}
              </fieldset>
              <p class="health-track-write-summary">
                Writing assigns tracks 1–{state.files.length} in this order,
                saves the track total in each audio file, and renames files to
                match. All files become disc 1 of 1; a matching playlist and
                metadata files are also saved. Existing gaps and disc divisions
                are removed.
              </p>
              {!state.submitted && props.canEdit && (
                <div class="health-track-actions">
                  <button
                    type="button"
                    disabled={state.busy}
                    onClick$={preview$}
                  >
                    {state.plans.length
                      ? "Refresh preview"
                      : "Preview file changes"}
                  </button>
                  <span>No files change until you confirm the preview.</span>
                </div>
              )}
              <h4>New track numbers</h4>
              <ol class="health-track-list">
                {state.files.map((file, index) => {
                  const parent = props.target.relativePath
                    .split("/")
                    .slice(0, -1)
                    .join("/");
                  const path = parent
                    ? `${parent}/${file.fileName}`
                    : file.fileName;
                  const item = state.items.find(
                    (candidate) => candidate.relativePath === path,
                  );
                  const playTarget = item
                    ? ({
                        itemId: item.id,
                        rootId: item.rootId,
                        relativePath: item.relativePath,
                        mediaKind: item.mediaKind,
                        title: file.fileName,
                        albumGroup: null,
                        health: [],
                      } as MetadataHealthResult)
                    : undefined;
                  return (
                    <li key={file.fileName}>
                      {playTarget && <HealthPlayButton target={playTarget} />}
                      <span class="health-track-name">
                        <strong>{file.fileName}</strong>
                        <span>
                          Existing:{" "}
                          {file.tagTrack != null
                            ? `disc ${file.tagDisc ?? 1}, track ${file.tagTrack}`
                            : "no track tag"}
                          {file.filenameNumber != null
                            ? ` · filename number ${file.filenameNumber}`
                            : ""}
                          {file.playlistPosition != null
                            ? ` · playlist ${file.playlistPosition}`
                            : ""}
                        </span>
                        <span>
                          Will write: track {index + 1}/{state.files.length} ·
                          disc 1/1
                        </span>
                      </span>
                      <span class="health-track-move">
                        {state.order === "custom" && (
                          <label class="health-track-position">
                            Position
                            <input
                              type="number"
                              min={1}
                              max={state.files.length}
                              value={index + 1}
                              aria-label={`New position for ${file.fileName}`}
                              disabled={
                                state.busy || state.submitted || !props.canEdit
                              }
                              onChange$={(_, input) => {
                                const position = input.valueAsNumber;
                                if (
                                  Number.isInteger(position) &&
                                  position >= 1 &&
                                  position <= state.files.length
                                )
                                  move$(index, position - index - 1);
                                else input.value = String(index + 1);
                              }}
                            />
                          </label>
                        )}
                        <button
                          type="button"
                          aria-label={`Move ${file.fileName} up`}
                          disabled={
                            index === 0 ||
                            state.busy ||
                            state.submitted ||
                            !props.canEdit
                          }
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
                            state.submitted ||
                            !props.canEdit
                          }
                          onClick$={() => move$(index, 1)}
                        >
                          ↓
                        </button>
                      </span>
                    </li>
                  );
                })}
              </ol>
            </>
          )}
          {state.plans.length > 0 && !state.submitted && (
            <div class="health-track-preview" ref={previewElement}>
              <h4>Review changes before writing</h4>
              <ul>
                {state.plans.flatMap((plan) =>
                  (plan.trackSequence ?? []).map((track) => (
                    <li
                      key={track.sourceRelativePath}
                      title={`${track.sourceRelativePath} → ${track.destinationRelativePath}`}
                    >
                      {track.sourceRelativePath.split("/").at(-1)} →{" "}
                      <strong>
                        {track.destinationRelativePath.split("/").at(-1)}
                      </strong>
                      <span class="health-track-tag-summary">
                        Track {track.trackNumber}/{track.trackTotal} · Disc{" "}
                        {track.discNumber}/{track.discTotal}
                      </span>
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
                      ? `Write track numbers to ${state.files.length} files`
                      : "Preview file changes"}
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
