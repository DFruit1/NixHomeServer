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
  if (!response.ok) throw await failure(response);
  return response.json() as Promise<T>;
}
/** The API's `{"error":"…"}` reply as a message an operator can act on. */
export async function failure(response: Response): Promise<Error> {
  const body: unknown = await response.json().catch(() => null);
  const message =
    body && typeof body === "object" && "error" in body
      ? String(body.error)
      : response.statusText;
  if (response.status === 401)
    return new Error("Your session expired. Reload to sign in again.");
  // The API refuses writes a browser marks as sent from another site.
  if (response.status === 403 && /cross-origin/i.test(message))
    return new Error(
      "The server refused this change because the browser reported it as sent from another site. Open the groundwater app at its own address and try again.",
    );
  if (response.status === 403)
    return new Error("You do not have permission for this action.");
  // At most four CSV exports run at once.
  if (response.status === 429)
    return new Error(
      message
        ? `${message.charAt(0).toUpperCase()}${message.slice(1)}.`
        : "The server is busy; try again shortly.",
    );
  return new Error(`${response.status}: ${message || "Request failed"}`);
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
/** Downloads `path` as a file, so a refusal (the CSV export allows four at
 * once and answers 429) is shown in place instead of replacing the app. */
export async function download(path: string, fallbackName: string) {
  const response = await fetch(path, { credentials: "same-origin" });
  if (!response.ok) throw await failure(response);
  const disposition = response.headers.get("Content-Disposition") || "";
  const name = /filename="?([^";]+)"?/.exec(disposition)?.[1] || fallbackName;
  const url = URL.createObjectURL(await response.blob());
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
export const dateInput = (date: Date) =>
  new Date(date.getTime() - date.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 16);
/** Instants before 2001 come from a logger clock that was never set (tv 0
 * seconds since boot misread as UTC); no real record predates the fleet. */
export const CLOCK_FLOOR_MS = Date.UTC(2001, 0, 1);
export const stamp = (value: string | null | undefined) => {
  const at = value ? Date.parse(value) : NaN;
  if (!Number.isFinite(at)) return "—";
  return at < CLOCK_FLOOR_MS ? "clock not set" : new Date(at).toLocaleString();
};
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
