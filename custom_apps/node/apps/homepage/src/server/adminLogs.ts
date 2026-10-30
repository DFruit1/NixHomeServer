import { constants } from 'node:fs';
import type { AdminLogEntry, AdminLogsResponse, RecentErrorSummary } from '../shared/types.js';
import { open } from 'node:fs/promises';
import type { IncomingHttpHeaders } from 'node:http';
import { TextDecoder } from 'node:util';
import type { AppConfig } from './config.js';
import { currentUserFromHeaders } from './auth.js';
import { isHomepageAdmin } from './homepageData.js';

export const SAFE_LOG_MESSAGE = 'Journal error event; message withheld';
const MAX_CACHE_BYTES = 131072;
const MAX_MANIFEST_BYTES = 8192;
const MAX_ENTRIES = 100;
const HORIZON_SECONDS = 86400;
const STALE_SECONDS = 900;
const REASON_CODES = new Set([
  'observation-invalid', 'timeout', 'output-too-large', 'collector-failed', 'collector-unavailable',
]);
const SAFE_UNITS = [
  { id: 'homepage', label: 'Homepage', unit: 'homepage.service' },
  { id: 'service-access-canary', label: 'Service access canary', unit: 'homepage-canary.service' },
  { id: 'offsite-backup', label: 'Offsite backup', unit: 'rclone-mega-kopia-sync.service' },
] as const;

type UnitConfig = { id: string; label: string; unit: string };
type Entry = AdminLogEntry;
type UnitReport = {
  unit: string;
  state: 'available' | 'unavailable' | 'invalid';
  reasonCode: string | null;
  truncated: boolean;
  entries: Entry[];
};
type Cache = { generatedAt: string; units: UnitReport[] };
type State = 'available' | 'unavailable' | 'stale' | 'invalid';
export class AdminLogsInputError extends Error {}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const strictIso = (value: unknown): string | undefined => {
  if (typeof value !== 'string' || value.length > 40) return undefined;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return undefined;
  const [, year, month, day, hour, minute, second, , zone] = match;
  const date = new Date(0);
  date.setUTCFullYear(Number(year), Number(month) - 1, Number(day));
  date.setUTCHours(Number(hour), Number(minute), Number(second), 0);
  if (date.getUTCFullYear() !== Number(year) || date.getUTCMonth() + 1 !== Number(month)
    || date.getUTCDate() !== Number(day) || Number(hour) > 23 || Number(minute) > 59 || Number(second) > 59) return undefined;
  if (zone !== 'Z' && (Number(zone.slice(1, 3)) > 23 || Number(zone.slice(4, 6)) > 59)) return undefined;
  return Number.isFinite(Date.parse(value)) ? value : undefined;
};

const epochMicroseconds = (value: string): number => {
  const fraction = /\.(\d{1,6})/.exec(value)?.[1] ?? '';
  const microseconds = Number(fraction.padEnd(6, '0') || 0);
  const firstThree = Number(fraction.slice(0, 3).padEnd(3, '0') || 0);
  return Date.parse(value) * 1000 + microseconds - firstThree * 1000;
};

