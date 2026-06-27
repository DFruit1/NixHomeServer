import { describe, expect, it } from "vitest";
import { applyDashboardStatusPayload } from "../shared/dom";
import type { AccountStatusPayload } from "../shared/types";

const payload = (
  overrides: Partial<AccountStatusPayload["accounts"][number]> = {},
): AccountStatusPayload => ({
  totals: {
    archived_message_count: 10,
    indexed_message_count: 8,
    pending_index_count: 2,
    index_coverage_percent: 80,
  },
  accounts: [
    {
      id: 42,
      status_class: "error",
      status_label: "sync failed",
      index_label: "Index behind",
      last_activity: "Synced 37 minutes ago",
      archived_message_count: 10,
      indexed_message_count: 8,
      pending_index_count: 2,
      index_coverage_percent: 80,
      archive_file_count: 10,
      overlap_file_count: 0,
      progress_note: "Index needs work.",
      diagnostic_summary: null,
      diagnostic_detail: null,
      diagnostic_impact: null,
      recommended_action: null,
      progress_warning: null,
      progress_warning_detail: null,
      progress_warning_action: null,
      ...overrides,
    },
  ],
});

describe("dashboard status island helpers", () => {
  it("updates dashboard totals and account status fields", () => {
    document.body.innerHTML = `
      <div data-dashboard-summary>
        <strong data-summary-field="archived"></strong>
        <strong data-summary-field="indexed"></strong>
        <strong data-summary-field="pending"></strong>
        <strong data-summary-field="coverage"></strong>
      </div>
      <article data-account-id="42">
        <span data-status-badge></span>
        <span data-index-pill></span>
        <strong data-progress-field="archived"></strong>
        <strong data-progress-field="indexed"></strong>
        <strong data-progress-field="pending"></strong>
        <strong data-progress-field="coverage"></strong>
        <p data-progress-note></p>
        <p data-overlap-note></p>
        <p data-last-activity></p>
        <span data-progress-bar></span>
        <span data-health-light="mailbox"></span>
        <span data-health-light="index"></span>
        <span data-health-light="storage"></span>
        <span data-health-light="paperless"></span>
        <span data-health-light="sync"></span>
        <div class="hidden" data-sync-diagnostic>
          <p data-diagnostic-summary></p>
          <p data-diagnostic-meta></p>
          <p data-diagnostic-impact></p>
          <p data-diagnostic-action></p>
          <details data-diagnostic-details><pre data-diagnostic-detail></pre></details>
        </div>
        <div class="hidden" data-progress-warning>
          <p data-progress-warning-text></p>
          <p data-progress-warning-action></p>
          <details data-progress-warning-details><pre data-progress-warning-detail></pre></details>
        </div>
      </article>
    `;

    applyDashboardStatusPayload(document, payload());

    expect(
      document.querySelector('[data-summary-field="coverage"]')?.textContent,
    ).toBe("80%");
    expect(document.querySelector("[data-status-badge]")?.textContent).toBe(
      "sync failed",
    );
    expect(document.querySelector("[data-status-badge]")?.className).toBe(
      "status error",
    );
    expect(document.querySelector("[data-index-pill]")?.textContent).toBe(
      "Index behind",
    );
    expect(
      (document.querySelector("[data-progress-bar]") as HTMLElement).style
        .width,
    ).toBe("80%");
    expect(document.querySelector("[data-last-activity]")?.textContent).toBe(
      "Synced 37 minutes ago",
    );
    expect(
      document.querySelector('[data-health-light="mailbox"]')?.className,
    ).toBe("health-light error");
    expect(
      document.querySelector('[data-health-light="index"]')?.className,
    ).toBe("health-light warning pulse-slow");
  });

  it("shows diagnostic and progress warning blocks when payload includes them", () => {
    document.body.innerHTML = `
      <article data-account-id="42">
        <span data-status-badge></span>
        <span data-index-pill></span>
        <strong data-progress-field="archived"></strong>
        <strong data-progress-field="indexed"></strong>
        <strong data-progress-field="pending"></strong>
        <strong data-progress-field="coverage"></strong>
        <p data-progress-note></p>
        <p data-overlap-note></p>
        <p data-last-activity></p>
        <span data-progress-bar></span>
        <span data-health-light="storage"></span>
        <div class="hidden" data-sync-diagnostic>
          <p data-diagnostic-summary></p>
          <p data-diagnostic-meta></p>
          <p data-diagnostic-impact></p>
          <p data-diagnostic-action></p>
          <details data-diagnostic-details><pre data-diagnostic-detail></pre></details>
        </div>
        <div class="hidden" data-progress-warning>
          <p data-progress-warning-text></p>
          <p data-progress-warning-action></p>
          <details data-progress-warning-details><pre data-progress-warning-detail></pre></details>
        </div>
      </article>
    `;

    applyDashboardStatusPayload(
      document,
      payload({
        diagnostic_phase: "download",
        diagnostic_code: "download_failed",
        diagnostic_summary: "Download failed",
        diagnostic_detail: "mbsync failed",
        progress_warning: "Index stale",
        progress_warning_action: "Run reindex",
        progress_warning_detail: "notmuch unavailable",
      }),
    );

    expect(
      document
        .querySelector("[data-sync-diagnostic]")
        ?.classList.contains("hidden"),
    ).toBe(false);
    expect(document.querySelector("[data-diagnostic-meta]")?.textContent).toBe(
      "Phase download · Code download_failed",
    );
    expect(
      document
        .querySelector("[data-progress-warning]")
        ?.classList.contains("hidden"),
    ).toBe(false);
    expect(
      document.querySelector("[data-progress-warning-action]")?.textContent,
    ).toBe("Run reindex");
  });
});
