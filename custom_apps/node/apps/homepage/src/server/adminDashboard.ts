import { readFile } from 'node:fs/promises';
import type { IncomingHttpHeaders } from 'node:http';
import type { AppConfig } from './config.js';
import { currentUserFromHeaders } from './auth.js';
import { isHomepageAdmin } from './homepageData.js';
import type {
  AdminDashboardResponse,
  AdminDashboardWidget,
  AdminDashboardWidgetRow,
  AdminDashboardWidgetState,
} from '../shared/types.js';

// The dashboard renders a cached report written by a root timer. Every value is
// re-validated and bounded here: the cache is a machine-written file, not a
// trusted API, and it must never be able to inject markup or unbounded text.
const MAX_STATUS_BYTES = 512 * 1024;
const MAX_LIST_ENTRIES = 64;
const MAX_NAME_LENGTH = 128;
const MAX_KIND_LENGTH = 32;
const MAX_MESSAGE_LENGTH = 240;
const WARN_RATIO = 0.75;
// Units and their numbers stay on one line so a narrow widget never leaves a
// stray "old" or "ago" on its own line.
const NBSP = '\u00A0';
// homepage-admin-dashboard-status.timer rewrites the cache every ten minutes.
// Cached ages are observations frozen at `generatedAt`, so the API advances
// every one of them by the time elapsed since collection and degrades the
// widgets once the cache itself stops being refreshed: three missed runs is
// attention, twelve (two hours) is action needed.
const COLLECTION_INTERVAL_SECONDS = 10 * 60;
const COLLECTION_WARN_SECONDS = 3 * COLLECTION_INTERVAL_SECONDS;
const COLLECTION_CRITICAL_SECONDS = 12 * COLLECTION_INTERVAL_SECONDS;

const SEVERITY: Record<AdminDashboardWidgetState, number> = {
  ok: 0,
  unknown: 1,
  warn: 2,
  critical: 3,
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const boundedString = (value: unknown, maximum: number): string | undefined => {
  if (typeof value !== 'string') {
    return undefined;
  }
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maximum || /[\u0000-\u001f\u007f]/.test(trimmed)) {
    return undefined;
  }
  return trimmed;
};

const nonNegativeInteger = (value: unknown, maximum = Number.MAX_SAFE_INTEGER): number | undefined => {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) {
    return undefined;
  }
  const rounded = Math.floor(value);
  return rounded > maximum ? maximum : rounded;
};

const isoString = (value: unknown): string | undefined => {
  const raw = boundedString(value, 40);
  if (!raw || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(raw)) {
    return undefined;
  }
  return Number.isNaN(Date.parse(raw)) ? undefined : raw;
};

export const formatDuration = (seconds: number): string => {
  if (seconds < 60) {
    return `${Math.max(0, Math.round(seconds))}s`;
  }
  if (seconds < 3600) {
    return `${Math.round(seconds / 60)}m`;
  }
  if (seconds < 86400) {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.round((seconds % 3600) / 60);
    return minutes > 0 ? `${hours}h${NBSP}${minutes}m` : `${hours}h`;
  }
  const days = Math.floor(seconds / 86400);
  const hours = Math.round((seconds % 86400) / 3600);
  return hours > 0 ? `${days}d${NBSP}${hours}h` : `${days}d`;
};

export const formatBytes = (bytes: number): string => {
  const units: Array<[number, string]> = [
    [1024 ** 4, 'TiB'],
    [1024 ** 3, 'GiB'],
    [1024 ** 2, 'MiB'],
    [1024, 'KiB'],
  ];
  for (const [size, unit] of units) {
    if (bytes >= size) {
      return `${(bytes / size).toFixed(1)}${NBSP}${unit}`;
    }
  }
  return `${bytes}${NBSP}B`;
};

type Measurement =
  | { kind: 'ok'; completedAt: string; ageSeconds: number; maxAgeSeconds: number }
  | { kind: 'error'; code: 'missing' | 'invalid'; detail?: string }
  | { kind: 'disabled' };

