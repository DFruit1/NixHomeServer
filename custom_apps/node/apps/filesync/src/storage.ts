export type SpaceStatus = 'ok' | 'blocked';

/// Downloads may use at most this share of the device's free space. The native
/// sync code enforces the same fraction; it is deliberately not a setting.
export const DOWNLOAD_SPACE_FRACTION = 0.99;

export function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value < 0) return '0 B';
  if (value < 1024) return `${Math.floor(value)} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let amount = value / 1024;
  let unit = units[0];
  for (const candidate of units) {
    unit = candidate;
    if (amount < 1024 || candidate === 'TB') break;
    amount /= 1024;
  }
  return amount >= 100 ? `${Math.floor(amount)} ${unit}` : `${amount.toFixed(1)} ${unit}`;
}

export function evaluateSpace(args: { pendingBytes: number; freeBytes: number; direction: string }): SpaceStatus {
  // Uploads never consume device storage, so the limit only gates downloads.
  if (args.direction !== 'server-to-phone' || args.pendingBytes <= 0) return 'ok';
  return args.pendingBytes > args.freeBytes * DOWNLOAD_SPACE_FRACTION ? 'blocked' : 'ok';
}
