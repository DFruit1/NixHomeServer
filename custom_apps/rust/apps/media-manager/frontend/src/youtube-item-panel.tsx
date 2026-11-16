import {
  $,
  component$,
  type QRL,
  useSignal,
  useStore,
  useTask$,
} from "@builder.io/qwik";
import { ApiError, api, readableError } from "./api";
import type {
  MutationPreview,
  PlanStatus,
  YoutubeItem,
} from "./api-contract.generated";
import { Icon } from "./icon";
import "./youtube-item-panel.css";

const TERMINAL = new Set(["completed", "failed", "rejected", "expired"]);
// Splitting, joining and re-covering copy the item's media once or twice and
// check it; a long video takes minutes.
const PREVIEW_TIMEOUT_MS = 30 * 60 * 1000;

type Change = "split" | "join" | "embed-cover" | "remove-cover" | "move";
type Layout = "channel" | "own-folder" | "collection";

const LAYOUTS: { id: Layout; label: string }[] = [
  { id: "channel", label: "By channel" },
  { id: "own-folder", label: "Own folder" },
  { id: "collection", label: "Collection" },
];

function clock(seconds: number): string {
  const whole = Math.max(0, Math.floor(seconds));
  const h = Math.floor(whole / 3600);
  const m = Math.floor((whole % 3600) / 60);
  const s = String(whole % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

function arrangement(item: YoutubeItem): string {
  switch (item.layout) {
    case "channel":
      return "by channel";
    case "own-folder":
      return "in its own folder";
    case "collection":
      return item.collection
        ? `in the collection “${item.collection}”`
        : "in a collection";
    default:
      return "at the top of the library";
  }
}

function leaf(path: string): string {
  return path.split("/").at(-1) ?? path;
}

/**
 * What the YouTube Downloader recorded beside a download, and the changes it
 * allows: split or join chapters, embed or remove the cover, and move the item
 * between layouts and libraries. Each change is previewed (the server does the
 * copying and checks it), then confirmed. Renders nothing for other items.
 */
export const YoutubeItemPanel = component$<{
  itemId: string;
  /** Run after a change that moved or replaced the selected file. */
  onMoved$?: QRL<(message: string) => void>;
}>((props) => {
  const open = useSignal(false);
  const state = useStore({
    item: undefined as YoutubeItem | undefined,
    loadError: "",
    phase: "idle" as "idle" | "preparing" | "previewed" | "applying",
    pending: "" as Change | "",
    plan: undefined as MutationPreview | undefined,
    error: "",
    notice: "",
    layout: "own-folder" as Layout,
    collection: "",
    rootId: "",
    reload: 0,
  });

  useTask$(async ({ track, cleanup }) => {
    const itemId = track(() => props.itemId);
    track(() => state.reload);
    let current = true;
    cleanup(() => (current = false));
    state.loadError = "";
    if (!itemId) {
      state.item = undefined;
      return;
    }
    try {
      const item = await api<YoutubeItem>(
        `/items/${encodeURIComponent(itemId)}/youtube`,
      );
      if (!current) return;
      state.item = item;
      state.rootId = item.rootId;
      state.layout = item.layout === "own-folder" ? "channel" : "own-folder";
    } catch (error) {
      if (!current) return;
      state.item = undefined;
      // Most items are not YouTube downloads; only report real failures.
      if (!(error instanceof ApiError && error.status === 404))
        state.loadError = readableError(error);
    }
  });

  const preview$ = $(async (change: Change) => {
    const item = state.item;
    if (!item || state.phase === "preparing" || state.phase === "applying")
      return;
    state.phase = "preparing";
    state.pending = change;
    state.error = "";
    state.notice = "";
    state.plan = undefined;
    const operation: Record<string, unknown> = { kind: "youtube_item", change };
    if (change === "move") {
      operation.layout = state.layout;
      if (state.layout === "collection")
        operation.collection = state.collection.trim();
      if (state.rootId && state.rootId !== item.rootId)
        operation.destinationRootId = state.rootId;
    }
    try {
      state.plan = await api<MutationPreview>(
        "/plans",
        {
          method: "POST",
          body: JSON.stringify({ itemIds: [item.itemId], operation }),
        },
        PREVIEW_TIMEOUT_MS,
      );
      state.phase = "previewed";
    } catch (error) {
      state.error = readableError(error);
      state.phase = "idle";
      state.pending = "";
    }
  });

  const cancel$ = $(() => {
    state.phase = "idle";
    state.pending = "";
    state.plan = undefined;
  });

  const confirm$ = $(async () => {
    const plan = state.plan;
    const item = state.item;
    if (!plan || !item || state.phase !== "previewed") return;
    state.phase = "applying";
    state.error = "";
    try {
      let status = await api<PlanStatus>(
        `/plans/${encodeURIComponent(plan.id)}/confirm`,
        { method: "POST", headers: { "if-match": `"${plan.digest}"` } },
      );
      // The broker copies the files into the library in the background.
      for (
        let attempt = 0;
        !TERMINAL.has(status.state) && attempt < 900;
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
      const change = plan.youtubeItem;
      const roots = new Set([item.rootId, change?.rootId ?? item.rootId]);
      for (const rootId of roots)
        await api("/scans", {
          method: "POST",
          body: JSON.stringify({ rootId }),
        }).catch(() => undefined);
      const where = change
        ? `${change.rootLabel} › ${change.folder || "library root"}`
        : "";
      const done: Record<string, string> = {
        split: `Split into chapter files in ${where}.`,
        join: `Joined into one file in ${where}.`,
        "embed-cover": "The cover is embedded.",
        "remove-cover": "The embedded cover was removed.",
        move: `Moved to ${where}.`,
      };
      const message = `${done[change?.change ?? ""] ?? "Done."} Replaced files are in the library's _Tombstone folder.`;
      state.phase = "idle";
      state.pending = "";
      state.plan = undefined;
      if (
        change?.change === "embed-cover" ||
        change?.change === "remove-cover"
      ) {
        state.notice = message;
        state.reload += 1;
      } else {
        // The selected file was replaced or moved; the editor lets it go.
        await props.onMoved$?.(message);
        state.notice = message;
      }
    } catch (error) {
      state.error = readableError(error);
      state.phase = "idle";
      state.pending = "";
      state.plan = undefined;
    }
  });

  const item = state.item;
  if (!item) {
    return state.loadError ? (
      <p class="message error youtube-item__load-error" role="alert">
        {state.loadError}
      </p>
    ) : null;
  }

  const busy = state.phase === "preparing" || state.phase === "applying";
  const canEdit = item.canEdit;
  const media = item.files.filter(
    (file) => file.role === "media" || file.role === "chapter",
  );
  const missing = item.files.filter((file) => !file.present).length;
  const otherLibraries = item.libraries.length > 1;
  const action = (change: Change, label: string, working: string) => (
    <button
      type="button"
      class="secondary-button"
      disabled={busy}
      onClick$={() => preview$(change)}
    >
      {state.phase === "preparing" && state.pending === change
        ? working
        : label}
    </button>
  );
  const plan = state.plan?.youtubeItem;

  return (
    <section class="source-accordion youtube-item">
      <button
        class="source-accordion-summary"
        type="button"
        aria-expanded={open.value}
        aria-controls="youtube-item-body"
        onClick$={() => (open.value = !open.value)}
      >
        <span class="source-accordion-title">YouTube download</span>
        <span class="source-accordion-chevron">
          <Icon name="chevron-down" size={16} />
        </span>
      </button>
      {open.value && (
        <div
          class="source-accordion-body youtube-item__body"
          id="youtube-item-body"
        >
          <dl class="youtube-item__facts">
            <div>
              <dt>Source</dt>
              <dd>
                {item.source.url ? (
                  <a href={item.source.url} target="_blank" rel="noreferrer">
                    {item.source.title}
                  </a>
                ) : (
                  item.source.title
                )}
                {(item.source.channel || item.source.uploadDate) && (
                  <span class="youtube-item__quiet">
                    {[item.source.channel, item.source.uploadDate]
                      .filter(Boolean)
                      .join(" · ")}
                  </span>
                )}
              </dd>
            </div>
            <div>
              <dt>Filed</dt>
              <dd>
                {item.rootLabel} › {item.folder || "library root"}
                <span class="youtube-item__quiet">{arrangement(item)}</span>
              </dd>
            </div>
            <div>
              <dt>Files</dt>
              <dd>
                {item.state.split
                  ? `${media.length} chapter files`
                  : "One file"}
                {item.state.coverEmbedded
                  ? ", cover embedded"
                  : ", no embedded cover"}
                {item.state.split && (
                  <span class="youtube-item__quiet">
                    {item.exactRestore
                      ? "Joins back into the original file, byte for byte."
                      : "Joins back with identical audio and video; the original's tags and exact timing are not on record."}
                  </span>
                )}
                {missing > 0 && (
                  <span class="youtube-item__quiet">
                    {missing === 1
                      ? "1 recorded file is missing."
                      : `${missing} recorded files are missing.`}
                  </span>
                )}
              </dd>
            </div>
          </dl>

          {item.chapters.length > 0 && (
            <details class="youtube-item__chapters">
              <summary>
                {item.chapters.length === 1
                  ? "1 chapter"
                  : `${item.chapters.length} chapters`}
                {!item.state.split && " kept in the file"}
              </summary>
              <ol>
                {item.chapters.map((chapter) => (
                  <li key={chapter.index}>
                    <span class="youtube-item__time">
                      {clock(chapter.startTime)}
                    </span>
                    <span>{chapter.title}</span>
                  </li>
                ))}
              </ol>
            </details>
          )}

          {canEdit &&
            state.phase !== "previewed" &&
            state.phase !== "applying" && (
              <div class="youtube-item__changes">
                {(item.changes.split.available ||
                  item.changes.join.available ||
                  item.changes.embedCover.available ||
                  item.changes.removeCover.available) && (
                  <div class="youtube-item__buttons">
                    {item.changes.split.available &&
                      action(
                        "split",
                        "Split into chapters",
                        "Splitting and checking…",
                      )}
                    {item.changes.join.available &&
                      action(
                        "join",
                        "Join into one file",
                        "Joining and checking…",
                      )}
                    {item.changes.embedCover.available &&
                      action("embed-cover", "Embed cover", "Embedding…")}
                    {item.changes.removeCover.available &&
                      action(
                        "remove-cover",
                        "Remove embedded cover",
                        "Removing…",
                      )}
                  </div>
                )}
                <form
                  class="youtube-item__move"
                  preventdefault:submit
                  onSubmit$={() => preview$("move")}
                >
                  <label>
                    <span>Arrange</span>
                    <select
                      value={state.layout}
                      disabled={busy}
                      onInput$={(_, select) =>
                        (state.layout = select.value as Layout)
                      }
                    >
                      {LAYOUTS.map((layout) => (
                        <option key={layout.id} value={layout.id}>
                          {layout.label}
                        </option>
                      ))}
                    </select>
                  </label>
                  {state.layout === "collection" && (
                    <label>
                      <span>Collection name</span>
                      <input
                        type="text"
                        required
                        maxLength={120}
                        value={state.collection}
                        disabled={busy}
                        onInput$={(_, input) =>
                          (state.collection = input.value)
                        }
                      />
                    </label>
                  )}
                  {otherLibraries && (
                    <label>
                      <span>Library</span>
                      <select
                        value={state.rootId}
                        disabled={busy}
                        onInput$={(_, select) => (state.rootId = select.value)}
                      >
                        {item.libraries.map((library) => (
                          <option key={library.id} value={library.id}>
                            {library.label}
                          </option>
                        ))}
                      </select>
                    </label>
                  )}
                  <button
                    type="submit"
                    class="secondary-button"
                    disabled={busy}
                  >
                    {state.phase === "preparing" && state.pending === "move"
                      ? "Checking…"
                      : "Preview move"}
                  </button>
                </form>
              </div>
            )}

          {plan &&
            (state.phase === "previewed" || state.phase === "applying") && (
              <div
                class="youtube-item__preview"
                role="group"
                aria-label="Preview"
              >
                <p>
                  {plan.change === "move"
                    ? `Move to ${plan.rootLabel} › ${plan.folder || "library root"}?`
                    : plan.change === "split"
                      ? `Split into ${plan.added.length} chapter files in ${plan.folder || "the library root"}?`
                      : plan.change === "join"
                        ? `Join into ${leaf(plan.added[0] ?? "one file")}?`
                        : plan.change === "embed-cover"
                          ? "Embed the original thumbnail as the cover?"
                          : "Remove the embedded cover?"}
                </p>
                {plan.change === "split" && (
                  <ul class="youtube-item__paths">
                    {plan.added.map((path) => (
                      <li key={path}>{leaf(path)}</li>
                    ))}
                  </ul>
                )}
                <ul class="youtube-item__warnings">
                  {(state.plan?.warnings ?? []).map((warning) => (
                    <li key={warning}>{warning}</li>
                  ))}
                </ul>
                <div class="youtube-item__buttons">
                  <button
                    type="button"
                    class="primary-button"
                    disabled={state.phase === "applying"}
                    onClick$={confirm$}
                  >
                    {state.phase === "applying" ? "Applying…" : "Confirm"}
                  </button>
                  <button
                    type="button"
                    class="secondary-button"
                    disabled={state.phase === "applying"}
                    onClick$={cancel$}
                  >
                    Cancel
                  </button>
                </div>
              </div>
            )}

          {state.notice && (
            <p class="message success" role="status">
              {state.notice}
            </p>
          )}
          {state.error && (
            <p class="message error" role="alert">
              {state.error}
            </p>
          )}
        </div>
      )}
    </section>
  );
});
