export type SpaceStatus = 'ok' | 'warn' | 'blocked';

export const STORAGE_FLOOR_FRACTION = 0.15;
export const DEFAULT_WARN_PERCENT = 80;
export const DEFAULT_BLOCK_PERCENT = 95;

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

export function storageBudget(freeBytes: number, totalBytes: number): number {
  return Math.max(0, freeBytes - totalBytes * STORAGE_FLOOR_FRACTION);
}

export function evaluateSpace(args: {
  pendingBytes: number;
  freeBytes: number;
  totalBytes: number;
  warnFraction: number;
  blockFraction: number;
  direction: string;
}): { status: SpaceStatus; budgetBytes: number } {
  // Uploads never consume device storage, so the cap only gates downloads.
  if (args.direction !== 'server-to-phone' || args.pendingBytes <= 0) {
    return { status: 'ok', budgetBytes: storageBudget(args.freeBytes, args.totalBytes) };
  }
  const budgetBytes = storageBudget(args.freeBytes, args.totalBytes);
  if (args.pendingBytes > args.blockFraction * budgetBytes) return { status: 'blocked', budgetBytes };
  if (args.pendingBytes > args.warnFraction * budgetBytes) return { status: 'warn', budgetBytes };
  return { status: 'ok', budgetBytes };
}

export function clampPercent(value: unknown, fallback: number): number {
  const parsed = typeof value === 'string' ? Number(value) : (value as number);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(100, Math.max(1, Math.floor(parsed)));
}
