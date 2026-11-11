import { validateApiResponse } from "./api-contract";
import type { CatalogItem } from "./api-contract.generated";
export interface ServerError {
  error?: {
    code?: string;
    message?: string;
    requestId?: string;
  };
}

export class ApiError extends Error {
  readonly code: string;
  readonly requestId: string;
  readonly status: number;

  constructor(
    status: number,
    code: string,
    message: string,
    requestId: string,
  ) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.requestId = requestId;
  }
}

const codeMessages: Record<string, string> = {
  request_failed: "The request could not be completed.",
  unauthorized: "You need to sign in again.",
  forbidden: "Your account does not have access to do that.",
  not_found: "That item is no longer available.",
  timeout: "The server took too long to respond. Try again.",
};

export function readableError(error: unknown): string {
  if (error instanceof ApiError) {
    return (
      error.message ||
      codeMessages[error.code] ||
      "The request could not be completed."
    );
  }
  return error instanceof Error
    ? error.message
    : "The request could not be completed.";
}

export function errorDetail(error: unknown): string {
  if (!(error instanceof ApiError)) return "";
  return [error.code, error.requestId]
    .filter((part) => part && part !== "unknown")
    .join(" · ");
}

const API_TIMEOUT_MS = 30_000;

export async function api<T>(
  path: string,
  init: RequestInit = {},
  timeoutMs = API_TIMEOUT_MS,
): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  headers.set("accept", "application/json");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  let response: Response;
  try {
    response = await fetch(`/api/v1${path}`, {
      credentials: "same-origin",
      ...init,
      headers,
      signal: controller.signal,
    });

    if (
      response.status === 204 &&
      validateApiResponse(path, init.method ?? "GET", response.status, null)
    )
      return undefined as T;
    const payload: unknown = await response.json().catch((error: unknown) => {
      if (controller.signal.aborted) throw error;
      return undefined;
    });
    const serverError =
      payload !== null && typeof payload === "object"
        ? (payload as ServerError).error
        : undefined;
    if (!response.ok) {
      throw new ApiError(
        response.status,
        serverError?.code ?? "request_failed",
        serverError?.message ?? "The request could not be completed.",
        serverError?.requestId ?? "unknown",
      );
    }
    if (
      !validateApiResponse(
        path,
        init?.method ?? "GET",
        response.status,
        payload,
      )
    ) {
      throw new ApiError(
        response.status,
        "invalid_response",
        "The server returned an invalid response.",
        "unknown",
      );
    }
    return payload as T;
  } catch (error) {
    if (controller.signal.aborted) {
      throw new ApiError(
        408,
        "timeout",
        "The server took too long to respond. Try again.",
        "unknown",
      );
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

export async function apiBlob(path: string): Promise<Blob> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), API_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetch(`/api/v1${path}`, {
      credentials: "same-origin",
      headers: { accept: "image/jpeg,image/png,image/gif,image/webp" },
      signal: controller.signal,
    });

    if (!response.ok) {
      const payload = (await response.json().catch((error: unknown) => {
        if (controller.signal.aborted) throw error;
        return {};
      })) as ServerError;
      throw new ApiError(
        response.status,
        payload.error?.code ?? "request_failed",
        payload.error?.message ?? "The image could not be downloaded.",
        payload.error?.requestId ?? "unknown",
      );
    }
    return await response.blob();
  } catch (error) {
    if (controller.signal.aborted) {
      throw new ApiError(
        408,
        "timeout",
        "The image took too long to download. Try again.",
        "unknown",
      );
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
}

// Cursor pages are fetched sequentially so one library cannot flood the server.
export async function catalogItems(
  rootId: string,
  current: () => boolean,
  probes = false,
): Promise<{
  items: CatalogItem[];
  probePending: boolean;
}> {
  const items = new Map<string, CatalogItem>();
  let cursor: string | null = null;
  let probePending = false;
  const cursors = new Set<string>();
  do {
    if (!current()) break;
    const query = new URLSearchParams({ rootId, pageSize: "500" });
    if (cursor) query.set("cursor", cursor);
    if (probes) query.set("includeVideoProbes", "true");
    const page = await api<{
      items: CatalogItem[];
      nextCursor?: string | null;
      probePending?: boolean;
    }>(`/items?${query}`);
    if (!current()) break;
    for (const item of page.items) items.set(item.id, item);
    probePending ||= page.probePending === true;
    cursor = page.nextCursor ?? null;
    if (cursor && cursors.has(cursor))
      throw new Error("Library pagination did not advance.");
    if (cursor) cursors.add(cursor);
  } while (cursor);
  return { items: [...items.values()], probePending };
}
