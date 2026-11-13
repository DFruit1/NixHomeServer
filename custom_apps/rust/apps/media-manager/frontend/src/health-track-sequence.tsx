import {
  $,
  component$,
  useStore,
  useSignal,
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
      state.files = [...report.files].sort(
        (a, b) => a.effectivePosition - b.effectivePosition,
      );
      state.items = catalog.items;
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
            Choose the play order. Confirmation writes track numbers 1–N and the
            total into the audio files, aligns filenames, and creates matching
            playlist and metadata sidecars. Disc number and disc total become 1
            so this sequence stays continuous across the folder.
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
                          Track {index + 1}/{state.files.length} · Disc 1/1
                        </span>
                      </span>
                      <span class="health-track-move">
                        <button
                          type="button"
                          aria-label={`Move ${file.fileName} up`}
                          disabled={
                            index === 0 || state.busy || state.submitted
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
                            state.submitted
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
              <h4>Track order to confirm</h4>
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
                      ? `Confirm track order for ${state.files.length} files`
                      : "Preview track order"}
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
