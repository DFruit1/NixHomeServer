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
  image?: ImmichImage;
  onOpenChange$?: QRL<(open: boolean) => void>;
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
  const toggle = $(async () => {
    state.open = !state.open;
    await props.onOpenChange$?.(state.open);
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
    <div class={{ "decision-questions": true, "is-open": state.open }}>
      <button
        type="button"
        class="secondary-button"
        aria-expanded={state.open}
        aria-controls="decision-editor"
        onClick$={toggle}
        disabled={busy}
      >
        {state.open ? "← Back to photos" : "Decision questions"}
      </button>
      {state.open && (
        <section
          id="decision-editor"
          aria-label="Decision questions"
          aria-busy={busy}
        >
          <h3>Decision questions</h3>
          <details class="decision-help">
            <summary>How decisions work</summary>
            <p class="muted">
              Yes/No answers can add a tag, archive the photo in Immich
              (restorable from Archive), or leave it unchanged. Category
              questions add the photo to the best-matching album at 50% or
              higher. Score bounds are optional per question; automatic
              questions run on the next library sweep within 30 minutes.
              Removing a question keeps tags and albums already applied. Saved
              tags stay private to Media Manager.
            </p>
          </details>
          {state.loading && <p role="status">Loading saved questions…</p>}
          {state.loaded && (
            <form preventdefault:submit onSubmit$={save}>
              <fieldset disabled={busy} class="decision-rules">
                <legend class="sr-only">Saved questions</legend>
                {state.rules.map((rule, i) => {
                  const kind = rule.kind === "category" ? "category" : "yesNo";
                  return (
                    <fieldset key={rule.id} class="decision-rule">
                      <legend>Question {i + 1}</legend>
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
                      <label class="decision-type">
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
                          <option value="category">
                            Categorise into albums
                          </option>
                        </select>
                      </label>
                      {kind === "category" ? (
                        <div class="decision-categories">
                          <span>Albums</span>
                          {rule.categories.map((category, position) => (
                            <div key={position} class="decision-category">
                              <label>
                                Album {position + 1}
                                <input
                                  required
                                  type="text"
                                  maxLength={96}
                                  value={category}
                                  onInput$={(_, el) => {
                                    rule.categories[position] = el.value;
                                    changed();
                                  }}
                                />
                              </label>
                              <button
                                type="button"
                                class="secondary-button"
                                aria-label={`Remove album ${position + 1}`}
                                disabled={rule.categories.length <= 2}
                                onClick$={() => {
                                  rule.categories = rule.categories.filter(
                                    (_name, index) => index !== position,
                                  );
                                  changed();
                                }}
                              >
                                Remove
                              </button>
                            </div>
                          ))}
                          <button
                            type="button"
                            class="secondary-button"
                            disabled={rule.categories.length >= 12}
                            onClick$={() => {
                              rule.categories = [...rule.categories, ""];
                              changed();
                            }}
                          >
                            Add album
                          </button>
                        </div>
                      ) : (
                        <div class="decision-actions">
                          {(["yesTag", "noTag"] as const).map((key) => (
                            <div key={key}>
                              <label>
                                If {key === "yesTag" ? "yes" : "no"}
                                <select
                                  value={
                                    rule[
                                      key === "yesTag"
                                        ? "yesArchive"
                                        : "noArchive"
                                    ]
                                      ? "archive"
                                      : rule[key] ||
                                          state.adding.includes(
                                            `${rule.id}-${key}`,
                                          )
                                        ? "tag"
                                        : "unchanged"
                                  }
                                  onChange$={(_, el) => {
                                    rule[key] = "";
                                    rule[
                                      key === "yesTag"
                                        ? "yesArchive"
                                        : "noArchive"
                                    ] = el.value === "archive";
                                    state.adding = state.adding.filter(
                                      (id) => id !== `${rule.id}-${key}`,
                                    );
                                    if (el.value === "tag")
                                      state.adding.push(`${rule.id}-${key}`);
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
                                        !state.adding.includes(
                                          `${rule.id}-${key}`,
                                        )
                                      )
                                        state.adding.push(`${rule.id}-${key}`);
                                      rule[key] = el.value;
                                      changed();
                                    }}
                                  />
                                </label>
                              )}
                            </div>
                          ))}
                        </div>
                      )}
                      <details class="decision-bounds">
                        <summary>Score bounds</summary>
                        <p class="muted">
                          Skip this question unless every bound is met. Leave
                          empty for no bound.
                        </p>
                        <div class="decision-bound-row decision-bound-head">
                          <span aria-hidden="true" />
                          <span aria-hidden="true">Minimum %</span>
                          <span aria-hidden="true">Maximum %</span>
                        </div>
                        {scoreNames.map((score) => (
                          <div key={score} class="decision-bound-row">
                            <span>
                              {score[0].toUpperCase() + score.slice(1)}
                            </span>
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
                      <label class="decision-automatic">
                        <input
                          type="checkbox"
                          checked={rule.automatic}
                          onChange$={(_, el) => {
                            rule.automatic = el.checked;
                            changed();
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
                          changed();
                        }}
                      >
                        Remove question {i + 1}
                      </button>
                    </fieldset>
                  );
                })}
                {!state.rules.length && (
                  <p class="decision-empty">No questions yet.</p>
                )}
                <div class="decision-toolbar">
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
          {state.notice && <p role="status">{state.notice}</p>}
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
          {state.dirty && (
            <p class="decision-note" role="status">
              Save changes before assessing.
            </p>
          )}
          {!!state.rules.length && (
            <div class="decision-assess">
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
                {!props.image && (
                  <p class="muted">Select a photo in Images to assess it.</p>
                )}
              </div>
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
                <p class="muted">
                  Files are assessed locally and not retained; tags are saved by
                  content for reuse. Uploads never change Immich albums or
                  archive photos.
                </p>
              </details>
            </div>
          )}
          {state.running && (
            <p role="status">Assessing {state.resultName} locally…</p>
          )}
          {state.result && (
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
                      {result.album && (
                        <span>Added to album: {result.album}</span>
                      )}
                      {result.category &&
                        !result.album &&
                        !result.albumError && (
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
        </section>
      )}
    </div>
  );
});
