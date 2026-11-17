import { component$, type QRL, useStore, useTask$ } from "@builder.io/qwik";
import { api, readableError } from "./api";
import type { ComicArchiveList } from "./api-contract.generated";
import { ComicArchiveAction } from "./comic-archive-action";

const FORMAT_NOTES: Record<string, string> = {
  zip: "Already a ZIP archive; only the extension changes",
  rar: "RAR archive",
  "7z": "7z archive",
  unknown: "Not a recognised archive",
  unreadable: "Could not be read",
};

/** CBR comics in the visible book libraries, each with its own CBZ action. */
export const ComicConversions = component$<{
  canEdit: boolean;
  onProcessing$?: QRL<(id: string, name: string, stage: string) => void>;
}>((props) => {
  const state = useStore({
    list: undefined as ComicArchiveList | undefined,
    error: "",
  });
  useTask$(async () => {
    try {
      state.list = await api<ComicArchiveList>("/comic-archives");
    } catch (error) {
      state.error = readableError(error);
    }
  });
  const items = state.list?.items ?? [];
  return (
    <section
      class="panel comic-conversions"
      aria-labelledby="comic-conversions-heading"
    >
      <header class="panel-heading">
        <h2 id="comic-conversions-heading">Comics that can't be edited</h2>
      </header>
      <div class="comic-conversions__body">
        <p>
          These comics are CBR files, a format whose details can be read but not
          changed. Converting makes a CBZ copy with the same pages, which Kavita
          and Media Manager can edit. Every page is checked against the
          original, and the original is kept.
        </p>
        {state.list && !state.list.conversionAvailable && (
          <p class="message error">
            Conversion is unavailable on this server. Comics that are already
            ZIP archives can still be renamed.
          </p>
        )}
        {state.error ? (
          <p class="message error" role="alert">
            {state.error}
          </p>
        ) : !state.list ? (
          <p class="quiet-copy">Looking for comics that can't be edited…</p>
        ) : items.length === 0 ? (
          <p class="quiet-copy">
            Every comic in your book libraries can be edited.
          </p>
        ) : (
          <ul class="comic-conversions__list">
            {items.map((item) => {
              const parts = item.relativePath.split("/");
              const name = parts.pop();
              return (
                <li key={item.itemId}>
                  <div class="comic-conversions__name">
                    <strong>{name}</strong>
                    <small>
                      {[
                        item.rootLabel,
                        parts.join("/"),
                        FORMAT_NOTES[item.format],
                      ]
                        .filter(Boolean)
                        .join(" · ")}
                    </small>
                  </div>
                  {["zip", "rar", "7z"].includes(item.format) && (
                    <ComicArchiveAction
                      itemId={item.itemId}
                      rootId={item.rootId}
                      format={item.format}
                      canEdit={props.canEdit}
                      onProcessing$={(stage) =>
                        props.onProcessing$?.(
                          item.itemId,
                          name ?? item.relativePath,
                          stage,
                        )
                      }
                    />
                  )}
                </li>
              );
            })}
          </ul>
        )}
        {state.list?.truncated && (
          <p class="quiet-copy">
            Only the first 1000 comics in each library are listed.
          </p>
        )}
      </div>
    </section>
  );
});
