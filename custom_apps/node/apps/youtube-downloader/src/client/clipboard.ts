/** Native bridge installed by the Android shell (MainActivity); absent elsewhere. */
type AndroidClipboardBridge = { readText: () => string };

const androidBridge = (): AndroidClipboardBridge | undefined =>
  (window as unknown as { AndroidClipboard?: AndroidClipboardBridge }).AndroidClipboard;

/** Whether a Paste button can read the clipboard on this platform. */
export const canReadClipboard = (): boolean =>
  typeof window !== 'undefined'
  && (androidBridge() != null || typeof navigator.clipboard?.readText === 'function');

/**
 * Read clipboard text. The Android WebView does not grant the async clipboard
 * permission, so the native shell exposes a small read-only bridge instead.
 * Returns undefined when the clipboard is empty or the read was refused.
 */
export const readClipboardText = async (): Promise<string | undefined> => {
  try {
    const bridge = androidBridge();
    const text = bridge ? bridge.readText() : await navigator.clipboard.readText();
    return text?.trim() || undefined;
  } catch {
    return undefined;
  }
};
