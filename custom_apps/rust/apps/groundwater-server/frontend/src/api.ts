export async function request<T>(
  path: string,
  signal?: AbortSignal,
  body?: unknown,
): Promise<T> {
  const response = await fetch(path, {
    credentials: "same-origin",
    signal,
    ...(body === undefined
      ? {}
      : {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }),
  });
  if (!response.ok) {
    const error: unknown = await response.json().catch(() => null);
    const message =
      error && typeof error === "object" && "error" in error
        ? String(error.error)
        : response.statusText;
    throw new Error(
      response.status === 401
        ? "Your session expired. Reload to sign in again."
        : response.status === 403
          ? "You do not have permission for this action."
          : `${response.status}: ${message || "Request failed"}`,
    );
  }
  return response.json() as Promise<T>;
}
export const query = (values: Record<string, string | number>) =>
  new URLSearchParams(
    Object.entries(values)
      .filter(([, value]) => value !== "")
      .map(([key, value]) => [key, String(value)]),
  ).toString();
export function rangeQuery(
  device: string,
  from: string,
  to: string,
  bucket: number,
) {
  if (
    !from ||
    !to ||
    !Number.isFinite(Date.parse(from)) ||
    !Number.isFinite(Date.parse(to)) ||
    Date.parse(from) >= Date.parse(to)
  )
    throw new Error("Choose a start time before the end time.");
  return query({
    device,
    from: new Date(from).toISOString(),
    to: new Date(to).toISOString(),
    bucket,
  });
}
export function exportUrl(device: string, from: string, to: string) {
  return `/api/export?${rangeQuery(device, from, to, 0)}&format=csv`;
}
export const dateInput = (date: Date) =>
  new Date(date.getTime() - date.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 16);
export const stamp = (value: string | null | undefined) =>
  value && Number.isFinite(Date.parse(value))
    ? new Date(value).toLocaleString()
    : "—";
export const number = (value: number | null | undefined, digits = 2) =>
  value == null || !Number.isFinite(value) ? "—" : value.toFixed(digits);
export function lag(
  recorded: string | null | undefined,
  received: string | null | undefined,
) {
  if (!recorded || !received) return "Unknown clock";
  const minutes = (Date.parse(received) - Date.parse(recorded)) / 60000;
  if (!Number.isFinite(minutes)) return "Unknown clock";
  if (minutes < -1) return "Clock ahead";
  if (minutes < 1) return "<1 min";
  return minutes < 60
    ? `${Math.floor(minutes)} min`
    : minutes < 1440
      ? `${(minutes / 60).toFixed(1)} h`
      : `${(minutes / 1440).toFixed(1)} d`;
}
export const errorText = (error: unknown) =>
  error instanceof Error ? error.message : "Request failed. Try again.";
