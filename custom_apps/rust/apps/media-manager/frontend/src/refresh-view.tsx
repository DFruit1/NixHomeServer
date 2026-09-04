import { $, component$, useStore, useVisibleTask$ } from "@builder.io/qwik";
import { api, readableError } from "./api";
import { Icon } from "./icon";
import { refreshPresentation } from "./root-routing";
import type { IconName, Integration, IntegrationRefresh } from "./root-types";
import { EmptyState } from "./view-states";

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
            ["library-refresh", "folder-rescan"].includes(capability),
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
        message: "Timed out waiting for the refresh adapter to finish.",
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
          message: result.alreadyQueued
            ? "This refresh was already waiting to run."
            : "The refresh request is waiting to run.",
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
        ["library-refresh", "folder-rescan"].includes(capability),
      ),
    );
    const integrationIconMap: Record<string, IconName> = {
      audiobookshelf: "audiobookshelf",
      jellyfin: "jellyfin",
      kavita: "kavita",
      syncthing: "syncthing",
    };

    return (
      <section class="single-column">
        {refresh.error && (
          <div class="message error" role="alert">
            <Icon name="alert" size={18} />
            <span>{refresh.error}</span>
            <button type="button" onClick$={() => (refresh.error = "")}>
              ×
            </button>
          </div>
        )}
        <div class="integration-grid">
          {refreshableIntegrations.map((integration) => {
            const canRefresh = true;
            const status = refresh.statuses[integration.id];
            const presentation = refreshPresentation(status);
            const appIcon = integrationIconMap[integration.id] ?? "refresh";
            return (
              <article
                class={{
                  "integration-card": true,
                  [presentation.tone]: canRefresh && integration.available,
                }}
                aria-busy={presentation.busy ? "true" : undefined}
                key={integration.id}
              >
                <div
                  class={{
                    "integration-icon": true,
                    spinning: status?.state === "running",
                  }}
                >
                  <Icon name={appIcon} size={20} />
                </div>
                <div class="integration-copy">
                  <h3>{integration.label}</h3>
                  <p class="integration-capabilities">
                    {integration.capabilities.join(" · ") ||
                      "No manual adapter registered"}
                  </p>
                  {canRefresh && integration.available && (
                    <div
                      class={{
                        "refresh-feedback": true,
                        [presentation.tone]: true,
                      }}
                      role="status"
                      aria-live="polite"
                    >
                      <strong>{presentation.label}</strong>
                      <span>{presentation.detail}</span>
                    </div>
                  )}
                </div>
                <button
                  class="secondary-button compact-action"
                  type="button"
                  disabled={!integration.available || presentation.busy}
                  onClick$={() => triggerRefresh(integration)}
                >
                  {presentation.action}
                </button>
              </article>
            );
          })}
        </div>
        {refreshableIntegrations.length === 0 && (
          <EmptyState
            title="No refreshable applications"
            detail="Applications with a manual refresh adapter appear here once they are enabled on the server."
          />
        )}
      </section>
    );
  },
);