const safeReadJson = async (path: string, maximum: number): Promise<unknown> => {
  let file;
  try {
    file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch {
    throw new Error('unavailable');
  }
  try {
    const info = await file.stat();
    if (!info.isFile() || info.size > maximum) throw new Error('invalid');
    const data = Buffer.alloc(Math.min(maximum + 1, info.size + 1));
    let offset = 0;
    while (offset < data.length) {
      const { bytesRead } = await file.read(data, offset, data.length - offset, offset);
      if (bytesRead === 0) break;
      offset += bytesRead;
    }
    if (offset > maximum) throw new Error('invalid');
    const text = new TextDecoder('utf-8', { fatal: true }).decode(data.subarray(0, offset));
    return JSON.parse(text) as unknown;
  } catch (error) {
    if (error instanceof SyntaxError || error instanceof TypeError || (error instanceof Error && error.message === 'invalid')) {
      throw new Error('invalid');
    }
    throw new Error('unavailable');
  } finally {
    await file.close();
  }
};

const parseManifest = (value: unknown): UnitConfig[] | undefined => {
  if (!isRecord(value) || value.schemaVersion !== 1 || !Array.isArray(value.units) || value.units.length < 2 || value.units.length > 3) return undefined;
  const seen = new Set<string>();
  const result: UnitConfig[] = [];
  for (const raw of value.units) {
    if (!isRecord(raw) || Object.keys(raw).sort().join(',') !== 'id,label,unit') return undefined;
    const known = SAFE_UNITS.find((unit) => unit.id === raw.id);
    if (!known || raw.label !== known.label || raw.unit !== known.unit || seen.has(known.id)) return undefined;
    seen.add(known.id);
    result.push({ ...known });
  }
  return seen.has('homepage') && seen.has('service-access-canary') ? result : undefined;
};

const parseCache = (value: unknown, manifest: UnitConfig[], now: number): Cache | undefined => {
  if (!isRecord(value) || Object.keys(value).sort().join(',') !== 'generatedAt,horizonSeconds,schemaVersion,units'
    || value.schemaVersion !== 1 || value.horizonSeconds !== HORIZON_SECONDS || !Array.isArray(value.units)
    || value.units.length !== manifest.length) return undefined;
  const generatedAt = strictIso(value.generatedAt);
  if (!generatedAt || Date.parse(generatedAt) > now) return undefined;
  const seen = new Set<string>();
  const units: UnitReport[] = [];
  for (const raw of value.units) {
    if (!isRecord(raw) || Object.keys(raw).sort().join(',') !== 'entries,reasonCode,state,truncated,unit'
      || typeof raw.unit !== 'string' || seen.has(raw.unit)) return undefined;
    seen.add(raw.unit);
    if (!manifest.some((unit) => unit.unit === raw.unit) || !Array.isArray(raw.entries)
      || typeof raw.truncated !== 'boolean'
      || (raw.state !== 'available' && raw.state !== 'unavailable' && raw.state !== 'invalid')
      || !(raw.reasonCode === null || (typeof raw.reasonCode === 'string' && REASON_CODES.has(raw.reasonCode)))) return undefined;
    const entries: Entry[] = [];
    if (raw.entries.length > MAX_ENTRIES || (raw.state !== 'available' && (raw.entries.length !== 0 || raw.truncated))) return undefined;
    for (const item of raw.entries) {
      if (!isRecord(item) || Object.keys(item).sort().join(',') !== 'message,priority,timestamp'
        || item.message !== SAFE_LOG_MESSAGE || !Number.isInteger(item.priority) || (item.priority as number) < 0 || (item.priority as number) > 3) return undefined;
      const timestamp = strictIso(item.timestamp);
      if (!timestamp || epochMicroseconds(timestamp) > epochMicroseconds(generatedAt)) return undefined;
      entries.push({ timestamp, priority: item.priority as AdminLogEntry['priority'], message: SAFE_LOG_MESSAGE });
    }
    if ((raw.state === 'available') !== (raw.reasonCode === null)) return undefined;
    units.push({ unit: raw.unit, state: raw.state, reasonCode: raw.reasonCode, truncated: raw.truncated, entries });
  }
  return units.length === manifest.length ? { generatedAt, units } : undefined;
};

const authorize = (config: AppConfig, headers: IncomingHttpHeaders): void => {
  const user = currentUserFromHeaders(headers, config.devUser);
  if (!isHomepageAdmin(config, user)) throw new Error('not authorised');
};

const unavailableResponse = (
  unit: string | null,
  windowSeconds: number,
  reasonCode: string,
  state: State = 'unavailable',
): AdminLogsResponse => ({
  schemaVersion: 1, state, generatedAt: new Date().toISOString(), unit,
  windowSeconds, entries: [], sourceGeneratedAt: null, truncated: false,
  privacyMode: 'metadata-only', reasonCode,
});

const readSources = async (config: AppConfig, headers: IncomingHttpHeaders, now: number) => {
  authorize(config, headers);
  if (!config.adminLogs) return { manifest: undefined, cache: undefined, state: 'unavailable' as const };
  let rawManifest: unknown;
  try {
    rawManifest = await safeReadJson(config.adminLogs.unitsFile, MAX_MANIFEST_BYTES);
  } catch {
    return { manifest: undefined, cache: undefined, state: 'unavailable' as const };
  }
  const manifest = parseManifest(rawManifest);
  if (!manifest) return { manifest: undefined, cache: undefined, state: 'invalid' as const };
  let rawCache: unknown;
  try {
    rawCache = await safeReadJson(config.adminLogs.statusFile, MAX_CACHE_BYTES);
  } catch (error) {
    return { manifest, cache: undefined, state: error instanceof Error && error.message === 'invalid' ? 'invalid' as const : 'unavailable' as const };
  }
  const cache = parseCache(rawCache, manifest, now);
  if (!cache) return { manifest, cache: undefined, state: 'invalid' as const };
  if (now - Date.parse(cache.generatedAt) > STALE_SECONDS * 1000) {
    return { manifest, cache, state: 'stale' as const };
  }
  return { manifest, cache, state: 'available' as const };
};

const parseQuery = (value: unknown): string => {
  if (value === undefined) return '';
  if (typeof value !== 'string' || Buffer.byteLength(value, 'utf8') > 128 || /[\p{Cc}\p{Cf}]/u.test(value)) {
    throw new AdminLogsInputError('invalid query');
  }
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new AdminLogsInputError('invalid query');
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new AdminLogsInputError('invalid query');
  }
  return value;
};

