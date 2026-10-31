import type {
  MetadataHealthIssue,
  MetadataHealthResult,
} from "./api-contract.generated";
import { api } from "./api";

export interface HealthIssueEntry {
  issue: MetadataHealthIssue;
  target: MetadataHealthResult;
}

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
