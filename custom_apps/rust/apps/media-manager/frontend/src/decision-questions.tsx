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
  DecisionScoreBounds,
  ImmichImage,
} from "./api-contract.generated";

const rulesPath = "/provider-lookups/immich/decision-rules";
const defaultCategoryQuestion =
  "Based on the photo's contents and tags, which category does it belong to?";
type BoundKey = keyof DecisionScoreBounds;
type ErrorPlace = "load" | "save" | "photo" | "file";
const scoreNames = ["aesthetic", "keeper", "cover"] as const;
const boundKeys = (score: (typeof scoreNames)[number]) =>
  [`${score}Min`, `${score}Max`] as const;
const percentValue = (value?: number) =>
  value === undefined ? "" : String(Math.round(value * 100));

const newRule = (kind: "yesNo" | "category"): DecisionRule => ({
  id: crypto.randomUUID(),
  kind,
  question: kind === "category" ? defaultCategoryQuestion : "",
  yesTag: "",
  yesArchive: kind === "yesNo",
  noArchive: false,
  noTag: "",
  categories: kind === "category" ? ["", ""] : [],
  automatic: false,
});

export const DecisionQuestions = component$<{
  open: boolean;
  image?: ImmichImage;
  onClose$: QRL<() => void>;
  onAssessed$: QRL<(id: string, tags: string[]) => void>;
}>((props) => {
  const output = useSignal<HTMLElement>();
  const heading = useSignal<HTMLElement>();
  const state = useStore({
    loaded: false,
    loading: false,
    saving: false,
    running: false,
    dirty: false,
    adding: [] as string[],
    rules: [] as DecisionRule[],
    error: "",
    errorAt: "load" as ErrorPlace,
    notice: "",
    result: undefined as DecisionAssessment | undefined,
    resultName: "",
    resultFrom: "photo" as "photo" | "file",
  });
  useVisibleTask$(({ track }) => {
    const result = track(() => state.result);
    if (result) output.value?.scrollIntoView({ block: "nearest" });
  });
  const changed = () => {
    state.dirty = true;
    state.notice = "";
  };
  const updateBound = (rule: DecisionRule, key: BoundKey, raw: string) => {
    const bounds: DecisionScoreBounds = { ...(rule.bounds ?? {}) };
    if (raw.trim() === "") delete bounds[key];
    else {
      const percent = Number(raw);
      if (!Number.isFinite(percent) || percent < 0 || percent > 100) return;
      bounds[key] = percent / 100;
    }
    rule.bounds = Object.keys(bounds).length > 0 ? bounds : undefined;
    changed();
  };
  const loadRules = $(async () => {
    if (state.loaded || state.loading) return;
    state.loading = true;
    state.error = "";
    state.errorAt = "load";
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
  useVisibleTask$(({ track }) => {
    if (!track(() => props.open)) return;
    heading.value?.focus();
    void loadRules();
  });
  const save = $(async () => {
    state.error = "";
    state.errorAt = "save";
    state.notice = "";
    state.saving = true;
    try {
      const response = await api<DecisionRules>(rulesPath, {
        method: "PUT",
        body: JSON.stringify({ rules: state.rules }),
      });
      state.rules = response.rules;
      state.dirty = false;
      state.notice = "Questions saved.";
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
    state.errorAt = "photo";
    state.notice = "";
    state.result = undefined;
    state.resultName = image.filename;
    state.resultFrom = "photo";
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
    state.errorAt = "file";
    state.notice = "";
    state.result = undefined;
    state.resultName = file.name;
    state.resultFrom = "file";
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
  if (!props.open) return null;
  const errorAt = (place: ErrorPlace) =>
    state.error && state.errorAt === place ? (
      <p class="message error" role="alert">
        {state.error}
      </p>
    ) : null;
  const resultAt = (from: "photo" | "file") => (
    <>
      {state.running && state.resultFrom === from && (
        <p class="decision-note" role="status">
          Assessing {state.resultName} locally…
        </p>
      )}
      {state.result && state.resultFrom === from && (
        <section
          ref={output}
          class="decision-result"
          aria-label="Assessment result"
          aria-live="polite"
        >
          <h4>{state.resultName}</h4>
          <ul>
            {state.result.results.map((result) => {
              const confidence =
                result.answer === "no"
                  ? 1 - result.yesProbability
                  : result.yesProbability;
              const summary =
                result.answer === "skipped"
                  ? "Skipped"
                  : result.kind === "category"
                    ? result.category
                      ? `Category: ${result.category} (${Math.round(result.yesProbability * 100)}%)`
                      : `No category (best ${Math.round(result.yesProbability * 100)}%)`
                    : `${result.answer === "yes" ? "Yes" : "No"} (${Math.round(confidence * 100)}%)`;
              return (
                <li key={result.id}>
                  <span>{result.question}</span>
                  <strong>{summary}</strong>
                  {result.album && <span>Added to album: {result.album}</span>}
                  {result.category && !result.album && !result.albumError && (
                    <span>Album not changed for uploaded files.</span>
                  )}
                  {result.skipReason && <span>{result.skipReason}</span>}
                  {result.albumError && (
                    <span class="message error">{result.albumError}</span>
                  )}
                  {result.archived && <span>Archived in Immich</span>}
                  {result.archiveRequested &&
                    !result.archived &&
                    !result.archiveError && (
                      <span>
                        {state.result!.target.startsWith("file:")
                          ? "Archive actions apply only to Immich photos."
                          : "Archive action was not applied. Review the saved question before retrying."}
                      </span>
                    )}
                  {result.archiveError && (
                    <span class="message error">{result.archiveError}</span>
                  )}
                  {result.tag ? (
                    <span>Added tag: {result.tag}</span>
                  ) : (
                    result.kind === "yesNo" &&
                    !result.archiveRequested &&
                    result.answer !== "skipped" && (
                      <span>Existing tags unchanged</span>
                    )
                  )}
                </li>
              );
            })}
          </ul>
          {!!state.result.tags.length && (
            <p>Saved tags: {state.result.tags.join(", ")}</p>
          )}
        </section>
      )}
    </>
  );
  return (
    <section
      id="decision-editor"
      class="decision-questions panel"
      aria-labelledby="decision-editor-title"
      aria-busy={busy}
    >
      <header class="decision-header">
        <button type="button" class="text-button" onClick$={props.onClose$}>
          <span aria-hidden="true">←</span> Back to photos
        </button>
        <h2 id="decision-editor-title" ref={heading} tabIndex={-1}>
          Decision questions
        </h2>
      </header>
      <details class="decision-help">
        <summary>How decisions work</summary>
        <p>
          Yes/No answers can add a tag, archive the photo in Immich (restorable
          from Archive), or leave it unchanged. Category questions add the photo
          to the best-matching album at 50% or higher. Score bounds are optional
          per question; automatic questions run on the next library sweep within
          30 minutes. Removing a question keeps tags and albums already applied.
          Saved tags stay private to Media Manager.
        </p>
      </details>
      {state.loading && (
        <p class="decision-note" role="status">
          Loading saved questions…
        </p>
      )}
      {errorAt("load")}
      {state.error && state.errorAt === "load" && !state.loaded && (
        <button type="button" class="secondary-button" onClick$={loadRules}>
          Retry loading questions
        </button>
      )}
      {state.loaded && (
        <form preventdefault:submit onSubmit$={save}>
          <fieldset disabled={busy} class="decision-rules">
            <legend class="sr-only">Saved questions</legend>
            {state.rules.map((rule, i) => {
              const kind = rule.kind === "category" ? "category" : "yesNo";
              const headingId = `decision-rule-${rule.id}`;
              return (
                <fieldset
                  key={rule.id}
                  class="decision-rule"
                  aria-labelledby={headingId}
                >
                  <div class="decision-rule-head">
                    <h3 id={headingId}>Question {i + 1}</h3>
                    <button
                      type="button"
                      class="text-button"
                      aria-label={`Remove question ${i + 1}`}
                      onClick$={() => {
                        state.rules = state.rules.filter(
                          (r) => r.id !== rule.id,
                        );
                        changed();
                      }}
                    >
                      Remove
                    </button>
                  </div>
                  <textarea
                    required
                    aria-label="Question"
                    maxLength={1000}
                    rows={2}
                    value={rule.question}
                    placeholder="Is the photo a computer screen or code?"
                    onInput$={(_, el) => {
                      rule.question = el.value;
                      changed();
                    }}
                  />
                  <div class="decision-row">
                    <label>
                      Type
                      <select
                        value={kind}
                        onChange$={(_, el) => {
                          const next =
                            el.value === "category" ? "category" : "yesNo";
                          rule.kind = next;
                          if (next === "category") {
                            if (!rule.question.trim())
                              rule.question = defaultCategoryQuestion;
                            rule.categories = ["", ""];
                            rule.yesTag = "";
                            rule.noTag = "";
                            rule.yesArchive = false;
                            rule.noArchive = false;
                          } else {
                            rule.categories = [];
                          }
                          changed();
                        }}
                      >
                        <option value="yesNo">Yes or no</option>
                        <option value="category">Categorise into albums</option>
                      </select>
                    </label>
                    {kind === "yesNo" &&
                      (["yesTag", "noTag"] as const).map((key) => {
                        const answer = key === "yesTag" ? "yes" : "no";
                        const archiveKey =
                          key === "yesTag" ? "yesArchive" : "noArchive";
                        const adding = `${rule.id}-${key}`;
                        return (
                          <div key={key} class="decision-answer">
                            <label>
                              If {answer}
                              <select
                                value={
                                  rule[archiveKey]
                                    ? "archive"
                                    : rule[key] || state.adding.includes(adding)
                                      ? "tag"
                                      : "unchanged"
                                }
                                onChange$={(_, el) => {
                                  rule[key] = "";
                                  rule[archiveKey] = el.value === "archive";
                                  state.adding = state.adding.filter(
                                    (id) => id !== adding,
                                  );
                                  if (el.value === "tag")
                                    state.adding.push(adding);
                                  changed();
                                }}
                              >
                                <option value="unchanged">
                                  Leave unchanged
                                </option>
                                <option value="archive">
                                  Archive in Immich
                                </option>
                                <option value="tag">Add tag</option>
                              </select>
                            </label>
                            {(!!rule[key] || state.adding.includes(adding)) && (
                              <label>
                                Tag for {answer}
                                <input
                                  required
                                  type="text"
                                  maxLength={96}
                                  value={rule[key]}
                                  pattern="[^,]+"
                                  onInput$={(_, el) => {
                                    if (!state.adding.includes(adding))
                                      state.adding.push(adding);
                                    rule[key] = el.value;
                                    changed();
                                  }}
                                />
                              </label>
                            )}
                          </div>
                        );
                      })}
                  </div>
                  {kind === "category" && (
                    <div
                      class="decision-categories"
                      role="group"
                      aria-labelledby={`${headingId}-albums`}
                    >
                      <span id={`${headingId}-albums`}>Albums</span>
                      {rule.categories.map((category, position) => (
                        <div key={position} class="decision-category">
                          <input
                            required
                            type="text"
                            maxLength={96}
                            aria-label={`Album ${position + 1}`}
                            value={category}
                            onInput$={(_, el) => {
                              rule.categories[position] = el.value;
                              changed();
                            }}
                          />
                          <button
                            type="button"
                            class="decision-icon-button"
                            aria-label={`Remove album ${position + 1}`}
                            title={`Remove album ${position + 1}`}
                            disabled={rule.categories.length <= 2}
                            onClick$={() => {
                              rule.categories = rule.categories.filter(
                                (_name, index) => index !== position,
                              );
                              changed();
                            }}
                          >
                            <svg
                              aria-hidden="true"
                              width="16"
                              height="16"
                              viewBox="0 0 24 24"
                              fill="none"
                              stroke="currentColor"
                              stroke-width="2"
                              stroke-linecap="round"
                            >
                              <path d="M6 6l12 12M18 6 6 18" />
                            </svg>
                          </button>
                        </div>
                      ))}
                      <button
                        type="button"
                        class="text-button"
                        disabled={rule.categories.length >= 12}
                        onClick$={() => {
                          rule.categories = [...rule.categories, ""];
                          changed();
                        }}
                      >
                        Add album
                      </button>
                    </div>
                  )}
                  <details class="decision-bounds">
                    <summary>Score bounds</summary>
                    <p class="decision-hint">
                      Skip this question unless every bound is met. Leave empty
                      for no bound.
                    </p>
                    <div class="decision-bound-row decision-bound-head">
                      <span aria-hidden="true" />
                      <span aria-hidden="true">Minimum %</span>
                      <span aria-hidden="true">Maximum %</span>
                    </div>
                    {scoreNames.map((score) => (
                      <div key={score} class="decision-bound-row">
                        <span>{score[0].toUpperCase() + score.slice(1)}</span>
                        {boundKeys(score).map((key) => (
                          <input
                            key={key}
                            type="number"
                            min={0}
                            max={100}
                            step={1}
                            aria-label={`${score} ${key.endsWith("Min") ? "minimum" : "maximum"} percent`}
                            value={percentValue(rule.bounds?.[key])}
                            onInput$={(_, el) =>
                              updateBound(rule, key, el.value)
                            }
                          />
                        ))}
                      </div>
                    ))}
                  </details>
                  <label class="decision-check">
                    <input
                      type="checkbox"
                      checked={rule.automatic}
                      onChange$={(_, el) => {
                        rule.automatic = el.checked;
                        changed();
                      }}
                    />
                    <span class="decision-check-box" aria-hidden="true">
                      <svg
                        width="14"
                        height="14"
                        viewBox="0 0 24 24"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2.5"
                        stroke-linecap="round"
                        stroke-linejoin="round"
                      >
                        <path d="m5 12 4 4L19 6" />
                      </svg>
                    </span>
                    Automatically assess my photo library
                  </label>
                </fieldset>
              );
            })}
            {!state.rules.length && (
              <p class="decision-note">No questions yet.</p>
            )}
            <div class="decision-toolbar">
              <button
                type="button"
                class="secondary-button"
                disabled={state.rules.length >= 16}
                onClick$={() => {
                  state.rules = [...state.rules, newRule("yesNo")];
                  changed();
                }}
              >
                Add yes/no question
              </button>
              <button
                type="button"
                class="secondary-button"
                disabled={state.rules.length >= 16}
                onClick$={() => {
                  state.rules = [...state.rules, newRule("category")];
                  changed();
                }}
              >
                Add category question
              </button>
            </div>
            <div class="decision-toolbar decision-save">
              <button
                type="submit"
                class="primary-button"
                disabled={!state.dirty}
              >
                {state.saving ? "Saving…" : "Save questions"}
              </button>
              {state.notice && (
                <p class="decision-note" role="status">
                  {state.notice}
                </p>
              )}
              {state.dirty && (
                <p class="decision-note" role="status">
                  Save changes before assessing.
                </p>
              )}
            </div>
            {errorAt("save")}
          </fieldset>
        </form>
      )}
      {!!state.rules.length && (
        <div class="decision-assess">
          <div class="decision-toolbar">
            <button
              type="button"
              class="secondary-button"
              disabled={!canAssess || !props.image}
              onClick$={assess}
            >
              Assess selected photo
            </button>
            <p class="decision-note">
              {props.image
                ? props.image.filename
                : "Select a photo in Images to assess it."}
            </p>
          </div>
          {errorAt("photo")}
          {resultAt("photo")}
          <details class="decision-upload">
            <summary>Assess another file</summary>
            <label>
              Image (max 16 MiB) or UTF-8 text (max 16 KiB)
              <input
                type="file"
                accept="image/jpeg,image/png,image/webp,text/*,.md,.json,.csv,.log,.rs,.ts"
                disabled={!canAssess}
                onChange$={assessFile}
              />
            </label>
            <p class="decision-hint">
              Files are assessed locally and not retained; tags are saved by
              content for reuse. Uploads never change Immich albums or archive
              photos.
            </p>
            {errorAt("file")}
            {resultAt("file")}
          </details>
        </div>
      )}
    </section>
  );
});
