import { constants } from 'node:fs';
import { open } from 'node:fs/promises';
import type { IncomingHttpHeaders } from 'node:http';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
import type { MkvConversionProgress, MkvProgressResponse } from '../shared/types.js';

const MAX_STATUS_BYTES = 64 * 1024;
const STALE_AFTER_MS = 10 * 60 * 1000;

const idle = (enabled: boolean, available = true): MkvProgressResponse => ({
  enabled,
  available,
  state: 'idle',
  conversions: [],
});

const finiteNumber = (value: unknown, minimum: number, maximum: number): number | undefined => {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) {
    return undefined;
  }
  return value;
};

const text = (value: unknown, maximum: number): string | undefined => {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maximum || /[\u0000-\u001f\u007f]/.test(trimmed)) return undefined;
  return trimmed;
};

const conversionFrom = (value: unknown): MkvConversionProgress | undefined => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  const title = text(raw.title, 240);
  const itemName = text(raw.itemName, 300);
  const mediaKind = raw.mediaKind === 'movie' || raw.mediaKind === 'tv' ? raw.mediaKind : undefined;
  const itemIndex = finiteNumber(raw.itemIndex, 1, 10_000);
  const itemCount = finiteNumber(raw.itemCount, 1, 10_000);
  const percent = finiteNumber(raw.percent, 0, 100);
  const itemPercent = finiteNumber(raw.itemPercent, 0, 100);
  if (!title || !itemName || !mediaKind || itemIndex === undefined || itemCount === undefined
    || itemIndex > itemCount || percent === undefined || itemPercent === undefined) {
    return undefined;
  }
  const etaSeconds = raw.etaSeconds === null || raw.etaSeconds === undefined
    ? undefined
    : finiteNumber(raw.etaSeconds, 0, 31_536_000);
  const rateFps = raw.rateFps === null || raw.rateFps === undefined
    ? undefined
    : finiteNumber(raw.rateFps, 0, 1_000_000);
  return {
    title,
    mediaKind,
    itemName,
    itemIndex: Math.trunc(itemIndex),
    itemCount: Math.trunc(itemCount),
    percent,
    itemPercent,
    etaSeconds: etaSeconds === undefined ? undefined : Math.trunc(etaSeconds),
    rateFps,
  };
};

const queuedItems = (value: unknown): string[] | undefined => {
  if (!Array.isArray(value)) return undefined;
  const titles = value.map((item) => text(item, 300));
  if (titles.some((title) => title === undefined)) return undefined;
  return titles as string[];
};

export const getMkvProgress = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  now = Date.now(),
): Promise<MkvProgressResponse> => {
  currentUserFromHeaders(headers, config.devUser);
  if (!config.mkvmakerProgressFile) return idle(false);

  let handle;
  try {
    handle = await open(config.mkvmakerProgressFile, constants.O_RDONLY | constants.O_NOFOLLOW);
    const file = await handle.stat();
    if (!file.isFile() || file.size > MAX_STATUS_BYTES) return idle(true, false);
    const raw = JSON.parse(await handle.readFile('utf8')) as unknown;
    if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return idle(true, false);
    const status = raw as Record<string, unknown>;
    const updatedSeconds = finiteNumber(status.updatedAt, 1, Number.MAX_SAFE_INTEGER);
    if (status.schemaVersion !== 1 || updatedSeconds === undefined) return idle(true, false);
    const queued = status.queued === undefined ? undefined : queuedItems(status.queued);
    if (status.queued !== undefined && queued === undefined) return idle(true, false);
    const updatedAtMs = updatedSeconds * 1000;
    if (updatedAtMs > now + 60_000 || now - updatedAtMs > STALE_AFTER_MS) return idle(true);
    if (status.state === 'idle') {
      return { ...idle(true), updatedAt: new Date(updatedAtMs).toISOString(), queued };
    }
    if (status.state !== 'converting' || !Array.isArray(status.conversions)) return idle(true, false);
    const conversions = status.conversions.map(conversionFrom).filter((value): value is MkvConversionProgress => Boolean(value));
    if (conversions.length === 0 || conversions.length !== status.conversions.length) return idle(true, false);
    return {
      enabled: true,
      available: true,
      state: 'converting',
      updatedAt: new Date(updatedAtMs).toISOString(),
      conversions,
      queued,
    };
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    return code === 'ENOENT' ? idle(true) : idle(true, false);
  } finally {
    await handle?.close();
  }
};
