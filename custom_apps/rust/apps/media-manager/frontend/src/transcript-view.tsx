import { component$, useSignal, useStore, useTask$ } from "@builder.io/qwik";
import { api, catalogItems, readableError } from "./api";
import type { VideoTranscript } from "./api-contract.generated";

export const TranscriptView = component$<{ rootId?: string; path?: string }>(
  (props) => {
    const query = useSignal("");
    const state = useStore({
      loading: true,
      error: "",
      text: "",
      recordings: [] as string[],
      cues: [] as VideoTranscript["cues"],
    });
    useTask$(({ track, cleanup }) => {
      const root = track(() => props.rootId);
      const path = track(() => props.path) ?? "";
      let stopped = false;
      cleanup(() => {
        stopped = true;
      });
      state.loading = true;
      state.error = "";
      state.text = "";
      state.recordings = [];
      state.cues = [];
      query.value = "";
      void (async () => {
        try {
          let result: VideoTranscript & { text?: string };
          if (!root && path.startsWith("_Transcripts/")) {
            result = await api(
              `/transcript-file?${new URLSearchParams({ path })}`,
            );
          } else if (root && path) {
            const page = await catalogItems(root, () => !stopped);
            const exact = page.items.find((item) => item.relativePath === path);
            const tracks = page.items.filter((item) =>
              item.relativePath.startsWith(path.replace(/\/$/, "") + "/"),
            );
            if (!exact && tracks.length > 1) {
              if (!stopped)
                state.recordings = tracks.map((item) => item.relativePath);
              return;
            }
            const item = exact ?? (tracks.length === 1 ? tracks[0] : undefined);
            if (!item)
              throw new Error(
                "This file is unavailable, or the result names a folder with multiple recordings. Open the individual recording from the library.",
              );
            result = await api(
              `/items/${encodeURIComponent(item.id)}/transcript`,
            );
          } else {
            throw new Error("Select a transcript from Search.");
          }
          if (!stopped) {
            state.cues = result.cues;
            state.text = result.text ?? "";
          }
        } catch (error) {
          if (!stopped) state.error = readableError(error);
        } finally {
          if (!stopped) state.loading = false;
        }
      })();
    });
    const cues = state.cues.filter((cue) =>
      cue.text
        .toLocaleLowerCase()
        .includes(query.value.trim().toLocaleLowerCase()),
    );
    return (
      <section class="transcript-page" aria-label="Transcript">
        <h2>{props.path?.split("/").at(-1) || "Transcript"}</h2>
        {state.loading ? (
          <p role="status">Loading transcript…</p>
        ) : state.error ? (
          <p role="alert">{state.error}</p>
        ) : state.recordings.length ? (
          <ul aria-label="Recordings">
            {state.recordings.map((path) => (
              <li key={path}>
                <a
                  href={`?${new URLSearchParams({ view: "transcript", root: props.rootId ?? "", path })}`}
                >
                  {path.split("/").at(-1)}
                </a>
              </li>
            ))}
          </ul>
        ) : state.cues.length ? (
          <>
            <label>
              Search transcript
              <input
                type="search"
                value={query.value}
                onInput$={(_, input) => {
                  query.value = input.value;
                }}
              />
            </label>
            <ol class="transcript-page-lines" aria-label="Timestamped dialogue">
              {cues.map((cue) => (
                <li key={cue.index}>
                  <time>
                    {new Date(cue.startMs).toISOString().slice(11, 19)}
                  </time>
                  <span>{cue.text}</span>
                </li>
              ))}
            </ol>
            {!cues.length && <p role="status">No matching dialogue.</p>}
          </>
        ) : state.text ? (
          <>
            <p>Timestamps are unavailable for this transcript.</p>
            <pre>{state.text}</pre>
          </>
        ) : (
          <p>No transcript is available for this file.</p>
        )}
      </section>
    );
  },
);
