import { $, component$, useStore, useVisibleTask$ } from "@builder.io/qwik";
import { api, readableError } from "./api";
import { friendlyAppName } from "./display-names";
import { Icon } from "./icon";
import { refreshPresentation } from "./root-routing";
import type { IconName, Integration, IntegrationRefresh } from "./root-types";
import { EmptyState } from "./view-states";
import "./refresh-view.css";

// Both capabilities ask the app to look at its folders again; the page
// calls either one "Refresh".
const REFRESH_CAPABILITIES = ["library-refresh", "folder-rescan"];

const APP_ICONS: Record<string, IconName> = {
  audiobookshelf: "audiobookshelf",
  jellyfin: "jellyfin",
  kavita: "kavita",
  radarr: "film",
  sonarr: "video",
};

export const RefreshView = component$<{ integrations: Integration[] }>(
  (props) => {
    const refresh = useStore<{
      statuses: Record<string, IntegrationRefresh>;
      error: string;
      active: boolean;
    }>({ statuses: {}, error: "", active: true });

    useVisibleTask$(({ cleanup }) => {
      refresh.active = true;
      let stopped = false;
      let timer: ReturnType<typeof setTimeout> | undefined;
      const refreshable = props.integrations.filter(
        (integration) =>
          integration.available &&
          integration.capabilities.some((capability) =>
            REFRESH_CAPABILITIES.includes(capability),
          ),
      );
      const poll = async () => {
        try {
          const statuses = await Promise.all(
            refreshable.map((integration) =>
              api<IntegrationRefresh>(
                `/integrations/${encodeURIComponent(integration.id)}/refresh`,
              ),
            ),
          );
          if (stopped) return;
          refresh.error = "";
          for (const status of statuses) {
            refresh.statuses[status.integrationId] = status;
          }
          if (
            statuses.some((status) =>
              ["queued", "running"].includes(status.state),
            )
          ) {
            timer = setTimeout(poll, 1000);
          }
        } catch (error) {
          if (!stopped) {
            refresh.error = readableError(error);
            timer = setTimeout(poll, 2000);
          }
        }
      };
      void poll();
      cleanup(() => {
        stopped = true;
        refresh.active = false;
        if (timer) clearTimeout(timer);
      });
    });

    const followRefresh = $(async (integrationId: string) => {
      for (let attempt = 0; attempt < 7200; attempt += 1) {
        await new Promise((resolve) =>
          setTimeout(resolve, attempt === 0 ? 250 : 1000),
        );
        if (!refresh.active) return;
        try {
          const status = await api<IntegrationRefresh>(
            `/integrations/${encodeURIComponent(integrationId)}/refresh`,
          );
          refresh.error = "";
          refresh.statuses[integrationId] = status;
          if (["idle", "succeeded", "failed"].includes(status.state)) return;
        } catch (error) {
          refresh.error = readableError(error);
        }
      }
      if (!refresh.active) return;
      refresh.statuses[integrationId] = {
        integrationId,
        state: "failed",
        message: "Timed out waiting for the refresh to finish.",
      };
    });

    const triggerRefresh = $(async (integration: Integration) => {
      if (refreshPresentation(refresh.statuses[integration.id]).busy) return;
      refresh.error = "";
      try {
        const result = await api<{
          alreadyQueued: boolean;
          requestId: string;
        }>(`/integrations/${encodeURIComponent(integration.id)}/refresh`, {
          method: "POST",
        });
        refresh.statuses[integration.id] = {
          integrationId: integration.id,
          state: "queued",
          requestId: result.requestId,
        };
        await followRefresh(integration.id);
      } catch (error) {
        refresh.statuses[integration.id] = {
          integrationId: integration.id,
          state: "failed",
          message: readableError(error),
        };
      }
    });

    const refreshableIntegrations = props.integrations.filter((integration) =>
      integration.capabilities.some((capability) =>
        REFRESH_CAPABILITIES.includes(capability),
      ),
    );
    const idleIntegrations = refreshableIntegrations.filter(
      (integration) =>
        integration.available &&
        !refreshPresentation(refresh.statuses[integration.id]).busy,
    );
    const refreshAll = $(async () => {
      await Promise.all(
        refreshableIntegrations
          .filter((integration) => integration.available)
          .map((integration) => triggerRefresh(integration)),
      );
    });

    if (refreshableIntegrations.length === 0) {
      return (
        <section class="single-column">
          <EmptyState title="Nothing to refresh" />
        </section>
      );
    }

    return (
      <section class="single-column refresh-apps">
        {refresh.error && (
          <div class="message error" role="alert">
            <Icon name="alert" size={18} />
            <span>{refresh.error}</span>
            <button
              type="button"
              aria-label="Dismiss error"
              onClick$={() => (refresh.error = "")}
            >
              ×
            </button>
          </div>
        )}
        {refreshableIntegrations.length > 1 && (
          <div class="refresh-apps-toolbar">
            <button
              class="secondary-button"
              type="button"
              disabled={idleIntegrations.length === 0}
              onClick$={refreshAll}
            >
              <Icon name="refresh" size={16} />
              Refresh all
            </button>
          </div>
        )}
        <ul class="refresh-app-list">
          {refreshableIntegrations.map((integration) => {
            const presentation = refreshPresentation(
              refresh.statuses[integration.id],
            );
            const name = friendlyAppName(integration.id, integration.label);
            return (
              <li
                class={["refresh-app-row", presentation.tone]}
                aria-busy={presentation.busy ? "true" : undefined}
                key={integration.id}
              >
                <span class="refresh-app-icon" aria-hidden="true">
                  <Icon
                    name={APP_ICONS[integration.id] ?? "server"}
                    size={20}
                  />
                </span>
                <div class="refresh-app-copy">
                  <h3 title={integration.label}>{name}</h3>
                  <p
                    class={["refresh-app-status", presentation.tone]}
                    role="status"
                    aria-live="polite"
                  >
                    {integration.available
                      ? presentation.label
                      : "Not available right now"}
                    {integration.available && presentation.detail && (
                      <span>{presentation.detail}</span>
                    )}
                  </p>
                </div>
                <button
                  class="secondary-button"
                  type="button"
                  aria-label={`Refresh ${name}`}
                  disabled={!integration.available || presentation.busy}
                  onClick$={() => triggerRefresh(integration)}
                >
                  Refresh
                </button>
              </li>
            );
          })}
        </ul>
      </section>
    );
  },
);