const parseMeasurement = (value: unknown, elapsedSeconds: number): Measurement => {
  if (!isRecord(value)) {
    return { kind: 'error', code: 'invalid' };
  }
  if (value.disabled === true) {
    return { kind: 'disabled' };
  }
  const errorCode = value.error;
  if (errorCode === 'missing' || errorCode === 'invalid') {
    return { kind: 'error', code: errorCode, detail: boundedString(value.detail, MAX_MESSAGE_LENGTH) };
  }
  const ageSeconds = nonNegativeInteger(value.ageSeconds);
  const maxAgeSeconds = nonNegativeInteger(value.maxAgeSeconds);
  const completedAt = isoString(value.completedAt);
  if (ageSeconds === undefined || !maxAgeSeconds || !completedAt) {
    return { kind: 'error', code: 'invalid' };
  }
  // The cached age was measured when the report was generated; the source has
  // kept ageing since then.
  return { kind: 'ok', completedAt, ageSeconds: ageSeconds + elapsedSeconds, maxAgeSeconds };
};

const freshnessState = (ageSeconds: number, maxAgeSeconds: number): AdminDashboardWidgetState => {
  const ratio = ageSeconds / maxAgeSeconds;
  if (ratio > 1) {
    return 'critical';
  }
  return ratio >= WARN_RATIO ? 'warn' : 'ok';
};

const worstState = (states: AdminDashboardWidgetState[]): AdminDashboardWidgetState =>
  states.reduce<AdminDashboardWidgetState>(
    (worst, state) => (SEVERITY[state] > SEVERITY[worst] ? state : worst),
    'ok',
  );

const summarise = (rows: AdminDashboardWidgetRow[], healthy: string): string => {
  const problem = rows.find((row) => row.state === 'critical') ?? rows.find((row) => row.state === 'warn');
  return problem ? `${problem.label}: ${problem.value}` : healthy;
};

const row = (label: string, value: string, state: AdminDashboardWidgetState = 'ok'): AdminDashboardWidgetRow =>
  state === 'ok' ? { label, value, state } : { label, value, state };

const syncedAge = (ageSeconds: number): string => `last activity ${formatDuration(ageSeconds)}${NBSP}ago`;

type Collection = {
  ageSeconds: number;
  state: AdminDashboardWidgetState;
};

const collectionHealth = (ageSeconds: number): Collection => ({
  ageSeconds,
  state: ageSeconds > COLLECTION_CRITICAL_SECONDS
    ? 'critical'
    : ageSeconds >= COLLECTION_WARN_SECONDS ? 'warn' : 'ok',
});

// Every widget states how old its cached numbers are: a report that stopped
// being refreshed must never look like a healthy one.
const collectionRow = (collection: Collection): AdminDashboardWidgetRow =>
  row(
    'Status cache',
    `collected ${formatDuration(collection.ageSeconds)}${NBSP}ago · refreshed every ${formatDuration(COLLECTION_INTERVAL_SECONDS)}`,
    collection.state,
  );

