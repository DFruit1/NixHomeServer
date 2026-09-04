import { $, component$, useStore, useTask$ } from "@builder.io/qwik";
import { api, apiBlob } from "./api";

interface ArtworkPlan {
  id: string;
  digest: string;
  warnings: string[];
}

function imageFormat(blob: Blob): string | undefined {
  switch (blob.type.split(";", 1)[0].toLowerCase()) {
    case "image/jpeg":
      return "jpg";
    case "image/png":
      return "png";
    case "image/gif":
      return "gif";
    case "image/webp":
      return "webp";
    default:
      return undefined;
  }
}

export const RemoteArtwork = component$<{
  itemId: string;
  sourceUrl: string;
  sourceLabel: string;
  title: string;
  actionNoun?: string;
  canEdit: boolean;
  mutationMode: "read-only" | "enabled";
}>((props) => {
  const state = useStore<{
    staging: boolean;
    confirming: boolean;
    error: string;
    notice: string;
    plan?: ArtworkPlan;
  }>({ staging: false, confirming: false, error: "", notice: "" });

  useTask$(({ track }) => {
    track(() => props.sourceUrl);
    track(() => props.itemId);
    state.staging = false;
    state.confirming = false;
    state.error = "";
    state.notice = "";
    state.plan = undefined;
  });

  const stage = $(async () => {
    if (!props.itemId || !props.sourceUrl || !props.canEdit || state.staging)
      return;
    const itemId = props.itemId;
    const sourceUrl = props.sourceUrl;
    state.staging = true;
    state.error = "";
    state.notice = "";
    state.plan = undefined;
    try {
      const blob = await apiBlob(sourceUrl);
      const format = imageFormat(blob);
      if (!format)
        throw new Error(
          `${props.sourceLabel} returned an unsupported image format.`,
        );
      const plan = await api<ArtworkPlan>(
        `/items/${encodeURIComponent(itemId)}/image/replacement?${new URLSearchParams({ format })}`,
        { method: "POST", headers: { "content-type": blob.type }, body: blob },
      );
      if (props.itemId === itemId && props.sourceUrl === sourceUrl)
        state.plan = plan;
    } catch (error) {
      if (props.itemId === itemId && props.sourceUrl === sourceUrl)
        state.error =
          error instanceof Error
            ? error.message
            : "The artwork could not be prepared.";
    } finally {
      if (props.itemId === itemId && props.sourceUrl === sourceUrl)
        state.staging = false;
    }
  });

  const confirm = $(async () => {
    if (!state.plan || state.confirming) return;
    const plan = state.plan;
    const itemId = props.itemId;
    state.confirming = true;
    state.error = "";
    try {
      await api(`/plans/${encodeURIComponent(plan.id)}/confirm`, {
        method: "POST",
        headers: { "if-match": `"${plan.digest}"` },
      });
      if (props.itemId !== itemId) return;
      state.plan = undefined;
      state.notice = "The artwork change was added to the mutation queue.";
    } catch (error) {
      if (props.itemId === itemId)
        state.error =
          error instanceof Error
            ? error.message
            : "The artwork could not be confirmed.";
    } finally {
      if (props.itemId === itemId) state.confirming = false;
    }
  });

  return (
    <section class="open-library-cover-preview remote-artwork-preview">
      <div>
        <strong>
          {props.actionNoun === "cover" ? "Cover" : "Artwork"} preview
        </strong>
        <span>{props.title}</span>
      </div>
      <img
        src={`/api/v1${props.sourceUrl}`}
        alt={`${props.sourceLabel} artwork for ${props.title}`}
      />
      {!state.plan ? (
        <button
          class="primary-button"
          type="button"
          disabled={!props.canEdit || state.staging}
          onClick$={stage}
        >
          {state.staging
            ? props.actionNoun === "cover"
              ? "Preparing cover…"
              : "Preparing artwork…"
            : props.actionNoun === "cover"
              ? "Prepare cover change"
              : "Prepare artwork change"}
        </button>
      ) : (
        <div class="open-library-cover-confirm">
          {state.plan.warnings.map((warning) => (
            <p class="quiet-copy" key={warning}>
              {warning}
            </p>
          ))}
          <button
            class="primary-button"
            type="button"
            disabled={props.mutationMode !== "enabled" || state.confirming}
            onClick$={confirm}
          >
            {state.confirming
              ? "Queuing…"
              : props.actionNoun === "cover"
                ? "Confirm cover change"
                : "Confirm artwork change"}
          </button>
        </div>
      )}
      {state.error && <p class="error-copy">{state.error}</p>}
      {state.notice && <p class="success-copy">{state.notice}</p>}
    </section>
  );
});
