import {
  $,
  component$,
  useStore,
  useSignal,
  useVisibleTask$,
  type QRL,
} from "@builder.io/qwik";
import { api, readableError } from "./api";
import type {
  DecisionRule,
  DecisionRules,
  DecisionAssessment,
  ImmichImage,
} from "./api-contract.generated";

const rulesPath = "/provider-lookups/immich/decision-rules";

export const DecisionQuestions = component$<{
  image?: ImmichImage;
  onAssessed$: QRL<(id: string, tags: string[]) => void>;
}>((props) => {
  const output = useSignal<HTMLElement>();
  const state = useStore({
    open: false,
    loaded: false,
    loading: false,
    saving: false,
    running: false,
    dirty: false,
    adding: [] as string[],
    rules: [] as DecisionRule[],
    error: "",
    notice: "",
    result: undefined as DecisionAssessment | undefined,
    resultName: "",
  });
  useVisibleTask$(({ track }) => {
    const result = track(() => state.result);
    if (result) output.value?.scrollIntoView({ block: "nearest" });
  });
  const toggle = $(async () => {
    state.open = !state.open;
    if (!state.open || state.loaded) return;
    state.loading = true;
    state.error = "";
    try {
      const response = await api<DecisionRules>(rulesPath);
      state.rules = response.rules;
      state.loaded = true;
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.loading = false;
    }
  });
  const save = $(async () => {
    state.error = "";
    state.notice = "";
    state.saving = true;
    try {
      const response = await api<DecisionRules>(rulesPath, {
        method: "PUT",
        body: JSON.stringify({ rules: state.rules }),
      });
      state.rules = response.rules;
      state.dirty = false;
      state.notice =
        "Questions saved. Automatic questions run on the next library sweep (up to 30 minutes).";
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.saving = false;
    }
  });
  const assess = $(async () => {
    const image = props.image;
    if (!image || state.dirty || state.running) return;
    state.running = true;
    state.error = "";
    state.notice = "";
    state.result = undefined;
    state.resultName = image.filename;
    try {
      const response = await api<DecisionAssessment>(
        `/provider-lookups/immich/images/${encodeURIComponent(image.id)}/decisions`,
        { method: "POST" },
        270_000,
      );
      state.result = response;
      await props.onAssessed$(image.id, response.tags);
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.running = false;
    }
  });
  const assessFile = $(async (_event: Event, input: HTMLInputElement) => {
    const file = input.files?.[0];
    if (!file || state.dirty || state.running) return;
    const image = file.type.startsWith("image/");
    const limit = image ? 16 * 1024 * 1024 : 16 * 1024;
    state.error = "";
    state.notice = "";
    state.result = undefined;
    state.resultName = file.name;
    if (file.size > limit) {
      state.error = image
        ? "Images must be at most 16 MiB."
        : "UTF-8 text files must be at most 16 KiB. PDFs and other binary files are unsupported.";
      input.value = "";
      return;
    }
    state.running = true;
    try {
      const content = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(String(reader.result).split(",")[1]);
        reader.onerror = () => reject(new Error("The file could not be read."));
        reader.readAsDataURL(file);
      });
      state.result = await api<DecisionAssessment>(
        "/provider-lookups/immich/decision-files",
        {
          method: "POST",
          body: JSON.stringify({ name: file.name, content, image }),
        },
        270_000,
      );
    } catch (error) {
      state.error = readableError(error);
    } finally {
      state.running = false;
      input.value = "";
    }
  });
  const busy = state.loading || state.saving || state.running;
  const canAssess =
    state.loaded && !busy && !state.dirty && state.rules.length > 0;
  return (
    <div class="decision-questions">
      <button
        type="button"
        class="secondary-button"
        aria-expanded={state.open}
        aria-controls="decision-editor"
        onClick$={toggle}
        disabled={busy}
      >
        {state.open ? "Hide decision questions" : "Decision questions"}
      </button>
      {state.open && (
        <section
          id="decision-editor"
          aria-label="Decision questions"
          aria-busy={busy}
        >
          <h3>Decision questions</h3>
          <p class="muted">
            d1 assesses Yes/No at a 50% cutoff. Tags stay in Media Manager;
            original files and Immich stay unchanged. Every successful
            assessment adds “auto-tagged yyyyMMdd hh:mm” in server local time,
            even when both actions leave tags unchanged.
          </p>
          {state.loading && <p role="status">Loading saved questions…</p>}
          {state.loaded && (
            <form preventdefault:submit onSubmit$={save}>
              <fieldset disabled={busy} class="decision-rules">
                <legend class="sr-only">Saved questions</legend>
                {state.rules.map((rule, i) => (
                  <fieldset key={rule.id} class="decision-rule">
                    <legend>Question {i + 1}</legend>
                    <label>
                      Question
                      <textarea
                        required
                        maxLength={1000}
                        rows={2}
                        value={rule.question}
                        placeholder="Is the photo a computer screen or code?"
                        onInput$={(_, el) => {
                          rule.question = el.value;
                          state.dirty = true;
                          state.notice = "";
                        }}
                      />
                    </label>
                    <div class="decision-actions">
                      {(["yesTag", "noTag"] as const).map((key) => (
                        <div key={key}>
                          <label>
                            If {key === "yesTag" ? "yes" : "no"}
                            <select
                              value={
                                rule[key] ||
                                state.adding.includes(`${rule.id}-${key}`)
                                  ? "tag"
                                  : "unchanged"
                              }
                              onChange$={(_, el) => {
                                rule[key] =
                                  el.value === "tag" ? "to be deleted" : "";
                                state.adding = state.adding.filter(
                                  (id) => id !== `${rule.id}-${key}`,
                                );
                                state.dirty = true;
                                state.notice = "";
                              }}
                            >
                              <option value="unchanged">Leave unchanged</option>
                              <option value="tag">Add tag</option>
                            </select>
                          </label>
                          {(!!rule[key] ||
                            state.adding.includes(`${rule.id}-${key}`)) && (
                            <label>
                              Tag for {key === "yesTag" ? "yes" : "no"}
                              <input
                                required
                                type="text"
                                maxLength={96}
                                value={rule[key]}
                                pattern="[^,]+"
                                onInput$={(_, el) => {
                                  if (
                                    !state.adding.includes(`${rule.id}-${key}`)
                                  )
                                    state.adding.push(`${rule.id}-${key}`);
                                  rule[key] = el.value;
                                  state.dirty = true;
                                  state.notice = "";
                                }}
                              />
                            </label>
                          )}
                        </div>
                      ))}
                    </div>
                    <label class="decision-automatic">
                      <input
                        type="checkbox"
                        checked={rule.automatic}
                        onChange$={(_, el) => {
                          rule.automatic = el.checked;
                          state.dirty = true;
                          state.notice = "";
                        }}
                      />
                      Automatically assess my photo library
                    </label>
                    <button
                      type="button"
                      class="secondary-button"
                      onClick$={() => {
                        state.rules = state.rules.filter(
                          (r) => r.id !== rule.id,
                        );
                        state.dirty = true;
                        state.notice = "";
                      }}
                    >
                      Remove question {i + 1}
                    </button>
                  </fieldset>
                ))}
                {!state.rules.length && <p>No saved questions.</p>}
                <div class="decision-toolbar">
                  <button
                    type="button"
                    class="secondary-button"
                    disabled={state.rules.length >= 16}
                    onClick$={() => {
                      state.rules = [
                        ...state.rules,
                        {
                          id: crypto.randomUUID(),
                          question: "",
                          yesTag: "to be deleted",
                          noTag: "",
                          automatic: false,
                        },
                      ];
                      state.dirty = true;
                      state.notice = "";
                    }}
                  >
                    Add question
                  </button>
                  <button
                    type="submit"
                    class="primary-button"
                    disabled={!state.dirty}
                  >
                    {state.saving ? "Saving…" : "Save questions"}
                  </button>
                </div>
              </fieldset>
            </form>
          )}
          {state.dirty && (
            <p role="status">
              Save changes before assessing. Removing or changing a question
              keeps tags already applied.
            </p>
          )}
          {props.image && (
            <p class="decision-target">
              Selected photo: {props.image.filename}
            </p>
          )}
          <div class="decision-toolbar">
            <button
              type="button"
              class="primary-button"
              disabled={!canAssess || !props.image}
              onClick$={assess}
            >
              Assess selected photo
            </button>
            <label>
              Assess another file
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,text/*,.md,.json,.csv,.log,.rs,.ts"
                disabled={!canAssess}
                onChange$={assessFile}
              />
            </label>
          </div>
          <p class="muted">
            Images up to 16 MiB or UTF-8 text up to 16 KiB. File contents are
            used locally for assessment and are not retained. Upload tags are
            saved by content; upload the same file again to retrieve them.
          </p>
          {state.running && (
            <p role="status">Assessing {state.resultName} locally…</p>
          )}
          {state.error && (
            <p class="message error" role="alert">
              {state.error}
            </p>
          )}
          {state.error && !state.loaded && (
            <button
              type="button"
              class="secondary-button"
              onClick$={() => {
                state.open = false;
                return toggle();
              }}
            >
              Retry loading questions
            </button>
          )}
          {state.notice && <p role="status">{state.notice}</p>}
          {state.result && (
            <section
              ref={output}
              class="decision-result"
              aria-label="Assessment result"
              aria-live="polite"
            >
              <h4>{state.resultName}</h4>
              <ul>
                {state.result.results.map((result) => (
                  <li key={result.id}>
                    <span>{result.question}</span>
                    <strong>
                      {result.answer === "yes" ? "Yes" : "No"} (
                      {Math.round(
                        (result.answer === "yes"
                          ? result.yesProbability
                          : 1 - result.yesProbability) * 100,
                      )}
                      %)
                    </strong>
                    <span>
                      {result.tag
                        ? `Added tag: ${result.tag}`
                        : "Existing tags unchanged"}
                    </span>
                  </li>
                ))}
              </ul>
              <p>Saved tags: {state.result.tags.join(", ")}</p>
            </section>
          )}
        </section>
      )}
    </div>
  );
});
