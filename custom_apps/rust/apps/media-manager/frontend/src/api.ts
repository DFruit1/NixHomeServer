import { validateApiResponse } from "./api-contract";
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

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  if (init.body && !headers.has("content-type")) {
    headers.set("content-type", "application/json");
  }
  headers.set("accept", "application/json");
  const response = await fetch(`/api/v1${path}`, {
    credentials: "same-origin",
    ...init,
    headers,
  });
  if (
    response.status === 204 &&
    validateApiResponse(path, init.method ?? "GET", response.status, null)
  )
    return undefined as T;
  const payload: unknown = await response.json().catch(() => undefined);
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
    !validateApiResponse(path, init?.method ?? "GET", response.status, payload)
  ) {
    throw new ApiError(
      response.status,
      "invalid_response",
      "The server returned an invalid response.",
      "unknown",
    );
  }
  return payload as T;
}

export async function apiBlob(path: string): Promise<Blob> {
  const response = await fetch(`/api/v1${path}`, {
    credentials: "same-origin",
    headers: { accept: "image/jpeg,image/png,image/gif,image/webp" },
  });
  if (!response.ok) {
    const payload = (await response.json().catch(() => ({}))) as ServerError;
    throw new ApiError(
      response.status,
      payload.error?.code ?? "request_failed",
      payload.error?.message ?? "The image could not be downloaded.",
      payload.error?.requestId ?? "unknown",
    );
  }
  return response.blob();
}