const backupFreshnessRows = (
  status: Record<string, unknown>,
  elapsedSeconds: number,
): AdminDashboardWidgetRow[] => {
  const rows: AdminDashboardWidgetRow[] = [];

  const snapshot = parseMeasurement(status.kopiaSnapshot, elapsedSeconds);
  if (snapshot.kind === 'ok') {
    rows.push(row(
      'Kopia snapshot',
      `${formatDuration(snapshot.ageSeconds)}${NBSP}old, limit ${formatDuration(snapshot.maxAgeSeconds)}`,
      freshnessState(snapshot.ageSeconds, snapshot.maxAgeSeconds),
    ));
  } else if (snapshot.kind === 'error') {
    rows.push(snapshot.code === 'missing'
      ? row('Kopia snapshot', 'no successful snapshot recorded', 'critical')
      : row('Kopia snapshot', 'snapshot record is unreadable', 'warn'));
  }

  const verify = parseMeasurement(status.kopiaVerify, elapsedSeconds);
  if (verify.kind === 'ok') {
    rows.push(row(
      'Kopia deep verify',
      `${formatDuration(verify.ageSeconds)}${NBSP}old, limit ${formatDuration(verify.maxAgeSeconds)}`,
      freshnessState(verify.ageSeconds, verify.maxAgeSeconds),
    ));
  } else if (verify.kind === 'error') {
    rows.push(row('Kopia deep verify', 'no completed deep verification recorded', 'warn'));
  }

  const logical = status.logicalBackup;
  if (isRecord(logical) && logical.disabled !== true) {
    const errorCode = logical.error;
    if (errorCode === 'missing' || errorCode === 'invalid') {
      rows.push(row('Logical backup', 'no published logical backup generation', 'critical'));
    } else {
      const generation = boundedString(logical.generation, MAX_NAME_LENGTH);
      const ageSeconds = nonNegativeInteger(logical.ageSeconds);
      const maxAgeSeconds = nonNegativeInteger(logical.maxAgeSeconds);
      if (generation && ageSeconds !== undefined && maxAgeSeconds) {
        const effectiveAge = ageSeconds + elapsedSeconds;
        rows.push(row(
          'Logical backup',
          `${generation}, ${formatDuration(effectiveAge)}${NBSP}old`,
          freshnessState(effectiveAge, maxAgeSeconds),
        ));
      } else {
        rows.push(row('Logical backup', 'logical backup record is unreadable', 'warn'));
      }
    }
  }

  const offsite = status.offsiteSync;
  if (isRecord(offsite) && offsite.disabled !== true) {
    const state = boundedString(offsite.state, MAX_KIND_LENGTH);
    const message = boundedString(offsite.message, MAX_MESSAGE_LENGTH);
    const ageSeconds = nonNegativeInteger(offsite.ageSeconds);
    const effectiveAge = ageSeconds === undefined ? undefined : ageSeconds + elapsedSeconds;
    if (!state) {
      rows.push(row('Offsite MEGA sync', 'offsite mirror record is unreadable', 'warn'));
    } else if (state === 'success') {
      const ageLimit = nonNegativeInteger(offsite.maxAgeSeconds) || 1;
      const age = effectiveAge === undefined ? '' : ` (${syncedAge(effectiveAge)})`;
      // A verified mirror that fell behind is a warning: the local encrypted
      // repository is still current, only the second copy is lagging.
      const mirrorState = effectiveAge === undefined || freshnessState(effectiveAge, ageLimit) !== 'ok' ? 'warn' : 'ok';
      rows.push(row('Offsite MEGA sync', `${message ?? 'mirror verified'}${age}`, mirrorState));
    } else {
      const stateLabel = state === 'running' || state === 'retrying' ? 'warn' : 'critical';
      const age = effectiveAge === undefined ? '' : ` (${syncedAge(effectiveAge)})`;
      rows.push(row('Offsite MEGA sync', `${message ?? `mirror ${state}`}${age}`, stateLabel));
    }
  }

  const zfs = status.zfsSnapshots;
  if (isRecord(zfs) && zfs.disabled !== true) {
    if (zfs.error !== undefined) {
      rows.push(row('ZFS snapshots', boundedString(zfs.detail, MAX_MESSAGE_LENGTH) ?? 'snapshot health is unavailable', 'unknown'));
    } else {
      const pool = boundedString(zfs.pool, MAX_NAME_LENGTH) ?? 'data pool';
      const health = boundedString(zfs.health, MAX_KIND_LENGTH) ?? 'unknown';
      const stale = nonNegativeInteger(zfs.staleDatasets) ?? 0;
      const newestCached = nonNegativeInteger(zfs.newestAgeSeconds);
      const newest = newestCached === undefined ? undefined : newestCached + elapsedSeconds;
      const details = newest === undefined ? '' : ` · newest snapshot ${formatDuration(newest)}${NBSP}old`;
      const state: AdminDashboardWidgetState = health !== 'ONLINE'
        ? 'critical'
        : stale > 0 ? 'warn' : 'ok';
      const staleText = stale > 0 ? ` · ${stale} dataset(s) past the snapshot limit` : '';
      rows.push(row('ZFS snapshots', `${pool} ${health}${staleText}${details}`, state));
    }
  }

  return rows;
};

type DumpRecord = {
  name: string;
  kind: string;
  bytes: number;
  integrityCheck: string;
  createdAt?: string;
};

const parseDumpRecord = (value: unknown): DumpRecord | undefined => {
  if (!isRecord(value)) {
    return undefined;
  }
  const name = boundedString(value.name, MAX_NAME_LENGTH);
  const kind = boundedString(value.kind, MAX_KIND_LENGTH);
  const bytes = nonNegativeInteger(value.bytes);
  const integrityCheck = boundedString(value.integrityCheck, MAX_KIND_LENGTH);
  const sha256 = boundedString(value.sha256, 64);
  if (!name || !kind || bytes === undefined || !integrityCheck || !sha256 || !/^[0-9a-f]{64}$/i.test(sha256)) {
    return undefined;
  }
  return { name, kind, bytes, integrityCheck, createdAt: isoString(value.createdAt) };
};

const parseExpectedDump = (value: unknown): { name: string; kind: string } | undefined => {
  if (!isRecord(value)) {
    return undefined;
  }
  const name = boundedString(value.name, MAX_NAME_LENGTH);
  const kind = boundedString(value.kind, MAX_KIND_LENGTH);
  return name && kind ? { name, kind } : undefined;
};

