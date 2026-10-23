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

const parseMeasurement = (value: unknown): Measurement => {
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
  return { kind: 'ok', completedAt, ageSeconds, maxAgeSeconds };
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

const backupFreshnessRows = (
  status: Record<string, unknown>,
): AdminDashboardWidgetRow[] => {
  const rows: AdminDashboardWidgetRow[] = [];

  const snapshot = parseMeasurement(status.kopiaSnapshot);
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

  const verify = parseMeasurement(status.kopiaVerify);
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
        rows.push(row(
          'Logical backup',
          `${generation}, ${formatDuration(ageSeconds)}${NBSP}old`,
          freshnessState(ageSeconds, maxAgeSeconds),
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
    if (!state) {
      rows.push(row('Offsite MEGA sync', 'offsite mirror record is unreadable', 'warn'));
    } else if (state === 'success') {
      const ageLimit = nonNegativeInteger(offsite.maxAgeSeconds) || 1;
      const age = ageSeconds === undefined ? '' : ` (${syncedAge(ageSeconds)})`;
      // A verified mirror that fell behind is a warning: the local encrypted
      // repository is still current, only the second copy is lagging.
      const mirrorState = ageSeconds === undefined || freshnessState(ageSeconds, ageLimit) !== 'ok' ? 'warn' : 'ok';
      rows.push(row('Offsite MEGA sync', `${message ?? 'mirror verified'}${age}`, mirrorState));
    } else {
      const stateLabel = state === 'running' || state === 'retrying' ? 'warn' : 'critical';
      const age = ageSeconds === undefined ? '' : ` (${syncedAge(ageSeconds)})`;
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
      const newest = nonNegativeInteger(zfs.newestAgeSeconds);
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

const dumpVerificationWidget = (status: Record<string, unknown>): AdminDashboardWidget => {
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
  const ageSeconds = nonNegativeInteger(logical.ageSeconds);
  const checkedAt = isoString(logical.completedAt);
  const expectedRaw = Array.isArray(logical.expected) ? logical.expected.slice(0, MAX_LIST_ENTRIES) : undefined;
  const dumpsRaw = Array.isArray(logical.dumps) ? logical.dumps.slice(0, MAX_LIST_ENTRIES) : undefined;

  if (!expectedRaw || !dumpsRaw) {
    return {
      id: 'dump-verification',
      title: 'Dump verification',
      state: 'warn',
      summary: 'The current generation has no per-dump verification record.',
      rows: [row(
        'Verification data',
        generation ? `generation ${generation} predates per-dump reporting` : 'no per-dump record',
        'warn',
      )],
      checkedAt,
    };
  }

  const dumps = new Map<string, DumpRecord>();
  for (const entry of dumpsRaw) {
    const record = parseDumpRecord(entry);
    if (record && !dumps.has(record.name)) {
      dumps.set(record.name, record);
    }
  }

  const rows: AdminDashboardWidgetRow[] = [];
  const seen = new Set<string>();
  const missing: string[] = [];
  const failed: string[] = [];
  for (const entry of expectedRaw) {
    const expected = parseExpectedDump(entry);
    if (!expected || seen.has(expected.name)) {
      continue;
    }
    seen.add(expected.name);
    const record = dumps.get(expected.name);
    if (!record) {
      missing.push(expected.name);
      rows.push(row(expected.name, 'expected dump is missing from the current generation', 'critical'));
      continue;
    }
    const integrityOk = record.integrityCheck === 'ok';
    if (!integrityOk) {
      failed.push(expected.name);
    }
    const ageText = ageSeconds === undefined ? '' : ` · ${formatDuration(ageSeconds)}${NBSP}old`;
    rows.push(row(
      expected.name,
      `${record.kind} · ${formatBytes(record.bytes)} · integrity${NBSP}${record.integrityCheck}${ageText}`,
      integrityOk ? 'ok' : 'critical',
    ));
  }

  const state = worstState(rows.map((row) => row.state ?? 'ok'));
  const summary = missing.length > 0
    ? `Missing dumps: ${missing.join(', ')}`
    : failed.length > 0
      ? `Integrity check failed: ${failed.join(', ')}`
      : `${dumps.size}/${expectedRaw.length} dumps verified in the current generation.`;

  return {
    id: 'dump-verification',
    title: 'Dump verification',
    state,
    summary,
    rows,
    checkedAt,
  };
};

const backupFreshnessWidget = (status: Record<string, unknown>): AdminDashboardWidget => {
  const rows = backupFreshnessRows(status);
  const state = rows.length > 0 ? worstState(rows.map((row) => row.state ?? 'ok')) : 'unknown';
  const checkedAt = isoString((status.logicalBackup as Record<string, unknown> | undefined)?.completedAt);
  return {
    id: 'backup-freshness',
    title: 'Backup freshness',
    state,
    summary: summarise(rows, 'All configured backup sources are within their freshness limits.'),
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

  return {
    available: true,
    generatedAt,
    generatedAgeSeconds: Math.max(0, Math.floor((Date.now() - Date.parse(generatedAt)) / 1000)),
    widgets: [backupFreshnessWidget(parsed), dumpVerificationWidget(parsed)],
  };
};
