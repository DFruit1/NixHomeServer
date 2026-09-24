type HttpError = Error & { httpStatus?: number };

/**
 * Whether a failed queue request should fall back to the on-device queue.
 *
 * The native shell can keep working without the server, so a transport failure
 * or an expired/absent session queues locally. Requests the server actively
 * rejected for other reasons (for example an invalid URL) stay as errors so the
 * user can correct them.
 */
export const shouldQueueLocally = (error: unknown, tauri: boolean): boolean => {
  if (!tauri) {
    return false;
  }
  if (!(error instanceof Error)) {
    // Tauri command rejections surface as plain strings.
    return true;
  }
  const status = (error as HttpError).httpStatus;
  if (status == null) {
    return true;
  }
  return status === 401 || status === 403;
};
