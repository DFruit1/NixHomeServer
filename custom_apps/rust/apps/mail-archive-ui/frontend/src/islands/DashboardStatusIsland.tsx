import { component$, useVisibleTask$ } from "@builder.io/qwik";
import { applyDashboardStatusPayload } from "../shared/dom";
import type { AccountStatusPayload } from "../shared/types";

const RUNNING_INTERVAL_MS = 3000;
const IDLE_INTERVAL_MS = 15000;

export const DashboardStatusIsland = component$(() => {
  useVisibleTask$(
    ({ cleanup }) => {
      if (!document.querySelector("[data-dashboard-status-root]")) {
        return;
      }

      let pollTimer = 0;
      let stopped = false;

      const scheduleNextPoll = (payload: AccountStatusPayload): void => {
        const hasRunningAccount = payload.accounts.some(
          (account) => account.status_label === "syncing",
        );
        const delay =
          document.hidden || !hasRunningAccount
            ? IDLE_INTERVAL_MS
            : RUNNING_INTERVAL_MS;
        pollTimer = window.setTimeout(fetchStatus, delay);
      };

      const fetchStatus = async (): Promise<void> => {
        window.clearTimeout(pollTimer);
        if (stopped) {
          return;
        }

        try {
          const response = await fetch("/api/accounts/status", {
            cache: "no-store",
            headers: { Accept: "application/json" },
          });
          if (!response.ok) {
            throw new Error(`status ${response.status}`);
          }
          const payload = (await response.json()) as AccountStatusPayload;
          applyDashboardStatusPayload(document, payload);
          scheduleNextPoll(payload);
        } catch (error) {
          console.error("mail archive status refresh failed", error);
          pollTimer = window.setTimeout(fetchStatus, IDLE_INTERVAL_MS);
        }
      };

      const onVisibilityChange = (): void => {
        if (!document.hidden) {
          fetchStatus();
        }
      };

      document.addEventListener("visibilitychange", onVisibilityChange);
      fetchStatus();

      cleanup(() => {
        stopped = true;
        window.clearTimeout(pollTimer);
        document.removeEventListener("visibilitychange", onVisibilityChange);
      });
    },
    { strategy: "document-ready" },
  );

  return null;
});
