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
  const payload = (await response.json().catch(() => ({}))) as T & ServerError;
  if (!response.ok) {
    throw new ApiError(
      response.status,
      payload.error?.code ?? "request_failed",
      payload.error?.message ?? "The request could not be completed.",
      payload.error?.requestId ?? "unknown",
    );
  }
  return payload;
}