const dumpVerificationWidget = (
  status: Record<string, unknown>,
  collection: Collection,
  elapsedSeconds: number,
): AdminDashboardWidget => {
  const logical = status.logicalBackup;
  if (!isRecord(logical) || logical.disabled === true) {
    return {
      id: 'dump-verification',
      title: 'Dump verification',
      state: 'unknown',
      summary: 'Logical backup results are not configured on this server.',
      rows: [],
    };
  }
  if (logical.error !== undefined) {
    return {
      id: 'dump-verification',
      title: 'Dump verification',
      state: 'critical',
      summary: 'No logical backup generation has been published yet.',
      rows: [row('Logical backup', 'no published generation', 'critical')],
    };
  }

  const generation = boundedString(logical.generation, MAX_NAME_LENGTH);
  const cachedAgeSeconds = nonNegativeInteger(logical.ageSeconds);
  const ageSeconds = cachedAgeSeconds === undefined ? undefined : cachedAgeSeconds + elapsedSeconds;
  const maxAgeSeconds = nonNegativeInteger(logical.maxAgeSeconds);
  const checkedAt = isoString(logical.completedAt);
  const rows: AdminDashboardWidgetRow[] = [collectionRow(collection)];
  const widget = (state: AdminDashboardWidgetState, summary: string): AdminDashboardWidget => ({
    id: 'dump-verification',
    title: 'Dump verification',
    state: worstState([collection.state, state]),
    summary,
    rows,
    checkedAt,
  });

  // The collector marks a per-dump record it could not read. Silently treating
  // that as an empty configuration would report a false verification.
  if (boundedString(logical.verificationMetadata, MAX_KIND_LENGTH) === 'invalid') {
    rows.push(row('Verification metadata', 'the current generation has an unreadable per-dump verification record', 'warn'));
    return widget('warn', 'The current generation has an unreadable per-dump verification record.');
  }

  const expectedRaw = Array.isArray(logical.expected) ? logical.expected.slice(0, MAX_LIST_ENTRIES) : undefined;
  const dumpsRaw = Array.isArray(logical.dumps) ? logical.dumps.slice(0, MAX_LIST_ENTRIES) : undefined;

  if (!expectedRaw || !dumpsRaw) {
    rows.push(row(
      'Verification data',
      generation ? `generation ${generation} predates per-dump reporting` : 'no per-dump record',
      'warn',
    ));
    return widget('warn', 'The current generation has no per-dump verification record.');
  }

  const dumps = new Map<string, DumpRecord>();
  for (const entry of dumpsRaw) {
    const record = parseDumpRecord(entry);
    if (record && !dumps.has(record.name)) {
      dumps.set(record.name, record);
    }
  }

  const seen = new Set<string>();
  const missing: string[] = [];
  const failed: string[] = [];
  const stale: string[] = [];
  const aging: string[] = [];
  let unreadable = 0;
  let verified = 0;

  if (maxAgeSeconds === undefined) {
    rows.push(row('Dump age limit', 'the current generation has no configured freshness limit', 'warn'));
  }

  for (const entry of expectedRaw) {
    const expected = parseExpectedDump(entry);
    if (!expected || seen.has(expected.name)) {
      // A configured dump we cannot name is a verification gap, not a pass.
      unreadable += 1;
      continue;
    }
    seen.add(expected.name);
    const record = dumps.get(expected.name);
    if (!record) {
      missing.push(expected.name);
      rows.push(row(expected.name, 'expected dump is missing from the current generation', 'critical'));
      continue;
    }
    verified += 1;
    const integrityOk = record.integrityCheck === 'ok';
    if (!integrityOk) {
      failed.push(expected.name);
    }
    // The dump's own age decides staleness; the generation age is the fallback
    // for records written before per-dump timestamps existed.
    const dumpAge = record.createdAt
      ? Math.max(0, Math.floor((Date.now() - Date.parse(record.createdAt)) / 1000))
      : ageSeconds;
    const ageState: AdminDashboardWidgetState = dumpAge === undefined || maxAgeSeconds === undefined
      ? 'unknown'
      : freshnessState(dumpAge, maxAgeSeconds);
    if (ageState === 'critical') {
      stale.push(expected.name);
    } else if (ageState === 'warn') {
      aging.push(expected.name);
    }
    const ageText = dumpAge === undefined ? '' : ` · ${formatDuration(dumpAge)}${NBSP}old`;
    const limitText = ageState === 'ok' || maxAgeSeconds === undefined
      ? ''
      : `, limit ${formatDuration(maxAgeSeconds)}`;
    rows.push(row(
      expected.name,
      `${record.kind} · ${formatBytes(record.bytes)} · integrity${NBSP}${record.integrityCheck}${ageText}${limitText}`,
      worstState([integrityOk ? 'ok' : 'critical', ageState]),
    ));
  }

  if (unreadable > 0) {
    rows.push(row(
      'Verification metadata',
      `${unreadable} configured dump ${unreadable === 1 ? 'entry is' : 'entries are'} unreadable`,
      'warn',
    ));
  }
  if (seen.size === 0 && unreadable === 0) {
    rows.push(row('Configured dumps', 'no logical dumps are configured for this generation', 'unknown'));
  }

  const summary = missing.length > 0
    ? `Missing dumps: ${missing.join(', ')}`
    : failed.length > 0
      ? `Integrity check failed: ${failed.join(', ')}`
      : unreadable > 0
        ? `${unreadable} configured dump ${unreadable === 1 ? 'entry is' : 'entries are'} unreadable`
        : stale.length > 0
          ? `Stale dumps: ${stale.join(', ')}`
          : aging.length > 0
            ? `Dumps approaching the age limit: ${aging.join(', ')}`
            : seen.size === 0
              ? 'No logical dumps are configured for the current generation.'
              : `${verified}/${seen.size} dumps verified in the current generation.`;

  return widget(worstState(rows.map((entry) => entry.state ?? 'ok')), summary);
};

