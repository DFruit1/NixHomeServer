import { $, component$, useStore, useTask$ } from "@builder.io/qwik";
import { api, ApiError, readableError } from "./api";
import { Icon } from "./icon";
import type {
  PlanActionResponse,
  PlanListResponse,
  PlanSummary,
  CatalogItem,
} from "./root-types";
import { EmptyState, LoadingState } from "./view-states";

const OPERATION_LABELS: Record<string, string> = {
  canonicalize_names: "Rename",
  semantic_move: "Move",
  tombstone: "Archive",
  install_subtitle: "Install subtitle",
  install_metadata_sidecar: "Write metadata",
  replace_metadata_sidecar: "Update metadata",
  replace_embedded_metadata: "Embed metadata",
  install_artwork: "Add artwork",
  replace_artwork: "Replace artwork",
  archive_embedded_artwork: "Archive artwork",
};

function operationLabel(kind: string): string {
  return OPERATION_LABELS[kind] ?? "Library change";
}

type PlanTone = "pending" | "success" | "error" | "muted";

const PLAN_STATES: Record<
  PlanSummary["state"],
  { label: string; tone: PlanTone }
> = {
  previewed: { label: "Awaiting confirmation", tone: "pending" },
  queued: { label: "Queued", tone: "pending" },
  running: { label: "Running", tone: "pending" },
  completed: { label: "Completed", tone: "success" },
  failed: { label: "Failed", tone: "error" },
  expired: { label: "Expired", tone: "muted" },
  rejected: { label: "Cancelled", tone: "muted" },
};

