import type {
  MetadataHealthIssue,
  MetadataHealthResult,
} from "./api-contract.generated";
import { api } from "./api";

export interface HealthIssueEntry {
  issue: MetadataHealthIssue;
  target: MetadataHealthResult;
}

// All health selections share one FIFO, including different albums and files.
// A click handler only appends a job; draining starts on a later task, so the
// pick is rendered before any queued work (or its network I/O) begins. A job
// whose picks were all replaced by later picks is skipped: the later job
// writes the value the reviewer ended up with.
interface HealthWrite {
  run: () => Promise<void>;
  superseded?: () => boolean;
}
const healthWrites: HealthWrite[] = [];
let healthWriteDrain: Promise<void> | undefined;

async function drainHealthWrites() {
  await new Promise((resolve) => setTimeout(resolve, 0));
  for (let job = healthWrites.shift(); job; job = healthWrites.shift()) {
    if (job.superseded?.()) continue;
    try {
      await job.run();
    } catch {
      // Each job reports its own failure beside the choice it saved.
    }
  }
  healthWriteDrain = undefined;
}

export function enqueueHealthWrite(
  run: () => Promise<void>,
  superseded?: () => boolean,
): void {
  healthWrites.push({ run, superseded });
  healthWriteDrain ??= drainHealthWrites();
}

export const healthValueKey = (value: unknown) => JSON.stringify(value ?? null);

export type HealthChoice = "current" | "proposed" | "unsure";
export const healthIssueKey = (issue: MetadataHealthIssue) =>
  issue.field ?? issue.code;

export async function saveHealthDecision(
  entry: HealthIssueEntry,
  choice: HealthChoice,
  planId?: string,
) {
  // Older API responses do not carry a signature; retain their existing edit flow.
  if (!entry.issue.proposalSignature) return;
  await api(
    `/items/${encodeURIComponent(entry.target.itemId)}/metadata/health-decisions`,
    {
      method: "POST",
      body: JSON.stringify({
        issueKey: healthIssueKey(entry.issue),
        proposalSignature: entry.issue.proposalSignature,
        choice,
        ...(planId ? { planId } : {}),
      }),
    },
  );
}

export function withoutHealthEntry(
  results: MetadataHealthResult[],
  entry: HealthIssueEntry,
) {
  return results
    .map((result) =>
      result.rootId === entry.target.rootId &&
      result.itemId === entry.target.itemId
        ? {
            ...result,
            health: result.health.filter(
              (issue) => healthIssueKey(issue) !== healthIssueKey(entry.issue),
            ),
          }
        : result,
    )
    .filter((result) => result.health.length > 0);
}