const backupFreshnessWidget = (
  status: Record<string, unknown>,
  collection: Collection,
  elapsedSeconds: number,
): AdminDashboardWidget => {
  const sourceRows = backupFreshnessRows(status, elapsedSeconds);
  const rows: AdminDashboardWidgetRow[] = [collectionRow(collection), ...sourceRows];
  const state = sourceRows.length > 0
    ? worstState(rows.map((entry) => entry.state ?? 'ok'))
    // Nothing is configured: the collection age decides, but an empty widget
    // is never reported as healthy.
    : worstState([collection.state, 'unknown']);
  const checkedAt = isoString((status.logicalBackup as Record<string, unknown> | undefined)?.completedAt);
  return {
    id: 'backup-freshness',
    title: 'Backup freshness',
    state,
    summary: sourceRows.length > 0
      ? summarise(rows, 'All configured backup sources are within their freshness limits.')
      : 'No backup source is configured on this server.',
    rows,
    checkedAt,
  };
};

const unavailable = (reason: string): AdminDashboardResponse => ({ available: false, reason, widgets: [] });

export const getAdminDashboard = async (
  config: AppConfig,
  headers: IncomingHttpHeaders,
): Promise<AdminDashboardResponse> => {
  const user = currentUserFromHeaders(headers, config.devUser);
  if (!isHomepageAdmin(config, user)) {
    throw new Error('not authorised to view the admin dashboard');
  }
  if (!config.adminDashboard) {
    return unavailable('the admin dashboard is not enabled on this server');
  }

  let raw: string;
  try {
    raw = await readFile(config.adminDashboard.statusFile, 'utf8');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return unavailable('no cached dashboard status is available yet');
    }
    return unavailable(`the cached dashboard status could not be read (${error instanceof Error ? error.message : String(error)})`);
  }

  if (Buffer.byteLength(raw, 'utf8') > MAX_STATUS_BYTES) {
    return unavailable('the cached dashboard status could not be read (report is too large)');
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch {
    return unavailable('the cached dashboard status could not be read (invalid JSON)');
  }
  if (!isRecord(parsed)) {
    return unavailable('the cached dashboard status could not be read (unexpected report shape)');
  }
  if (parsed.schemaVersion !== 1) {
    return unavailable('the cached dashboard status uses an unsupported schema version');
  }
  const generatedAt = isoString(parsed.generatedAt);
  if (!generatedAt) {
    return unavailable('the cached dashboard status could not be read (invalid generatedAt)');
  }

  const generatedAgeSeconds = Math.max(0, Math.floor((Date.now() - Date.parse(generatedAt)) / 1000));
  const collection = collectionHealth(generatedAgeSeconds);

  return {
    available: true,
    generatedAt,
    generatedAgeSeconds,
    collectionState: collection.state,
    widgets: [
      backupFreshnessWidget(parsed, collection, generatedAgeSeconds),
      dumpVerificationWidget(parsed, collection, generatedAgeSeconds),
    ],
  };
};
