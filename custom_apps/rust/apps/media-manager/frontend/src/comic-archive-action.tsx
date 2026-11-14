import { $, component$, type QRL, useStore } from "@builder.io/qwik";
import { api, readableError } from "./api";
import type { MutationPreview, PlanStatus } from "./api-contract.generated";
import "./comic-archive-action.css";

const TERMINAL = new Set(["completed", "failed", "rejected", "expired"]);
// Repacking reads every page twice to verify it; large comics take a while.
const PREVIEW_TIMEOUT_MS = 20 * 60 * 1000;

function leaf(path: string): string {
  return path.split("/").at(-1) ?? path;
}

/**
 * Turns one .cbr comic into a .cbz: a rename when the file is already a ZIP,
 * otherwise a verified repack. Shared by Library health and Conversions.
 */
export const ComicArchiveAction = component$<{
  itemId: string;
  rootId: string;
  /** Archive format when already known; "zip" offers a rename. */
  format?: string;
  canEdit: boolean;
  /** Run after the new CBZ is in place so the caller can refresh its list. */
  onConverted$?: QRL<() => void>;
}>((props) => {
  const state = useStore({
    phase: "idle" as "idle" | "preparing" | "previewed" | "applying" | "done",
    plan: undefined as MutationPreview | undefined,
    error: "",
    notice: "",
  });
  const rename = (state.plan?.comicArchive?.format ?? props.format) === "zip";

  const preview$ = $(async () => {
    if (!props.canEdit || state.phase === "preparing") return;
    state.phase = "preparing";
    state.error = "";
    state.plan = undefined;
    try {
      state.plan = await api<MutationPreview>(
        "/plans",
        {
          method: "POST",
          body: JSON.stringify({
            itemIds: [props.itemId],
            operation: { kind: "comic_archive_to_cbz" },
          }),
        },
        PREVIEW_TIMEOUT_MS,
      );
      state.phase = "previewed";
    } catch (error) {
      state.error = readableError(error);
      state.phase = "idle";
    }
  });

  const confirm$ = $(async () => {
    const plan = state.plan;
    if (!plan || state.phase !== "previewed") return;
    state.phase = "applying";
    state.error = "";
    try {
      let status = await api<PlanStatus>(
        `/plans/${encodeURIComponent(plan.id)}/confirm`,
        { method: "POST", headers: { "if-match": `"${plan.digest}"` } },
      );
      // The server copies the new file into the library in the background.
      for (
        let attempt = 0;
        !TERMINAL.has(status.state) && attempt < 600;
        attempt += 1
      ) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
        status = await api<PlanStatus>(`/plans/${encodeURIComponent(plan.id)}`);
      }
      if (status.state !== "completed")
        throw new Error(
          TERMINAL.has(status.state)
            ? status.error || `The change was ${status.state}.`
            : "The change is still running. Check Activity for the result.",
        );
      // Refresh the catalog so the .cbz replaces the .cbr in every view.
      await api("/scans", {
        method: "POST",
        body: JSON.stringify({ rootId: props.rootId }),
      }).catch(() => undefined);
      const destination = leaf(
        plan.comicArchive?.destinationRelativePath ?? "",
      );
      state.notice = rename
        ? `Renamed to ${destination}.`
        : `Converted to ${destination}. The original CBR is in the superseded folder.`;
      state.phase = "done";
      await props.onConverted$?.();
    } catch (error) {
      state.error = readableError(error);
      state.phase = "idle";
      state.plan = undefined;
    }
  });

  if (state.phase === "done")
    return (
      <p class="comic-archive-action message success" role="status">
        {state.notice}
      </p>
    );

  const files = state.plan?.comicArchive?.files;
  const destination = leaf(
    state.plan?.comicArchive?.destinationRelativePath ?? "",
  );
  return (
    <div class="comic-archive-action">
      {state.phase === "previewed" || state.phase === "applying" ? (
        <>
          <p>
            {rename
              ? `Rename to ${destination}?`
              : `Replace with ${destination}${files ? ` (${files} files)` : ""}?`}
          </p>
          <ul>
            {(state.plan?.warnings ?? []).map((warning) => (
              <li key={warning}>{warning}</li>
            ))}
          </ul>
          <div class="comic-archive-action__buttons">
            <button
              type="button"
              class="primary-button"
              disabled={state.phase === "applying"}
              onClick$={confirm$}
            >
              {state.phase === "applying"
                ? rename
                  ? "Renaming…"
                  : "Saving CBZ…"
                : rename
                  ? "Rename"
                  : "Replace with CBZ"}
            </button>
            <button
              type="button"
              class="secondary-button"
              disabled={state.phase === "applying"}
              onClick$={() => {
                state.phase = "idle";
                state.plan = undefined;
              }}
            >
              Cancel
            </button>
          </div>
        </>
      ) : (
        <button
          type="button"
          class="secondary-button"
          disabled={!props.canEdit || state.phase === "preparing"}
          title={
            props.canEdit
              ? undefined
              : "Converting comics requires editor access."
          }
          onClick$={preview$}
        >
          {state.phase === "preparing"
            ? rename
              ? "Checking…"
              : "Converting and checking pages…"
            : rename
              ? "Rename to .cbz"
              : "Convert to CBZ"}
        </button>
      )}
      {state.error && (
        <p class="message error" role="alert">
          {state.error}
        </p>
      )}
    </div>
  );
});