function relativeTime(timestamp: string): string {
  const parsed = Date.parse(
    timestamp.includes("T") ? timestamp : `${timestamp.replace(" ", "T")}Z`,
  );
  if (Number.isNaN(parsed)) return timestamp;
  const seconds = Math.round((Date.now() - parsed) / 1000);
  if (seconds < 45) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} hr ago`;
  const days = Math.round(hours / 24);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}

export const ActivityView = component$<{ canEdit: boolean }>((props) => {
  const activity = useStore<{
    plans: PlanSummary[];
    scope: "mine" | "all";
    mutationMode: "read-only" | "enabled";
    loading: boolean;
    error: string;
    notice: string;
    busyId: string;
    itemPaths: Record<string, string | null>;
    pendingItems: Record<string, boolean>;
    itemErrors: Record<string, boolean>;
    drainRunning: boolean;
    generation: number;
    filter: "all" | "failed" | "previewed";
  }>({
    plans: [],
    scope: props.canEdit ? "all" : "mine",
    mutationMode: "enabled",
    loading: true,
    error: "",
    notice: "",
    busyId: "",
    itemPaths: {},
    pendingItems: {},
    itemErrors: {},
    drainRunning: false,
    generation: 0,
    filter: "all",
  });

  const load$ = $(async () => {
    const generation = activity.generation;
    const query = activity.scope === "all" ? "?scope=all" : "";
    const response = await api<PlanListResponse>(`/plans${query}`);
    if (generation !== activity.generation) return;
    activity.plans = response.plans;
    activity.mutationMode = response.mutationMode;
    if (activity.drainRunning) return;
    const missing = [
      ...new Set(response.plans.flatMap((plan) => plan.itemIds)),
    ].filter((id) => !(id in activity.itemPaths) && !activity.pendingItems[id]);
    if (!missing.length) return;
    activity.drainRunning = true;
    void (async () => {
      try {
        for (
          let offset = 0;
          offset < missing.length && activity.generation === generation;
          offset += 8
        ) {
          const batch = missing.slice(offset, offset + 8);
          for (const id of batch) activity.pendingItems[id] = true;
          await Promise.all(
            batch.map(async (id) => {
              try {
                const item = await api<CatalogItem>(
                  `/items/${encodeURIComponent(id)}`,
                );
                if (activity.generation !== generation) return;
                activity.itemPaths[id] = item.relativePath || null;
                delete activity.itemErrors[id];
              } catch (error) {
                if (activity.generation !== generation) return;
                if (
                  error instanceof ApiError &&
                  (error.status === 403 || error.status === 404)
                ) {
                  activity.itemPaths[id] = null;
                  delete activity.itemErrors[id];
                } else {
                  activity.itemErrors[id] = true;
                }
              } finally {
                delete activity.pendingItems[id];
              }
            }),
          );
        }
      } finally {
        activity.drainRunning = false;
      }
    })();
  });

  useTask$(({ cleanup, track }) => {
    track(() => activity.scope);
    const generation = ++activity.generation;
    let stopped = false;
    const tick = async () => {
      try {
        await load$();
        if (!stopped) activity.error = "";
      } catch (error) {
        if (!stopped) activity.error = readableError(error);
      } finally {
        if (!stopped) activity.loading = false;
      }
    };
    void tick();
    // Polling is a browser lifecycle concern. Starting an interval during SSR
    // (or a DOM-less component test) leaves work alive after the render ends.
    cleanup(() => {
      if (activity.generation === generation) activity.generation++;
    });
    if (typeof window === "undefined") return;
    const timer = setInterval(tick, 4000);
    cleanup(() => {
      stopped = true;
      clearInterval(timer);
    });
  });

  const retry$ = $(async (plan: PlanSummary) => {
    if (activity.busyId) return;
    activity.busyId = plan.id;
    activity.error = "";
    activity.notice = "";
    try {
      await api<PlanActionResponse>(
        `/plans/${encodeURIComponent(plan.id)}/retry`,
        { method: "POST" },
      );
      activity.notice = `${operationLabel(plan.operationKind)} was re-queued for the broker.`;
      await load$();
    } catch (error) {
      activity.error = readableError(error);
    } finally {
      activity.busyId = "";
    }
  });

  const abandon$ = $(async (plan: PlanSummary) => {
    if (activity.busyId) return;
    if (
      typeof window !== "undefined" &&
      !window.confirm(
        `Cancel this ${operationLabel(plan.operationKind).toLowerCase()}? It will not run.`,
      )
    )
      return;
    activity.busyId = plan.id;
    activity.error = "";
    activity.notice = "";
    try {
      await api<PlanActionResponse>(
        `/plans/${encodeURIComponent(plan.id)}/abandon`,
        { method: "POST" },
      );
      activity.notice = "The plan was cancelled.";
      await load$();
    } catch (error) {
      activity.error = readableError(error);
    } finally {
      activity.busyId = "";
    }
  });

  return (
    <section class="activity-view">
      {activity.error && (
        <div class="message error" role="alert">
          <Icon name="alert" size={18} />
          <span>{activity.error}</span>
          <button
            type="button"
            aria-label="Dismiss error"
            onClick$={() => (activity.error = "")}
          >
            ×
          </button>
        </div>
      )}
      {activity.notice && (
        <div class="message success" role="status">
          <Icon name="check" size={18} />
          <span>{activity.notice}</span>
        </div>
      )}
      {activity.mutationMode === "read-only" && (
        <div class="activity-banner" role="note">
          <Icon name="shield" size={18} />
          <span>
            Media Manager is in read-only mode. Queued plans will not run until
            an operator re-enables mutations.
          </span>
        </div>
      )}

      {activity.loading ? (
        <LoadingState />
      ) : activity.plans.length === 0 ? (
        <EmptyState
          title="No recent mutations"
          detail="Rename, metadata, subtitle, and artwork plans appear here with their broker state."
        />
      ) : (
        <div class="panel">
          <div class="panel-heading">
            <div>
              <h3>Mutation queue</h3>
              <p class="activity-subtitle">
                {activity.plans.length} recent plan
                {activity.plans.length === 1 ? "" : "s"}
              </p>
            </div>
            {props.canEdit && (
              <div
                class="activity-scope"
                role="group"
                aria-label="Plan visibility"
              >
                <button
                  type="button"
                  class={{
                    "scope-button": true,
                    active: activity.scope === "mine",
                  }}
                  aria-pressed={activity.scope === "mine"}
                  onClick$={() => (activity.scope = "mine")}
                >
                  Mine
                </button>
                <button
                  type="button"
                  class={{
                    "scope-button": true,
                    active: activity.scope === "all",
                  }}
                  aria-pressed={activity.scope === "all"}
                  onClick$={() => (activity.scope = "all")}
                >
                  Everyone
                </button>
              </div>
            )}
          </div>
          <div
            class="activity-scope activity-filters"
            role="group"
            aria-label="Filter activity"
          >
            {(
              [
                ["all", "All"],
                ["failed", "Failed"],
                ["previewed", "Awaiting confirmation"],
              ] as const
            ).map(([id, label]) => (
              <button
                type="button"
                class={{ "scope-button": true, active: activity.filter === id }}
                data-filter={id}
                aria-pressed={activity.filter === id}
                onClick$={() => (activity.filter = id)}
              >
                {label}
              </button>
            ))}
          </div>
          {activity.filter !== "all" &&
            !activity.plans.some((plan) => plan.state === activity.filter) && (
              <p class="quiet-copy">No matching activity.</p>
            )}
          <ul class="activity-list">
            {activity.plans
              .filter(
                (plan) =>
                  activity.filter === "all" || plan.state === activity.filter,
              )
              .map((plan) => {
                const presentation = PLAN_STATES[plan.state];
                const busy = activity.busyId === plan.id;
                return (
                  <li class="activity-row" key={plan.id}>
                    <div class="activity-row-main">
                      <div class="activity-row-title">
                        <strong>{operationLabel(plan.operationKind)}</strong>
                        <span
                          class={{
                            "plan-state": true,
                            [presentation.tone]: true,
                          }}
                        >
                          {presentation.label}
                        </span>
                        {activity.scope === "all" && (
                          <span class="plan-owner">{plan.ownerUsername}</span>
                        )}
                      </div>
                      {plan.itemIds.length > 0 && (
                        <details class="activity-items">
                          <summary>
                            {activity.itemPaths[plan.itemIds[0]]
                              ?.split("/")
                              .at(-1) ??
                              (plan.itemIds[0] in activity.itemPaths
                                ? "Item unavailable"
                                : activity.itemErrors[plan.itemIds[0]]
                                  ? "Item lookup failed; retrying…"
                                  : "Loading item…")}
                            {plan.itemIds.length > 1
                              ? ` and ${plan.itemIds.length - 1} more`
                              : ""}
                          </summary>
                          <ul>
                            {plan.itemIds.map((id) => (
                              <li key={id}>
                                {activity.itemPaths[id] ??
                                  (id in activity.itemPaths
                                    ? "Item unavailable"
                                    : activity.itemErrors[id]
                                      ? "Item lookup failed; retrying…"
                                      : "Loading item…")}
                              </li>
                            ))}
                          </ul>
                          <p>Created: {plan.createdAt}</p>
                        </details>
                      )}
                      <p class="activity-row-meta">
                        <span>
                          {plan.itemIds.length} item
                          {plan.itemIds.length === 1 ? "" : "s"}
                        </span>
                        <span aria-hidden="true">·</span>
                        <time dateTime={plan.createdAt} title={plan.createdAt}>
                          {relativeTime(plan.createdAt)}
                        </time>
                        {plan.actionCount > 0 &&
                          ["queued", "running"].includes(plan.state) && (
                            <>
                              <span aria-hidden="true">·</span>
                              <span>
                                {plan.completedActionCount}/{plan.actionCount}{" "}
                                actions
                              </span>
                            </>
                          )}
                      </p>
                      {plan.error && (
                        <p class="activity-row-error">{plan.error}</p>
                      )}
                    </div>
                    <div class="activity-row-actions">
                      {plan.state === "failed" && (
                        <button
                          class="secondary-button"
                          type="button"
                          disabled={busy}
                          onClick$={() => retry$(plan)}
                        >
                          {busy ? "Retrying…" : "Retry"}
                        </button>
                      )}
                      {(plan.state === "previewed" ||
                        plan.state === "queued") && (
                        <button
                          class="secondary-button danger"
                          type="button"
                          disabled={busy}
                          onClick$={() => abandon$(plan)}
                        >
                          {busy ? "Cancelling…" : "Cancel"}
                        </button>
                      )}
                    </div>
                  </li>
                );
              })}
          </ul>
        </div>
      )}
    </section>
  );
});