const integerOption = (value: unknown, fallback: number, minimum: number, maximum: number, name: string): number => {
  if (value === undefined) return fallback;
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) throw new AdminLogsInputError(`invalid ${name}`);
  return Math.min(maximum, Math.max(minimum, value));
};

export const getAdminLogs = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
  body: unknown,
): Promise<AdminLogsResponse> => {
  const now = Date.now();
  authorize(config, headers);
  if (!isRecord(body) || Object.keys(body).some((key) => !['unit', 'sinceSeconds', 'query', 'limit'].includes(key))) {
    throw new AdminLogsInputError('invalid request');
  }
  const unitId = body.unit;
  if (typeof unitId !== 'string' || unitId.length > 64) throw new AdminLogsInputError('invalid unit');
  const query = parseQuery(body.query);
  const windowSeconds = integerOption(body.sinceSeconds, 3600, 60, HORIZON_SECONDS, 'time window');
  const limit = integerOption(body.limit, 100, 1, MAX_ENTRIES, 'limit');
  const sources = await readSources(config, headers, now);
  if (!sources.manifest) return unavailableResponse(null, windowSeconds, sources.state === 'invalid' ? 'manifest-invalid' : 'source-unavailable', sources.state);
  const selected = sources.manifest.find((candidate) => candidate.id === unitId);
  if (!selected) throw new AdminLogsInputError('invalid unit');
  if (sources.state === 'unavailable') return unavailableResponse(selected.unit, windowSeconds, 'source-unavailable');
  if (sources.state === 'invalid') return { ...unavailableResponse(selected.unit, windowSeconds, 'cache-invalid'), state: 'invalid' };
  const report = sources.cache?.units.find((candidate) => candidate.unit === selected.unit);
  if (!report || report.state !== 'available' || sources.state === 'stale') {
    return {
      ...unavailableResponse(selected.unit, windowSeconds, report?.reasonCode ?? (sources.state === 'stale' ? 'cache-stale' : 'observation-unavailable')),
      state: sources.state === 'stale' ? 'stale' : report?.state === 'invalid' ? 'invalid' : 'unavailable',
      sourceGeneratedAt: sources.cache?.generatedAt ?? null,
    };
  }
  const nowMicros = now * 1000;
  const earliest = nowMicros - windowSeconds * 1_000_000;
  const entries = report.entries
    .filter((entry) => epochMicroseconds(entry.timestamp) >= earliest && epochMicroseconds(entry.timestamp) <= nowMicros)
    .filter((entry) => entry.message.includes(query))
    .sort((left, right) => epochMicroseconds(right.timestamp) - epochMicroseconds(left.timestamp) || left.priority - right.priority);
  const retainedWindowTruncated = report.truncated
    && report.entries.every((entry) => epochMicroseconds(entry.timestamp) >= earliest);
  return {
    schemaVersion: 1, state: 'available', generatedAt: new Date(now).toISOString(), unit: selected.unit,
    windowSeconds, entries: entries.slice(0, limit), sourceGeneratedAt: sources.cache?.generatedAt ?? null,
    truncated: retainedWindowTruncated || entries.length > limit, privacyMode: 'metadata-only', reasonCode: entries.length === 0 ? 'no-events-observed' : null,
  };
};

export const getRecentErrorSummary = async (config: AppConfig, headers: IncomingHttpHeaders): Promise<RecentErrorSummary> => {
  const now = Date.now();
  const sources = await readSources(config, headers, now);
  const units = (sources.manifest ?? []).map((unit) => {
    const record = sources.cache?.units.find((candidate) => candidate.unit === unit.unit);
    const state: State = sources.state !== 'available' ? sources.state
      : record?.state === 'invalid' ? 'invalid'
        : record?.state === 'unavailable' || !record ? 'unavailable' : 'available';
    const entries = state === 'available'
      ? record?.entries.filter((entry) => Date.parse(entry.timestamp) >= now - 3600_000 && Date.parse(entry.timestamp) <= now) ?? []
      : [];
    return {
      id: unit.id, label: unit.label, state, count: entries.length,
      lowerBound: state === 'available' && !!record?.truncated && entries.length === record.entries.length, sourceGeneratedAt: sources.cache?.generatedAt ?? null,
      reasonCode: state === 'available' ? entries.length === 0 ? 'no-events-observed' : null
        : sources.state === 'stale' ? 'cache-stale'
          : sources.state === 'invalid' ? 'cache-invalid' : record?.reasonCode ?? 'source-unavailable',
    };
  });
  return { schemaVersion: 1, generatedAt: new Date(now).toISOString(), units };
};

export const unavailableAdminLogs = (reasonCode: string, state: State = 'unavailable'): AdminLogsResponse =>
  unavailableResponse(null, 3600, reasonCode, state);
