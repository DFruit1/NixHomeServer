import './styles.css';
import { getCurrent, onOpenUrl } from '@tauri-apps/plugin-deep-link';
import { openUrl } from '@tauri-apps/plugin-opener';
import { browseOrder, directoriesOnly, entryMeta, fileActionLabel, joinPath, parentPath, type BrowseEntry, type FileAction } from './browse';
import { parseSavedPairs, type Folder, type SyncDirection, type SyncPair } from './pairs';
import { DEFAULT_BLOCK_PERCENT, DEFAULT_WARN_PERCENT, clampPercent, evaluateSpace, formatBytes } from './storage';

type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;
type TauriWindow = Window & { __TAURI__?: { core?: { invoke?: Invoke } } };
type SyncPreset = { id: string; folder: string; service: string; serviceTitle: string; title: string; description: string; serverPath: string; localSubpath: string; direction: SyncDirection };
type ServerEntry = BrowseEntry;
type SyncProgress = { active: boolean; pair: string; pairs: string[]; direction: string; currentFile: string; transferred: number; skipped: number };
type SyncEstimate = { pendingBytes: number; pendingCount: number; skipped: number; direction: string; freeBytes: number; totalBytes: number; remoteTotalBytes: number };
type DeviceStorage = { freeBytes: number; totalBytes: number };
type FileTransfer = { path?: string; action: FileAction };

const invoke = (window as TauriWindow).__TAURI__?.core?.invoke;
const STORAGE_KEY = 'nixhomeserver.filesync.pairs.v1';
const SETTINGS_KEY = 'nixhomeserver.filesync.server.v1';
const SESSION_BACKUP_KEY = 'nixhomeserver.filesync.session-backup.v1';
const USER_KEY = 'nixhomeserver.filesync.user.v1';
const SPACE_PREFS_KEY = 'nixhomeserver.filesync.space-limits.v1';
const DEFAULT_SERVER = import.meta.env.VITE_FILESYNC_DEFAULT_SERVER ?? '';
const app = document.querySelector<HTMLDivElement>('#app')!;
// Reserve scroll space for feedback so a persistent connection error cannot
// cover the final folder controls, including when its text wraps on a phone.
const feedbackObserver = new ResizeObserver(([entry]) => {
  app.style.setProperty('--feedback-space', `${entry.borderBoxSize[0]!.blockSize}px`);
});

const state: { pairs: SyncPair[]; presets: SyncPreset[]; syncingPairId?: string; removingPairId?: string; progress?: SyncProgress; server: string; user?: string; offline: boolean; settingsAuthorized: boolean; backgroundStatus?: string; error: string; notice: string; estimates: Record<string, SyncEstimate | undefined>; estimatesDone: Record<string, boolean>; estimatesDoneAll: boolean; librarySizes: Record<string, LibrarySize>; sizedOnDemand: Record<string, true>; sizingPresetId?: string; deviceStorage?: DeviceStorage; warnPercent: number; blockPercent: number; transfer?: FileTransfer } = {
  pairs: readPairs(),
  presets: [],
  server: localStorage.getItem(SETTINGS_KEY) ?? DEFAULT_SERVER,
  settingsAuthorized: false,
  offline: false,
  error: '',
  notice: '',
  estimates: {},
  estimatesDone: {},
  estimatesDoneAll: false,
  librarySizes: {},
  sizedOnDemand: {},
  ...readSpacePrefs(),
};

function readSpacePrefs(): { warnPercent: number; blockPercent: number } {
  let saved: unknown = null;
  try { saved = JSON.parse(localStorage.getItem(SPACE_PREFS_KEY) ?? 'null'); } catch { saved = null; }
  const warnPercent = clampPercent((saved as { warnPercent?: unknown } | null)?.warnPercent, DEFAULT_WARN_PERCENT);
  const blockPercent = clampPercent((saved as { blockPercent?: unknown } | null)?.blockPercent, DEFAULT_BLOCK_PERCENT);
  if (blockPercent <= warnPercent) return { warnPercent: DEFAULT_WARN_PERCENT, blockPercent: DEFAULT_BLOCK_PERCENT };
  return { warnPercent, blockPercent };
}

function limitsFor(pair: SyncPair): { storageWarn: number; storageBlock: number } {
  const warn = typeof pair.storageWarn === 'number' && Number.isFinite(pair.storageWarn) ? pair.storageWarn : state.warnPercent / 100;
  const block = typeof pair.storageBlock === 'number' && Number.isFinite(pair.storageBlock) ? pair.storageBlock : state.blockPercent / 100;
  return { storageWarn: warn, storageBlock: block };
}

function currentLimits(): { storageWarn: number; storageBlock: number } {
  return { storageWarn: state.warnPercent / 100, storageBlock: state.blockPercent / 100 };
}

function applySpacePrefsToPairs(): void {
  const { storageWarn, storageBlock } = { storageWarn: state.warnPercent / 100, storageBlock: state.blockPercent / 100 };
  state.pairs = state.pairs.map((pair) => ({ ...pair, storageWarn, storageBlock }));
}

function spaceStatus(pair: SyncPair, estimate?: SyncEstimate): 'ok' | 'warn' | 'blocked' {
  if (!estimate || pair.direction !== 'server-to-phone') return 'ok';
  const { storageWarn, storageBlock } = limitsFor(pair);
  return evaluateSpace({ pendingBytes: estimate.pendingBytes, freeBytes: estimate.freeBytes, totalBytes: estimate.totalBytes, warnFraction: storageWarn, blockFraction: storageBlock, direction: pair.direction }).status;
}

function readPairs(): SyncPair[] {
  return parseSavedPairs(localStorage.getItem(STORAGE_KEY), localStorage.getItem(SETTINGS_KEY) ?? DEFAULT_SERVER);
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]!);
}

const ICONS = {
  sync: '<path d="M20 7h-5V2"/><path d="M20 7a8 8 0 0 0-14.9-2M4 17h5v5"/><path d="M4 17a8 8 0 0 0 14.9 2"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.6v.2h-4V21a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9A1.7 1.7 0 0 0 3 14H2.8v-4H3a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3A1.7 1.7 0 0 0 10 3V2.8h4V3a1.7 1.7 0 0 0 1 1.6 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.6 1h.2v4H21a1.7 1.7 0 0 0-1.6 1Z"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  cloud: '<path d="M17.5 19H6a4 4 0 0 1-.5-8 6.5 6.5 0 0 1 12.4-1.6A4.8 4.8 0 0 1 17.5 19Z"/>',
  device: '<rect x="6" y="2" width="12" height="20" rx="3"/><path d="M10 5h4M11 18h2"/>',
  music: '<path d="M9 18V5l12-3v13M9 8l12-3"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="15" r="3"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h5l2 2h7a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z"/>',
  file: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8Z"/><path d="M14 2v6h6M8 13h8M8 17h5"/>',
  arrowRight: '<path d="M5 12h14m-5-5 5 5-5 5"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
  warning: '<path d="M10.3 3.6 2.2 18a2 2 0 0 0 1.7 3h16.2a2 2 0 0 0 1.7-3L13.7 3.6a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4M12 17h.01"/>',
  upload: '<path d="M12 16V3m-5 5 5-5 5 5M5 15v5h14v-5"/>',
  download: '<path d="M12 3v13m-5-5 5 5 5-5M5 15v5h14v-5"/>',
  share: '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="m8.6 10.5 6.8-4M8.6 13.5l6.8 4"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14M10 11v6M14 11v6"/>',
  chevronUp: '<path d="m6 15 6-6 6 6"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  server: '<rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="14" width="18" height="7" rx="2"/><path d="M7 6.5h.01M7 17.5h.01M11 6.5h6M11 17.5h6"/>',
} as const;

function icon(name: keyof typeof ICONS, className = ''): string {
  return `<svg class="icon${className ? ` ${className}` : ''}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${ICONS[name]}</svg>`;
}

function serverName(): string {
  if (!state.server) return 'No server configured';
  try { return new URL(state.server).host; }
  catch { return state.server; }
}

function directionText(direction: SyncDirection): string {
  if (direction === 'phone-to-server') return 'Files move from this device to the server';
  if (direction === 'server-to-phone') return 'Files move from the server to this device';
  return 'Files move both ways';
}

function pendingFiles(estimate: SyncEstimate): string {
  const count = Math.max(0, Math.round(Number(estimate.pendingCount) || 0));
  if (count === 1) return '1 file waiting';
  return count > 1 ? `${count} files waiting` : 'Changes waiting';
}

function spaceLine(pair: SyncPair, estimate?: SyncEstimate): string {
  if (pair.direction === 'two-way' || !state.user) return '';
  const id = escapeHtml(pair.id);
  if (!estimate) {
    const text = state.estimatesDone[pair.id]
      ? 'Couldn’t check for changes. You can still try syncing.'
      : 'Checking for changes and available space…';
    return `<p class="pair-space${state.estimatesDone[pair.id] ? ' space-warn' : ''}" data-space-for="${id}">${text}</p>`;
  }
  if (estimate.pendingBytes <= 0) {
    return `<p class="pair-space" data-space-for="${id}"><span>${escapeHtml(formatBytes(estimate.freeBytes))} free on this device</span></p>`;
  }
  const status = spaceStatus(pair, estimate);
  const amount = formatBytes(estimate.pendingBytes);
  const free = `${formatBytes(estimate.freeBytes)} free`;
  if (pair.direction !== 'server-to-phone') {
    return `<p class="pair-space" data-space-for="${id}"><span>${escapeHtml(pendingFiles(estimate))} · ≈ ${escapeHtml(amount)} to upload</span></p>`;
  }
  const text = status === 'blocked'
    ? `${pendingFiles(estimate)} · ${amount} needed`
    : status === 'warn'
      ? `Low space · ${pendingFiles(estimate)} · ≈ ${amount} to download`
      : `${pendingFiles(estimate)} · ≈ ${amount} to download`;
  const tone = status === 'blocked' ? ' space-blocked' : status === 'warn' ? ' space-warn' : '';
  return `<p class="pair-space${tone}" data-space-for="${id}"><span>${escapeHtml(text)}</span><span class="pair-space-meta">${escapeHtml(free)}</span></p>`;
}

function storageSummary(): string {
  if (!state.deviceStorage || !state.user) return '';
  return `${formatBytes(state.deviceStorage.freeBytes)} free of ${formatBytes(state.deviceStorage.totalBytes)}`;
}

type PairStatus = { label: string; tone: 'active' | 'success' | 'pending' | 'warning' | 'danger' | 'neutral'; icon: keyof typeof ICONS };

function pairIsSyncing(pair: SyncPair): boolean {
  return state.syncingPairId === pair.id || Boolean(state.progress?.active && (state.progress.pair === pair.name || state.progress.pairs.includes(pair.name)));
}

function pairStatus(pair: SyncPair): PairStatus {
  const estimate = state.estimates[pair.id];
  if (pairIsSyncing(pair)) return { label: 'Syncing now', tone: 'active', icon: 'sync' };
  if (!state.user || pair.account !== state.user) return { label: state.user ? 'Different account' : 'Sign-in needed', tone: 'neutral', icon: 'user' };
  if (pair.server && pair.server !== state.server) return { label: 'Different server', tone: 'neutral', icon: 'server' };
  if (pair.direction === 'two-way') return { label: 'Needs new pair', tone: 'warning', icon: 'warning' };
  if (state.offline) return { label: 'Offline', tone: 'warning', icon: 'warning' };
  if (spaceStatus(pair, estimate) === 'blocked') return { label: 'Not enough space', tone: 'danger', icon: 'warning' };
  if (estimate?.pendingBytes) return { label: 'Changes to sync', tone: 'pending', icon: pair.direction === 'server-to-phone' ? 'download' : 'upload' };
  if (estimate) return { label: 'Up to date', tone: 'success', icon: 'check' };
  if (state.estimatesDone[pair.id]) return { label: 'Status unavailable', tone: 'warning', icon: 'warning' };
  return { label: 'Checking…', tone: 'neutral', icon: 'sync' };
}

function pairStatusBadge(pair: SyncPair): string {
  const status = pairStatus(pair);
  return `<span class="status-badge status-${status.tone}">${icon(status.icon)}<span>${escapeHtml(status.label)}</span></span>`;
}

function overviewTone(): string {
  if (!state.user) return 'is-signed-out';
  if (state.progress?.active || state.syncingPairId) return 'is-active';
  if (state.offline || state.pairs.some((pair) => spaceStatus(pair, state.estimates[pair.id]) === 'blocked')) return 'is-warning';
  return 'is-ready';
}

function overviewContent(): string {
  const active = Boolean(state.user && (state.progress?.active || state.syncingPairId));
  const blocked = state.pairs.filter((pair) => spaceStatus(pair, state.estimates[pair.id]) === 'blocked');
  const pending = state.pairs.filter((pair) => (state.estimates[pair.id]?.pendingBytes ?? 0) > 0);
  const checked = state.pairs.filter((pair) => state.estimates[pair.id]);
  let title = 'Your files, right where you need them.';
  let copy = 'Connect to your home server to choose folders and keep them in sync with this device.';
  let symbol: keyof typeof ICONS = 'sync';

  if (!state.user) {
    if (state.pairs.length) {
      title = 'Sign in to sync your folders';
      copy = 'Your saved folders are still here. Sign in to check for changes and sync.';
      symbol = 'user';
    }
  } else if (!state.pairs.length) {
    title = 'What would you like on this device?';
    copy = 'Choose a recommended folder below. The first copy starts as soon as you set it up.';
    symbol = 'folder';
  } else if (active) {
    title = 'Syncing your files';
    copy = 'The current file and transfer counts update here as the sync runs.';
    symbol = 'sync';
  } else if (state.offline) {
    title = 'You’re offline';
    copy = 'Your saved folders are still here. Reconnect to the server to check for changes and sync.';
    symbol = 'cloud';
  } else if (blocked.length) {
    title = 'Not enough device space';
    copy = `${blocked.length === 1 ? blocked[0]!.name : `${blocked.length} folders`} need${blocked.length === 1 ? 's' : ''} more free space before downloading. Free up space, then try again.`;
    symbol = 'warning';
  } else if (state.pairs.some((pair) => !state.estimatesDone[pair.id])) {
    title = 'Checking your folders';
    copy = 'Looking for changes and available space. Your folder controls will update as each check finishes.';
    symbol = 'sync';
  } else if (state.pairs.length && checked.length < state.pairs.length) {
    title = 'Some statuses are unavailable';
    copy = 'File Sync couldn’t check every folder. You can still try syncing each folder below.';
    symbol = 'warning';
  } else if (pending.length) {
    title = 'Changes are ready to sync';
    copy = `${pending.length} of ${state.pairs.length} ${state.pairs.length === 1 ? 'folder has' : 'folders have'} files waiting. Use Sync now on a folder to bring it up to date.`;
    symbol = 'download';
  } else if (state.pairs.length) {
    title = 'Everything’s in sync';
    copy = 'All of your configured folders are up to date.';
    symbol = 'check';
  }

  const action = !state.user
    ? state.server
      ? `<button class="primary-button overview-action" type="button" data-sign-in>Sign in to your server ${icon('arrowRight')}</button>`
      : `<button class="primary-button overview-action" type="button" data-open-settings>Set up your server ${icon('arrowRight')}</button>`
    : '';
  const background = state.user && state.backgroundStatus ? `<span>${icon('sync')}${escapeHtml(state.backgroundStatus)}</span>` : '';
  return `
    <div class="overview-main">
      <div class="overview-copy">
        <span class="overview-symbol">${icon(symbol)}</span>
        <h1 id="overview-title">${escapeHtml(title)}</h1>
        <p>${escapeHtml(copy)}</p>
        ${action}
      </div>
      <span class="overview-watermark" aria-hidden="true">${icon(symbol)}</span>
    </div>
    <div class="overview-meta">
      <span>${icon(state.user ? 'cloud' : 'server')}${escapeHtml(serverName())}</span>
      ${background}
    </div>
    <div class="sync-progress" id="sync-progress" aria-live="polite" aria-atomic="true" ${active ? '' : 'hidden'}>${progressCopy(state.progress, state.syncingPairId)}</div>`;
}

function updateOverview(): void {
  const overview = document.querySelector<HTMLElement>('#sync-overview');
  if (!overview) return;
  overview.className = `sync-overview ${overviewTone()}`;
  overview.innerHTML = overviewContent();
}

// The reserved server root that stands for the personal folder. Browsing it
// lists the account's own library folders, so a pair can be pointed anywhere
// under them instead of inside one pre-chosen library. The server refuses any
// path that does not start with a configured library folder, which is what
// keeps the `_Shared` and `_Backups` mounts out of reach.
const HOME_ROOT = 'home';

// How big the server folder behind a suggestion is, once it is set up. The
// total is the folder's own size; the pending amount is what a sync would move
// now, which is the part that decides whether a phone has room for it.
/// The size line for a premade folder.
///
/// A paired folder already carries the server total in its own estimate, so it
/// needs no separate lookup. An unpaired one has nothing to read it from, which
/// is why it says nothing until someone asks — the app deliberately does not
/// walk a library just to fill in a number nobody has looked at yet.
function presetSizeLine(preset: SyncPreset, pair?: SyncPair): string {
  const id = escapeHtml(preset.id);
  if (pair) {
    const estimate = state.estimates[pair.id];
    if (!estimate) {
      return state.estimatesDone[pair.id]
        ? ''
        : `<p class="suggest-size" data-preset-size-for="${id}">Checking size…</p>`;
    }
    const pending = Number(estimate.pendingBytes) || 0;
    if (pending <= 0) {
      return `<p class="suggest-size" data-preset-size-for="${id}">${escapeHtml(formatBytes(estimate.remoteTotalBytes))} on the server</p>`;
    }
    const verb = preset.direction === 'phone-to-server' ? 'to upload' : 'to download';
    return `<p class="suggest-size" data-preset-size-for="${id}">${escapeHtml(`${formatBytes(estimate.remoteTotalBytes)} on the server · ${formatBytes(pending)} ${verb}`)}</p>`;
  }

  const size = state.librarySizes[preset.id];
  if (!size) {
    return state.sizingPresetId === preset.id
      ? `<p class="suggest-size" data-preset-size-for="${id}">Calculating…</p>`
      : '';
  }
  const total = size.truncated ? `At least ${formatBytes(size.bytes)}` : formatBytes(size.bytes);
  const free = state.deviceStorage ? `${formatBytes(state.deviceStorage.freeBytes)} free on this device` : '';
  const text = free ? `${total} on the server · ${free}` : `${total} on the server`;
  return `<p class="suggest-size" data-preset-size-for="${id}">${escapeHtml(text)}</p>`;
}

function progressCopy(progress?: SyncProgress, syncingPairId?: string): string {
  if (progress?.active) {
    const names = progress.pairs.length > 1 ? `${progress.pairs.length} folders` : progress.pair;
    const directionIcon = progress.direction === 'server-to-phone' ? 'download' : 'upload';
    const file = progress.currentFile
      ? `<p class="progress-file">${icon(directionIcon)}<span>${escapeHtml(progress.currentFile)}</span></p>`
      : '<p class="progress-file">Preparing the next file…</p>';
    return `<div class="progress-heading"><strong>Syncing ${escapeHtml(names)}</strong><span>${progress.transferred} copied · ${progress.skipped} unchanged</span></div><div class="progress-track" aria-hidden="true"><span></span></div>${file}`;
  }
  if (syncingPairId) return '<div class="progress-heading"><strong>Starting sync…</strong></div><div class="progress-track" aria-hidden="true"><span></span></div>';
  return '';
}

const SERVICE_LOGOS: Record<string, string> = {
  files: '/logos/filestash.svg',
  'offline-media': '/logos/syncthing.svg',
  jellyfin: '/logos/jellyfin.svg',
  audiobookshelf: '/logos/audiobookshelf.svg',
  kavita: '/logos/kavita.svg',
};

function syncIsActive(): boolean {
  return Boolean(state.syncingPairId || state.progress?.active);
}

function pairMark(pair: SyncPair): string {
  const rootPreset = state.presets.find((item) => item.id === (pair.serverRoot ?? 'files'));
  const folder = pair.serverRoot === HOME_ROOT ? pair.serverPath.split('/')[0] : pair.serverFolder ?? rootPreset?.folder;
  if (folder === '_Music') return icon('music');
  // Prefer the media app when multiple presets expose the same home library.
  const preset = pair.serverRoot === HOME_ROOT
    ? state.presets.find((item) => item.folder === folder && item.service !== 'offline-media')
      ?? state.presets.find((item) => item.folder === folder)
    : rootPreset;
  if (preset) return serviceMark(preset.service, preset.serviceTitle);
  const service = ({ _Files: 'files', _Videos: 'jellyfin', _Audiobooks: 'audiobookshelf', _Books: 'kavita' } as Record<string, string>)[folder ?? ''];
  return service ? serviceMark(service, folder ?? service) : icon('folder');
}

function serverLocation(pair: SyncPair): string {
  // A pair picked through the personal-root browser stores the whole server
  // path, so there is no library prefix to add.
  if (pair.serverRoot === HOME_ROOT) return `/${pair.serverPath}`;
  return pair.serverRoot && pair.serverRoot !== 'files'
    ? `/${pair.serverFolder ?? pair.serverRoot}${pair.serverPath ? `/${pair.serverPath}` : ''}`
    : pair.serverPath ? `/_Files/${pair.serverPath}` : '/_Files';
}

function localLocation(pair: SyncPair): string {
  return `${pair.local.displayName}${pair.localSubpath ? ` / ${pair.localSubpath}` : ''}`;
}

type Route = { sourceLabel: string; sourceValue: string; targetLabel: string; targetValue: string; arrow: string };

function routeFor(direction: SyncDirection, localValue: string, serverValue: string): Route {
  const local = { label: 'This device', value: localValue };
  const server = { label: 'Server', value: serverValue };
  const [source, target] = direction === 'server-to-phone' ? [server, local] : [local, server];
  return { sourceLabel: source.label, sourceValue: source.value, targetLabel: target.label, targetValue: target.value, arrow: direction === 'two-way' ? '↔' : '→' };
}

// One inline rendering of a route, shared by the suggested list and the paired
// list so a folder path never changes appearance between the two.
function routeLine(direction: SyncDirection, localValue: string, serverValue: string): string {
  const route = routeFor(direction, localValue, serverValue);
  return `<span class="route-line"><span class="route-line-endpoint"><span class="route-place">${escapeHtml(route.sourceLabel)}</span><strong>${escapeHtml(route.sourceValue)}</strong></span><span class="route-arrow" aria-hidden="true">${icon(direction === 'two-way' ? 'sync' : 'arrowRight')}</span><span class="route-line-endpoint"><span class="route-place">${escapeHtml(route.targetLabel)}</span><strong>${escapeHtml(route.targetValue)}</strong></span></span>`;
}

function presetServerLocation(preset: SyncPreset): string {
  return `/${preset.folder}${preset.serverPath ? `/${preset.serverPath}` : ''}`;
}

// A suggested folder is "set up" once a pair covers it. Rendering and the
// enable handler both ask this question, so they cannot drift apart.
function pairForPreset(preset: SyncPreset): SyncPair | undefined {
  return state.pairs.find((pair) =>
    pair.server === state.server &&
    pair.account === state.user &&
    (pair.serverRoot ?? 'files') === preset.id &&
    (pair.serverPath ?? '') === (preset.serverPath ?? ''));
}

function serviceInitials(title: string): string {
  return title.trim().slice(0, 2).toUpperCase();
}

function serviceMark(service: string, serviceTitle: string): string {
  const logo = SERVICE_LOGOS[service];
  return logo
    ? `<img src="${logo}" alt="" loading="lazy" onerror="this.remove()" />`
    : `<span class="service-symbol">${escapeHtml(serviceInitials(serviceTitle))}</span>`;
}

/// The buttons on a not-yet-paired suggestion.
///
/// `Calculate size` only earns its place while the size is unknown. Once the
/// number is on screen the line answers the question, and leaving a button
/// beside it would invite a second, redundant request.
function presetActions(preset: SyncPreset, hasPairs: boolean): string {
  const sizing = state.sizingPresetId === preset.id;
  const known = Boolean(state.librarySizes[preset.id]);
  return `<div class="suggest-actions" data-preset-actions="${escapeHtml(preset.id)}">
    <button class="${hasPairs ? 'secondary-button' : 'primary-button'}" type="button" data-enable-preset="${escapeHtml(preset.id)}" aria-label="Set up ${escapeHtml(preset.title)}" ${state.syncingPairId ? 'disabled' : ''}>${icon('plus')}<span>Set up</span></button>
    ${known || sizing
      ? ''
      : `<button class="text-button" type="button" data-calc-size="${escapeHtml(preset.id)}" ${state.syncingPairId || state.sizingPresetId ? 'disabled' : ''}>Calculate size</button>`}
  </div>`;
}

function render(): void {
  const hasPairs = state.pairs.length > 0;
  const suggestSection = state.user ? `
    <section class="suggest-section" id="suggestions" aria-labelledby="suggest-heading">
      <div class="section-heading">
        <h2 id="suggest-heading">${hasPairs ? 'Add another folder' : 'Recommended for you'}</h2>
      </div>
      ${state.presets.length ? `
        <ul class="suggest-list">${state.presets.map((preset) => {
          const pair = pairForPreset(preset);
          const size = presetSizeLine(preset, pair);
          return `<li class="suggest-row${pair ? ' is-set-up' : ''}${size ? ' has-size' : ''}" data-preset-row="${escapeHtml(preset.id)}">
            <span class="service-logo" aria-hidden="true">${serviceMark(preset.service, preset.serviceTitle)}</span>
            <div class="suggest-copy">
              <div class="suggest-title-line"><h3>${escapeHtml(preset.title)}</h3>${pair ? `<span class="preset-added">${icon('check')}Added</span>` : ''}</div>
              <p class="suggest-service">${escapeHtml(preset.serviceTitle)}</p>
              <p class="suggest-description">${escapeHtml(preset.description)}</p>
            </div>
            ${pair ? size : `${presetActions(preset, hasPairs)}${size}`}
            ${routeLine(preset.direction, `/${preset.localSubpath}`, presetServerLocation(preset))}
          </li>`;
        }).join('')}</ul>
      ` : '<p class="services-empty">No recommended folders are available for this account yet. You can still pair your own folders below.</p>'}
      <div class="section-actions">
        <button class="secondary-button" type="button" id="open-files">${icon('folder')}Browse server files</button>
        <button class="text-button" type="button" id="open-pair-form">${icon('plus')}Pair your own folders</button>
      </div>
    </section>` : '';
  const pairRows = state.pairs.map((pair) => {
    const route = routeFor(pair.direction, localLocation(pair), serverLocation(pair));
    const estimate = state.estimates[pair.id];
    const blocked = spaceStatus(pair, estimate) === 'blocked';
    const busy = Boolean(syncIsActive() || state.removingPairId);
    const unavailable = pair.direction === 'two-way' || (pair.server && pair.server !== state.server) || !state.user || pair.account !== state.user;
    const syncLabel = pairIsSyncing(pair) ? 'Syncing…' : blocked ? 'Not enough space' : pair.direction === 'two-way' ? 'Recreate pair' : pair.server && pair.server !== state.server ? 'Different server' : !state.user ? 'Sign in to sync' : pair.account !== state.user ? 'Different account' : 'Sync now';
    return `
    <li class="pair-row" data-pair-id="${escapeHtml(pair.id)}">
      <div class="pair-heading">
        <span class="pair-folder-icon" aria-hidden="true">${pairMark(pair)}</span>
        <h3 class="pair-name">${escapeHtml(pair.name)}</h3>
        <div class="pair-status" data-pair-status="${escapeHtml(pair.id)}">${pairStatusBadge(pair)}</div>
      </div>
      <div class="pair-route">
        <div class="route-endpoint">
          <span class="route-role">${icon(route.sourceLabel === 'Server' ? 'server' : 'device')}From ${escapeHtml(route.sourceLabel)}</span>
          <strong class="route-path">${escapeHtml(route.sourceValue)}</strong>
        </div>
        <span class="pair-route-arrow" role="img" aria-label="${escapeHtml(directionText(pair.direction))}">${icon(pair.direction === 'two-way' ? 'sync' : 'arrowRight')}</span>
        <div class="route-endpoint">
          <span class="route-role">${icon(route.targetLabel === 'Server' ? 'server' : 'device')}To ${escapeHtml(route.targetLabel)}</span>
          <strong class="route-path">${escapeHtml(route.targetValue)}</strong>
        </div>
      </div>
      ${spaceLine(pair, estimate)}
      <div class="pair-actions">
        <button class="secondary-button sync-button" type="button" data-sync="${escapeHtml(pair.id)}" ${busy || blocked || unavailable ? 'disabled' : ''}>${icon('sync')}<span>${syncLabel}</span></button>
        <button class="text-button danger-text" type="button" data-remove="${escapeHtml(pair.id)}" aria-label="Remove ${escapeHtml(pair.name)}" ${state.syncingPairId || state.removingPairId ? 'disabled' : ''}>${icon('trash')}<span>${state.removingPairId === pair.id ? 'Removing…' : 'Remove'}</span></button>
      </div>
    </li>
  `;
  }).join('');

  app.innerHTML = `
    <div class="app-shell">
      <header class="topbar">
        <a class="brand" href="#main-content" aria-label="File Sync home"><span class="brand-mark" aria-hidden="true">${icon('sync')}</span><span>File Sync</span></a>
        <div class="topbar-actions">
          ${state.user ? `<span class="connection-pill${state.offline ? ' is-offline' : ''}"><span class="connection-dot" aria-hidden="true"></span>${state.offline ? 'Offline' : 'Connected'}</span>` : ''}
          <button class="icon-button settings-button" type="button" id="open-settings" data-open-settings aria-haspopup="dialog" aria-label="Open settings" title="Settings">${icon('settings')}<span>Settings</span></button>
        </div>
      </header>

      <main id="main-content">
        <section class="sync-overview ${overviewTone()}" id="sync-overview" aria-labelledby="overview-title">${overviewContent()}</section>

        ${hasPairs ? `
          <section class="pairs-section" aria-labelledby="pairs-heading">
            <div class="section-heading"><h2 id="pairs-heading">${state.user ? 'Synced folders' : 'Saved folders'}</h2>${state.user ? '' : '<p>Sign in to reconnect these folders and resume syncing.</p>'}</div>
            <ul class="pair-list">${pairRows}</ul>
          </section>
        ` : ''}

        ${suggestSection}
      </main>
    </div>

    <div class="toast-stack">
      <div class="toast" role="status" aria-live="polite" ${state.notice ? '' : 'hidden'}>${icon('check')}<span>${escapeHtml(state.notice)}</span></div>
      <div class="toast error-toast" role="alert" ${state.error ? '' : 'hidden'}>${icon('warning')}<span>${escapeHtml(state.error)}</span></div>
    </div>

    <dialog id="pair-dialog" class="pair-dialog" aria-labelledby="pair-heading">
      <form method="dialog" id="pair-form">
        <div class="dialog-heading"><div><h2 id="pair-heading">Pair your own folders</h2><p>Choose both locations and which way files should move.</p></div><button class="close-button" value="cancel" aria-label="Close dialog">${icon('close')}</button></div>
        <div class="field-group"><label for="pair-name">Pair name</label><input id="pair-name" name="name" required maxlength="64" placeholder="For example, Field notes" /></div>
        <div class="field-group"><label for="pick-folder">Folder on this device</label><div class="picker-row"><span class="picker-symbol">${icon('device')}</span><span id="picked-folder">No folder selected</span><button class="secondary-button" id="pick-folder" type="button">Choose</button></div></div>
        <div class="field-group"><label for="browse-server">Folder on server</label><div class="picker-row"><span class="picker-symbol">${icon('server')}</span><span id="picked-server-folder">No folder selected</span><button class="secondary-button" id="browse-server" type="button">Browse</button></div></div>
        <fieldset class="direction-fieldset">
          <legend>Sync direction</legend>
          <label class="direction-choice"><input type="radio" name="direction" value="phone-to-server" checked /><span class="direction-choice-icon">${icon('upload')}</span><span class="direction-choice-copy"><strong>This device to server</strong><small>Upload new and changed files</small></span></label>
          <label class="direction-choice"><input type="radio" name="direction" value="server-to-phone" /><span class="direction-choice-icon">${icon('download')}</span><span class="direction-choice-copy"><strong>Server to this device</strong><small>Download files for access here</small></span></label>
        </fieldset>
        <p class="form-error" id="form-error" role="alert"></p>
        <div class="dialog-actions"><button class="secondary-button" value="cancel">Cancel</button><button class="primary-button" id="save-pair" type="button">${icon('plus')}Save pair</button></div>
      </form>
    </dialog>

    <dialog id="server-browser" class="pair-dialog server-browser" aria-labelledby="server-browser-heading">
      <div class="dialog-heading"><div><h2 id="server-browser-heading">Choose a server folder</h2><p>Select the folder this pair will use.</p></div><button class="close-button" type="button" id="close-server-browser" aria-label="Close dialog">${icon('close')}</button></div>
      <p class="browser-location" id="server-browser-location">/</p>
      <div class="browser-list" id="server-browser-list"></div>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="server-browser-up">${icon('chevronUp')}Up one level</button><button class="primary-button" type="button" id="choose-server-folder">Use this folder</button></div>
    </dialog>

    <dialog id="files-dialog" class="pair-dialog files-dialog" aria-labelledby="files-heading">
      <div class="dialog-heading"><div><h2 id="files-heading">Server files</h2><p>Browse, download, or share without creating a sync pair.</p></div><button class="close-button" type="button" id="close-files" aria-label="Close files">${icon('close')}</button></div>
      <p class="browser-location" id="files-location">/</p>
      <div class="files-selection" id="files-selection" hidden>
        <span id="files-selected-count" role="status"></span>
        <button class="text-button" type="button" id="files-clear">Clear</button>
        <button class="secondary-button" type="button" id="files-share">${icon('share')}<span>Share</span></button>
        <button class="secondary-button" type="button" id="files-download">${icon('download')}<span>Download</span></button>
      </div>
      <div class="browser-list" id="files-list"></div>
      <p class="form-error" id="files-error" role="alert"></p>
      <p class="files-status" id="files-status" role="status" aria-live="polite"></p>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="files-up">${icon('chevronUp')}Up one level</button></div>
    </dialog>

    <dialog id="permission-dialog" class="pair-dialog" aria-labelledby="permission-heading">
      <div class="dialog-heading"><div><h2 id="permission-heading">All files access</h2><p>Let File Sync create and manage the selected folder.</p></div><button class="close-button" type="button" id="cancel-permission-request" aria-label="Close dialog">${icon('close')}</button></div>
      <p id="permission-status"></p>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="choose-folder-manually">Choose folder manually</button><button class="primary-button" type="button" id="open-all-files-settings">Open settings</button></div>
    </dialog>

    <dialog id="settings-dialog" class="pair-dialog settings-dialog" aria-labelledby="settings-heading">
      <div class="dialog-heading"><div><h2 id="settings-heading">Settings</h2></div><button class="close-button" type="button" id="close-settings" aria-label="Close settings">${icon('close')}</button></div>
      <section class="settings-account" aria-labelledby="connection-heading">
        <h3 id="connection-heading">Connection</h3>
        <p class="account-user">${state.user ? `${icon('user')}<span>Signed in as <strong>${escapeHtml(state.user)}</strong>${state.offline ? ' · offline' : ''}</span>` : `${icon('user')}<span>Sign in to sync your folders.</span>`}</p>
        <div class="settings-facts">
          <span>${icon('server')}${escapeHtml(serverName())}</span>
          ${state.backgroundStatus ? `<span>${icon('sync')}${escapeHtml(state.backgroundStatus)}</span>` : ''}
          <span id="storage-summary" class="storage-fact">${state.deviceStorage ? `${icon('device')}${escapeHtml(storageSummary())}` : ''}</span>
        </div>
        <div class="settings-account-actions">
          ${state.user
            ? `${state.settingsAuthorized ? '' : '<button class="secondary-button" type="button" id="unlock-settings">Unlock settings</button>'}<button class="text-button danger-text" type="button" id="sign-out">Sign out</button>`
            : `<button class="primary-button" type="button" data-sign-in>Sign in ${icon('arrowRight')}</button>`}
        </div>
      </section>
      <form method="dialog" id="settings-form">
        <section class="settings-group" aria-labelledby="server-settings-heading">
          <h3 id="server-settings-heading">Server</h3>
          <div class="field-group"><label for="server-address">Server address</label><input id="server-address" type="url" value="${escapeHtml(state.server)}" autocomplete="url" autocapitalize="none" spellcheck="false" placeholder="https://filesync-api.example.org" /></div>
        </section>
        <fieldset class="settings-group storage-settings">
          <legend>Storage limits</legend>
          <p class="settings-hint">Downloads always keep 15% of total device storage free. These limits apply to the remaining space.</p>
          <div class="limit-grid">
            <div class="limit-field"><label for="warn-limit">Warn me at</label><div class="input-suffix"><input id="warn-limit" type="number" min="1" max="100" value="${state.warnPercent}" /><span>%</span></div><small>of free space</small></div>
            <div class="limit-field"><label for="block-limit">Stop downloads at</label><div class="input-suffix"><input id="block-limit" type="number" min="1" max="100" value="${state.blockPercent}" /><span>%</span></div><small>of free space</small></div>
          </div>
        </fieldset>
        <p class="form-error" id="settings-error" role="alert"></p>
        <div class="dialog-actions"><button class="secondary-button" value="cancel">Cancel</button><button class="primary-button" id="save-server" type="button">Save settings</button></div>
      </form>
    </dialog>

    <dialog id="remove-dialog" class="pair-dialog settings-dialog" aria-labelledby="remove-heading">
      <div class="dialog-heading"><div><h2 id="remove-heading">Remove folder pair</h2></div><button class="close-button" type="button" id="cancel-remove" aria-label="Close dialog">${icon('close')}</button></div>
      <p id="remove-copy"></p>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="cancel-remove-button">Keep pair</button><button class="danger-button" type="button" id="confirm-remove">${icon('trash')}Remove pair</button></div>
    </dialog>
  `;

  feedbackObserver.disconnect();
  feedbackObserver.observe(document.querySelector<HTMLElement>('.toast-stack')!);

  bindEvents();
}

let selectedFolder: Folder | undefined;
let selectedServerPath = '';
let selectedServerRoot = HOME_ROOT;
let hasSelectedServerFolder = false;
let serverBrowserPath = '';
let filesBrowserPath = '';
let filesEntries: ServerEntry[] = [];
const selectedFiles = new Set<string>();
let filesLoad = 0;
let pendingRemoveId: string | undefined;
let progressTimer: number | undefined;

function bindEvents(): void {
  const dialog = document.querySelector<HTMLDialogElement>('#pair-dialog')!;
  const browser = document.querySelector<HTMLDialogElement>('#server-browser')!;
  const settingsDialog = document.querySelector<HTMLDialogElement>('#settings-dialog')!;
  document.querySelectorAll<HTMLButtonElement>('[data-open-settings]').forEach((button) => button.addEventListener('click', () => settingsDialog.showModal()));
  document.querySelector('#close-settings')?.addEventListener('click', () => settingsDialog.close());
  dialog.addEventListener('close', () => {
    const abandonedFolder = selectedFolder;
    if (abandonedFolder && !state.pairs.some((pair) => pair.local.uri === abandonedFolder.uri) && invoke) {
      void invoke<void>('forget_local_folder', { folderUri: abandonedFolder.uri }).catch(() => undefined);
    }
    selectedFolder = undefined;
    selectedServerPath = '';
    selectedServerRoot = HOME_ROOT;
    hasSelectedServerFolder = false;
  });
  const openPairForm = async () => { if (await ensureSettingsAuthorized()) dialog.showModal(); };
  document.querySelector('#open-pair-form')?.addEventListener('click', () => void openPairForm());
  document.querySelectorAll<HTMLButtonElement>('[data-calc-size]').forEach((button) => button.addEventListener('click', () => {
    void calculatePresetSize(button.dataset.calcSize!);
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-enable-preset]').forEach((button) => button.addEventListener('click', async () => {
    const preset = state.presets.find((item) => item.id === button.dataset.enablePreset);
    if (!invoke || !preset) return;
    if (!(await ensureSettingsAuthorized())) return;
    button.disabled = true;
    try {
      const folder = await obtainPresetFolder(preset);
      if (!folder) { button.disabled = false; return; }
      const pair: SyncPair = { id: crypto.randomUUID(), name: preset.title, local: folder, serverRoot: preset.id, serverFolder: preset.folder, serverPath: preset.serverPath, localSubpath: preset.localSubpath, direction: preset.direction, server: state.server, account: state.user, ...currentLimits() };
      if (pairForPreset(preset)) {
        if (!state.pairs.some((item) => item.local.uri === folder.uri)) await invoke<void>('forget_local_folder', { folderUri: folder.uri });
        state.error = 'That server folder already has a sync pair.';
      } else {

        state.pairs = [...state.pairs, pair];
        await persistPairs();
        state.notice = `${preset.title} enabled. Copying files now.`;
        state.error = '';
        state.syncingPairId = pair.id;
        render();
        startProgressPolling();
        try {
          const result = await invoke<{ transferred: number; skipped: number }>('sync_pair', { pair: { ...pair, ...limitsFor(pair) } });
          state.notice = `Sync complete: ${result.transferred} transferred, ${result.skipped} unchanged.`;
          state.offline = false;
          await saveSessionBackup();
        } catch (error) {
          showError(error);
          state.notice = 'Pair saved. Use Sync now to retry.';
        }
        state.syncingPairId = undefined;
        state.progress = undefined;
        stopProgressPolling();
      }
    } catch (error) { showError(error); }
    render();
    void refreshEstimates(true);
  }));
  document.querySelector('#save-server')?.addEventListener('click', async () => {
    const input = document.querySelector<HTMLInputElement>('#server-address')!;
    const warnInput = document.querySelector<HTMLInputElement>('#warn-limit')!;
    const blockInput = document.querySelector<HTMLInputElement>('#block-limit')!;
    const settingsError = document.querySelector<HTMLElement>('#settings-error')!;
    let nextServer: string;
    try { nextServer = normalizeServerAddress(input.value); }
    catch (error) {
      settingsError.textContent = error instanceof Error ? error.message : String(error);
      input.focus();
      return;
    }
    const warnPercent = clampPercent(warnInput.value, state.warnPercent);
    const blockPercent = clampPercent(blockInput.value, state.blockPercent);
    if (blockPercent <= warnPercent) {
      settingsError.textContent = 'The stop limit must be higher than the warn limit.';
      blockInput.focus();
      return;
    }
    state.warnPercent = warnPercent;
    state.blockPercent = blockPercent;
    localStorage.setItem(SPACE_PREFS_KEY, JSON.stringify({ warnPercent, blockPercent }));
    applySpacePrefsToPairs();
    const serverChanged = nextServer !== state.server;
    if (state.user && serverChanged && invoke) {
      try { await invoke<void>('logout'); localStorage.removeItem(SESSION_BACKUP_KEY); localStorage.removeItem(USER_KEY); state.user = undefined; state.offline = false; state.settingsAuthorized = false; }
      catch (error) { setError(error); return; }
    }
    state.server = nextServer;
    if (serverChanged) state.presets = [];
    localStorage.setItem(SETTINGS_KEY, state.server);
    state.notice = state.server ? 'Settings saved on this device.' : 'Server address cleared.';
    state.error = '';
    try { await persistPairs(); } catch { /* The notice already explains the save; pairs retry on next change. */ }
    render();
    void refreshEstimates();
  });

  document.querySelectorAll<HTMLButtonElement>('[data-sign-in]').forEach((button) => button.addEventListener('click', async () => {
    if (!invoke) return;
    const server = state.server.trim();
    if (!server) {
      state.error = 'Open Settings to add a sync server address before signing in.';
      render();
      return;
    }
    try { await beginInteractiveLogin(); } catch (error) {
      setError(error);
    }
  }));

  document.querySelector('#unlock-settings')?.addEventListener('click', async () => {
    try { await beginInteractiveLogin(); } catch (error) { setError(error); }
  });

  document.querySelector('#sign-out')?.addEventListener('click', async () => {
    if (!invoke) return;
    try {
      await invoke<void>('logout');
      localStorage.removeItem(SESSION_BACKUP_KEY);
      localStorage.removeItem(USER_KEY);
      state.user = undefined;
      state.offline = false;
      state.settingsAuthorized = false;
      state.presets = [];
      state.estimates = {};
      state.estimatesDone = {};
      state.deviceStorage = undefined;
      state.notice = 'Signed out of the sync server.';
      state.error = '';
      render();
    } catch (error) {
      setError(error);
    }
  });

  document.querySelector('#pick-folder')?.addEventListener('click', async () => {
    if (!invoke) {
      document.querySelector<HTMLElement>('#form-error')!.textContent = 'Folder selection is available in the installed app.';
      return;
    }
    try {
      selectedFolder = await invoke<Folder | null>('pick_local_folder') ?? undefined;
      const name = document.querySelector<HTMLElement>('#picked-folder');
      if (name && selectedFolder) name.textContent = selectedFolder.displayName;
    } catch (error) {
      document.querySelector<HTMLElement>('#form-error')!.textContent = error instanceof Error ? error.message : String(error);
    }
  });

  document.querySelector('#browse-server')?.addEventListener('click', async () => {
    if (!invoke || !state.user) {
      document.querySelector<HTMLElement>('#form-error')!.textContent = 'Sign in before choosing a server folder.';
      return;
    }
    selectedServerRoot = HOME_ROOT;
    serverBrowserPath = '';
    await renderServerBrowser();
    browser.showModal();
  });
  document.querySelector('#close-server-browser')?.addEventListener('click', () => browser.close());
  document.querySelector('#server-browser-up')?.addEventListener('click', async () => {
    serverBrowserPath = parentPath(serverBrowserPath);
    await renderServerBrowser();
  });
  document.querySelector('#choose-server-folder')?.addEventListener('click', () => {
    selectedServerPath = serverBrowserPath;
    hasSelectedServerFolder = true;
    const label = document.querySelector<HTMLElement>('#picked-server-folder');
    if (label) label.textContent = `/${selectedServerPath}`;
    browser.close();
  });

  const filesDialog = document.querySelector<HTMLDialogElement>('#files-dialog')!;
  document.querySelector('#open-files')?.addEventListener('click', async () => {
    if (!invoke || !state.user) {
      state.error = 'Sign in before browsing server files.';
      render();
      return;
    }
    if (!state.presets.length) {
      state.error = 'This account has no server libraries to browse yet.';
      render();
      return;
    }
    if (state.transfer) return;
    filesBrowserPath = '';
    setFilesFeedback('', '');
    await renderFilesBrowser();
    filesDialog.showModal();
  });
  document.querySelector('#close-files')?.addEventListener('click', () => { if (!state.transfer) filesDialog.close(); });
  document.querySelector('#files-up')?.addEventListener('click', async () => {
    if (state.transfer) return;
    filesBrowserPath = parentPath(filesBrowserPath);
    setFilesFeedback('', '');
    await renderFilesBrowser();
  });
  filesDialog.addEventListener('cancel', (event) => { if (state.transfer) event.preventDefault(); });
  document.querySelector('#files-clear')?.addEventListener('click', () => {
    selectedFiles.clear();
    updateFileActions();
  });
  for (const action of ['share', 'download'] as const) {
    document.querySelector(`#files-${action}`)?.addEventListener('click', () => void runFileAction([...selectedFiles], action));
  }
  const fileList = document.querySelector<HTMLElement>('#files-list')!;
  let holdTimer: number | undefined;
  let heldRow: string | undefined;
  let startX = 0;
  let startY = 0;
  const cancelHold = () => { window.clearTimeout(holdTimer); holdTimer = undefined; };
  fileList.addEventListener('pointerdown', (event) => {
    cancelHold();
    heldRow = undefined;
    if (state.transfer || !event.isPrimary || event.button !== 0) return;
    const target = event.target as HTMLElement;
    if (target.closest('input,[data-share],[data-download]')) return;
    const row = target.closest<HTMLElement>('[data-file-row]');
    if (!row) return;
    startX = event.clientX;
    startY = event.clientY;
    holdTimer = window.setTimeout(() => {
      heldRow = row.dataset.fileRow!;
      toggleFile(heldRow);
    }, 500);
  });
  fileList.addEventListener('pointermove', (event) => {
    if (Math.hypot(event.clientX - startX, event.clientY - startY) > 10) cancelHold();
  });
  for (const event of ['pointerup', 'pointercancel', 'pointerleave', 'scroll']) fileList.addEventListener(event, cancelHold);
  fileList.addEventListener('contextmenu', (event) => { if ((event.target as HTMLElement).closest('[data-file-row]')) event.preventDefault(); });
  fileList.addEventListener('change', (event) => {
    const checkbox = (event.target as HTMLElement).closest<HTMLInputElement>('[data-select]');
    if (checkbox && !state.transfer) toggleFile(checkbox.dataset.select!);
  });
  fileList.addEventListener('click', async (event) => {
    if (state.transfer) return;
    const target = event.target as HTMLElement;
    if (target.closest('[data-select]')) return;
    const row = target.closest<HTMLElement>('[data-file-row]');
    if (!row) return;
    const name = row.dataset.fileRow!;
    if (heldRow === name) { heldRow = undefined; event.preventDefault(); return; }
    const action = target.closest<HTMLElement>('[data-share],[data-download]');
    if (action) { await runFileAction([name], action.dataset.share ? 'share' : 'download'); return; }
    if (selectedFiles.size || !target.closest('[data-open]')) { toggleFile(name); return; }
    filesBrowserPath = joinPath(filesBrowserPath, name);
    setFilesFeedback('', '');
    await renderFilesBrowser();
  });

  document.querySelector('#save-pair')?.addEventListener('click', async () => {
    if (!(await ensureSettingsAuthorized())) return;
    const form = document.querySelector<HTMLFormElement>('#pair-form')!;
    const data = new FormData(form);
    const name = String(data.get('name') ?? '').trim();
    const serverPath = selectedServerPath;
    const direction = String(data.get('direction') ?? 'phone-to-server') as SyncDirection;
    const error = document.querySelector<HTMLElement>('#form-error')!;
    if (!name) {
      error.textContent = 'Enter a name for this folder pair.';
      form.querySelector<HTMLInputElement>('#pair-name')?.focus();
      return;
    }
    if (!selectedFolder) {
      error.textContent = 'Choose a folder on this device first.';
      return;
    }
    if (!hasSelectedServerFolder) {
      error.textContent = 'Choose a server folder first.';
      return;
    }
    if (!state.user) {
      error.textContent = 'Sign in before saving a folder pair.';
      return;
    }
    if (state.pairs.some((pair) => pair.account === state.user && (pair.local.uri === selectedFolder!.uri || ((pair.serverRoot ?? 'files') === selectedServerRoot && pair.serverPath === serverPath)))) {
      error.textContent = 'A saved pair already uses one of these folders.';
      return;
    }
    state.pairs = [...state.pairs, { id: crypto.randomUUID(), name, local: selectedFolder, serverRoot: selectedServerRoot, serverPath, direction, server: state.server, account: state.user, ...currentLimits() }];
    try { await persistPairs(); }
    catch (error) { showError(error); return; }
    selectedFolder = undefined;
    selectedServerPath = '';
    selectedServerRoot = HOME_ROOT;
    hasSelectedServerFolder = false;
    state.notice = 'Folder pair saved.';
    state.error = '';
    dialog.close();
    render();
    void refreshEstimates();
  });

  document.querySelectorAll<HTMLButtonElement>('[data-remove]').forEach((button) => {
    button.addEventListener('click', () => {
      const pair = state.pairs.find((item) => item.id === button.dataset.remove);
      if (!pair) return;
      pendingRemoveId = pair.id;
      const copy = document.querySelector<HTMLElement>('#remove-copy');
      if (copy) copy.textContent = `Remove the “${pair.name}” folder pair? Synced files stay where they are; only its settings are removed.`;
      document.querySelector<HTMLDialogElement>('#remove-dialog')?.showModal();
    });
  });
  document.querySelector('#cancel-remove')?.addEventListener('click', () => {
    pendingRemoveId = undefined;
    document.querySelector<HTMLDialogElement>('#remove-dialog')?.close();
  });
  document.querySelector('#cancel-remove-button')?.addEventListener('click', () => {
    pendingRemoveId = undefined;
    document.querySelector<HTMLDialogElement>('#remove-dialog')?.close();
  });
  document.querySelector('#confirm-remove')?.addEventListener('click', async () => {
    const pair = state.pairs.find((item) => item.id === pendingRemoveId);
    pendingRemoveId = undefined;
    document.querySelector<HTMLDialogElement>('#remove-dialog')?.close();
    if (!pair) return;
    // Removal needs no fresh settings unlock: it only deletes local settings
    // and disables background work. Requiring a sign-in here previously opened
    // the system browser mid-tap, and the blocking window.confirm froze the
    // WebView on Android before anything happened.
    state.removingPairId = pair.id;
    state.error = '';
    render();
    const nextPairs = state.pairs.filter((item) => item.id !== pair.id);
    const previousPairs = state.pairs;
    state.pairs = nextPairs;
    try {
      await persistPairs();
    } catch (error) {
      state.pairs = previousPairs;
      showError(error);
      state.removingPairId = undefined;
      render();
      return;
    }
    if (!state.pairs.some((item) => item.local.uri === pair.local.uri) && invoke) {
      void invoke<void>('forget_local_folder', { folderUri: pair.local.uri }).catch(() => undefined);
    }
    state.removingPairId = undefined;
    state.notice = 'Folder pair removed.';
    delete state.estimates[pair.id];
    delete state.estimatesDone[pair.id];
    render();
  });

  document.querySelectorAll<HTMLButtonElement>('[data-sync]').forEach((button) => {
    button.addEventListener('click', async () => {
      if (!invoke || !state.user) { state.error = 'Sign in before syncing.'; render(); return; }
      const pair = state.pairs.find((item) => item.id === button.dataset.sync);
      if (!pair || syncIsActive() || state.removingPairId) return;
      state.syncingPairId = pair.id;
      state.progress = undefined;
      state.error = '';
      render();
      startProgressPolling();
      try {
        const result = await invoke<{ transferred: number; skipped: number }>('sync_pair', { pair: { ...pair, ...limitsFor(pair) } });
        state.notice = `Sync complete: ${result.transferred} transferred, ${result.skipped} unchanged.`;
        state.error = '';
        state.offline = false;
        await saveSessionBackup();
      } catch (error) { showError(error); }
      state.syncingPairId = undefined;
      state.progress = undefined;
      stopProgressPolling();
      try {
        state.backgroundStatus = readBackgroundStatus(await invoke<string | null>('background_sync_status'));
      } catch { /* Keep the last known status. */ }
      render();
      void refreshEstimates(true);
    });
  });

}

function startProgressPolling(): void {
  stopProgressPolling();
  if (!invoke) return;
  void refreshProgress();
  progressTimer = window.setInterval(() => { void refreshProgress(); }, 1000);
}

function stopProgressPolling(): void {
  if (progressTimer !== undefined) {
    window.clearInterval(progressTimer);
    progressTimer = undefined;
  }
}

async function refreshProgress(): Promise<void> {
  if (!invoke) return;
  let raw: string | null;
  try {
    raw = await invoke<string | null>('sync_progress');
  } catch { return; }
  const next = parseProgress(raw);
  const wasActive = state.progress?.active === true;
  const changed = JSON.stringify(next ?? null) !== JSON.stringify(state.progress ?? null);
  state.progress = next;
  if (!changed) return;
  updateOverview();
  for (const pair of state.pairs) updatePairStatusUi(pair);
  if (wasActive && !next?.active && !state.syncingPairId) void refreshEstimates(true);
}

let estimateRun = 0;
let estimateInFlight: Promise<void> | undefined;
let estimatesFreshUntil = 0;

/// How long a set of numbers stays good enough to keep showing.
///
/// An estimate is no longer a walk of the library, but it is still a request
/// per pair and the app asks for one on sign-in and after every enable, remove,
/// sync and address change. Reusing a recent answer keeps a burst of those from
/// turning into a burst of identical work.
const ESTIMATE_FRESH_MS = 20_000;

type LibrarySize = { bytes: number; files: number; truncated: boolean };

/// Work out how big one premade folder is, and how much room the device has,
/// without setting the pair up.
///
/// Deliberately scoped to the one root that was asked about: the question is
/// about a single folder, so walking every library to answer it would be the
/// same over-computation this change set out to remove.
async function calculatePresetSize(presetId: string): Promise<void> {
  if (!invoke || !state.user || state.sizingPresetId) return;
  const preset = state.presets.find((item) => item.id === presetId);
  if (!preset) return;
  state.sizingPresetId = presetId;
  render();
  try {
    // The device figure has no folder to hang off, so it is fetched on its own
    // rather than as a side effect of some other pair's estimate.
    const [sizes, storage] = await Promise.all([
      invoke<Record<string, LibrarySize>>('server_library_sizes', { root: presetId }),
      invoke<DeviceStorage>('device_storage').catch(() => undefined),
    ]);
    const size = sizes?.[presetId];
    if (size) {
      state.librarySizes[presetId] = {
        bytes: Number(size.bytes) || 0,
        files: Number(size.files) || 0,
        truncated: size.truncated === true,
      };
    }
    if (storage) {
      state.deviceStorage = { freeBytes: Number(storage.freeBytes) || 0, totalBytes: Number(storage.totalBytes) || 0 };
    }
    state.sizedOnDemand[presetId] = true;
    state.error = '';
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error);
  } finally {
    state.sizingPresetId = undefined;
    // In place: a full re-render here would drop the Enable button the user may
    // be about to press, and rebuild the whole list for one number.
    updatePresetSize(preset);
  }
}

async function refreshEstimates(force = false): Promise<void> {
  if (!invoke || !state.user) return;
  if (!force && Date.now() < estimatesFreshUntil && state.estimatesDoneAll) return;
  // A refresh already in flight will produce the same answer. Chaining onto it
  // avoids the old behaviour where a second caller threw away the first run's
  // partial work and started the whole thing again.
  if (estimateInFlight) {
    if (force) await estimateInFlight;
    else return estimateInFlight;
  }
  const run = ++estimateRun;
  const work = (async () => {
    state.estimates = {};
    state.estimatesDone = {};
    state.estimatesDoneAll = false;
    for (const pair of state.pairs) updateSpaceUi(pair.id);
    for (const pair of state.pairs) {
      if (run !== estimateRun) return;
      if (pair.direction === 'two-way') {
        state.estimatesDone[pair.id] = true;
        updateSpaceUi(pair.id);
        continue;
      }
      try {
        const raw = await invoke<SyncEstimate>('estimate_sync_pair', { pair: { ...pair, ...limitsFor(pair) } });
        if (run !== estimateRun) return;
        state.estimates[pair.id] = {
          pendingBytes: Number(raw.pendingBytes) || 0,
          pendingCount: Number(raw.pendingCount) || 0,
          skipped: Number(raw.skipped) || 0,
          direction: typeof raw.direction === 'string' ? raw.direction : pair.direction,
          freeBytes: Number(raw.freeBytes) || 0,
          totalBytes: Number(raw.totalBytes) || 0,
          remoteTotalBytes: Number(raw.remoteTotalBytes) || 0,
        };
        state.deviceStorage = { freeBytes: Number(raw.freeBytes) || 0, totalBytes: Number(raw.totalBytes) || 0 };
      } catch {
        if (run !== estimateRun) return;
        state.estimates[pair.id] = undefined;
      }
      state.estimatesDone[pair.id] = true;
      updateSpaceUi(pair.id);
      // The suggestion row shows the folder total plus what is pending, so it
      // has to be repainted as each pair's number lands. The sizes request and
      // the estimates race, and whichever finishes first must not leave the
      // other one's half of the line on screen.
      for (const preset of state.presets) {
        if (pairForPreset(preset)?.id === pair.id) updatePresetSize(preset);
      }
    }
    if (run !== estimateRun) return;
    state.estimatesDoneAll = true;
    estimatesFreshUntil = Date.now() + ESTIMATE_FRESH_MS;
    updateOverview();
  })();
  const settled = work.finally(() => {
    if (estimateInFlight === settled) estimateInFlight = undefined;
  });
  estimateInFlight = settled;
  await settled;
}

function updatePairStatusUi(pair: SyncPair): void {
  const status = document.querySelector(`[data-pair-status="${CSS.escape(pair.id)}"]`);
  if (status) status.innerHTML = pairStatusBadge(pair);
  const button = document.querySelector<HTMLButtonElement>(`[data-sync="${CSS.escape(pair.id)}"]`);
  if (button) {
    const blocked = spaceStatus(pair, state.estimates[pair.id]) === 'blocked';
    const unavailable = pair.direction === 'two-way' || (pair.server && pair.server !== state.server) || !state.user || pair.account !== state.user;
    button.disabled = syncIsActive() || Boolean(state.removingPairId) || blocked || Boolean(unavailable);
    const label = button.querySelector('span');
    if (label) label.textContent = pairIsSyncing(pair) ? 'Syncing…' : blocked ? 'Not enough space' : pair.direction === 'two-way' ? 'Recreate pair' : pair.server && pair.server !== state.server ? 'Different server' : !state.user ? 'Sign in to sync' : pair.account !== state.user ? 'Different account' : 'Sync now';
  }
}

function updateSpaceUi(pairId: string): void {
  const pair = state.pairs.find((item) => item.id === pairId);
  if (!pair) return;
  const html = spaceLine(pair, state.estimates[pairId]);
  const line = document.querySelector(`[data-space-for="${CSS.escape(pairId)}"]`);
  if (line) {
    if (html) line.outerHTML = html;
    else line.remove();
  } else if (html) {
    const actions = document.querySelector(`[data-pair-id="${CSS.escape(pairId)}"] .pair-actions`);
    actions?.insertAdjacentHTML('beforebegin', html);
  }
  const summary = document.querySelector('#storage-summary');
  if (summary) summary.innerHTML = state.deviceStorage ? `${icon('device')}${escapeHtml(storageSummary())}` : '';
  updatePairStatusUi(pair);
  updateOverview();
}

// A suggestion that is set up reports the folder's size in its own row, so the
// same estimate has to refresh that line too. The line is patched in place for
// the same reason the paired space line is: a full re-render would drop the
// Enable button's focus mid-sync.
function updatePresetSize(preset: SyncPreset): void {
  const pair = pairForPreset(preset);
  const line = document.querySelector(`[data-preset-size-for="${CSS.escape(preset.id)}"]`);
  const html = presetSizeLine(preset, pair);
  // The size arriving is also what retires the Calculate size button and pushes
  // the route down a row, so the row's own class has to follow the line.
  const row = document.querySelector(`[data-preset-row="${CSS.escape(preset.id)}"]`);
  row?.classList.toggle('has-size', Boolean(html));
  if (line) {
    if (html) line.outerHTML = html;
    else line.remove();
  } else if (html) {
    row?.querySelector('.suggest-copy')?.insertAdjacentHTML('afterend', html);
  }
  // The size arriving is also what retires the Calculate size button, so the
  // action cell is repainted from the same source of truth as the line.
  const actions = document.querySelector(`[data-preset-actions="${CSS.escape(preset.id)}"]`);
  const wanted = pair ? '' : presetActions(preset, state.pairs.length > 0);
  if (actions && actions.innerHTML.trim() !== wanted.trim()) actions.outerHTML = wanted;
}

function parseProgress(raw: string | null): SyncProgress | undefined {  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw) as Partial<SyncProgress>;
    if (value?.active !== true) return undefined;
    return {
      active: true,
      pair: typeof value.pair === 'string' ? value.pair : 'Folder pair',
      pairs: Array.isArray(value.pairs) ? value.pairs.filter((item): item is string => typeof item === 'string') : [],
      direction: typeof value.direction === 'string' ? value.direction : '',
      currentFile: typeof value.currentFile === 'string' ? value.currentFile : '',
      transferred: typeof value.transferred === 'number' ? value.transferred : 0,
      skipped: typeof value.skipped === 'number' ? value.skipped : 0,
    };
  } catch {
    return undefined;
  }
}

function setError(error: unknown): void {
  showError(error);
}

function showError(error: unknown): void {
  state.error = error instanceof Error ? error.message : String(error);
  if (state.error.includes('Sign in again to reconnect File Sync')) {
    state.user = undefined;
    state.settingsAuthorized = false;
    state.presets = [];
    state.estimates = {};
    state.estimatesDone = {};
    state.estimatesDoneAll = false;
    state.librarySizes = {};
    state.sizedOnDemand = {};
    state.sizingPresetId = undefined;
    estimatesFreshUntil = 0;
    state.deviceStorage = undefined;
    // The stored session is dead (revoked or rejected): drop the backup and
    // the cached name so the next launch does not resurrect either of them.
    localStorage.removeItem(SESSION_BACKUP_KEY);
    localStorage.removeItem(USER_KEY);
  }
  render();
}

async function saveSessionBackup(): Promise<void> {
  if (!invoke) return;
  try {
    const backup = await invoke<string | null>('session_backup');
    if (backup) localStorage.setItem(SESSION_BACKUP_KEY, backup);
  } catch { /* The session stays available in secure storage only. */ }
}

function cacheSignedInUser(username: string): void {
  state.user = username;
  try { localStorage.setItem(USER_KEY, username); } catch { /* The name is a display hint only. */ }
}

async function hasStoredSession(): Promise<boolean> {
  if (!invoke) return false;
  try {
    return await invoke<boolean>('has_session');
  } catch { return false; }
}

async function restoreSessionBackup(): Promise<boolean> {
  if (!invoke) return false;
  const backup = localStorage.getItem(SESSION_BACKUP_KEY);
  if (!backup) return false;
  try {
    await invoke<void>('restore_session_backup', { backup });
    state.user = await invoke<string | null>('current_user') ?? undefined;
    if (state.user) cacheSignedInUser(state.user);
    return state.user !== undefined;
  } catch { return false; }
}

async function start(): Promise<void> {
  if (invoke) {
    try {
      await onOpenUrl((urls) => { for (const url of urls) void finishCallback(url); });
    } catch { /* The browser preview does not provide native deep links. */ }
    try {
      state.user = await invoke<string | null>('current_user') ?? undefined;
    } catch { state.user = undefined; }
    if (state.user) {
      cacheSignedInUser(state.user);
      // Token refresh may have rotated the session just now; keep the
      // browser backup identical so a later restore never replays a dead
      // refresh token over the live one.
      await saveSessionBackup();
    } else if (await restoreSessionBackup()) {
      state.notice = 'Signed in from the saved session.';
      await saveSessionBackup();
    } else {
      // The server may just be unreachable (offline, VPN, captive portal)
      // while a valid session sits in secure storage. Stay signed in under
      // the cached name instead of bouncing to "Sign in to sync": the next
      // sync attempt revalidates and surfaces the real error if the session
      // is actually dead.
      const cached = localStorage.getItem(USER_KEY);
      if (cached && (await hasStoredSession())) {
        state.user = cached;
        state.offline = true;
        state.notice = 'Could not reach the sync server. Showing the saved sign-in; syncs will retry.';
      }
    }
    try {
      state.backgroundStatus = readBackgroundStatus(await invoke<string | null>('background_sync_status'));
      applySpacePrefsToPairs();
      await persistPairs();
      if (state.user) {
        state.settingsAuthorized = await invoke<boolean>('settings_authorized');
        await loadPresets();
      }
    } catch (error) {
      state.error = error instanceof Error ? error.message : String(error);
    }
    try {
      const initialLinks = await getCurrent();
      for (const url of initialLinks ?? []) void finishCallback(url);
    } catch { /* No pending native deep link. */ }
    // Notification permission is best-effort: sync still works without it.
    void invoke<boolean>('ensure_notifications').catch(() => undefined);
    // Keep the in-app banner fresh for background syncs even when no manual
    // sync is running. refreshProgress reads in-memory progress only.
    window.setInterval(() => { void refreshProgress(); }, 3000);
  }
  render();
  void refreshProgress();
  startupPending = false;
  for (const url of startupCallbacks) void finishCallback(url);
  startupCallbacks.clear();
  void refreshEstimates();
}

async function renderServerBrowser(): Promise<void> {
  const location = document.querySelector<HTMLElement>('#server-browser-location');
  const list = document.querySelector<HTMLElement>('#server-browser-list');
  if (location) location.textContent = `/${serverBrowserPath}`;
  if (!list || !invoke) return;
  list.textContent = 'Loading folders…';
  try {
    const entries = await invoke<ServerEntry[]>('server_tree', { path: serverBrowserPath, root: selectedServerRoot });
    const directories = directoriesOnly(entries);
    list.innerHTML = directories.length
      ? directories.map((entry) => `<button class="browser-entry" type="button" data-enter="${escapeHtml(entry.name)}"><span class="browser-entry-icon" aria-hidden="true">${icon('folder')}</span><span>${escapeHtml(entry.name)}</span>${icon('arrowRight')}</button>`).join('')
      : '<p class="browser-empty">No folders here. You can use this folder as the pair destination.</p>';
    list.querySelectorAll<HTMLButtonElement>('[data-enter]').forEach((button) => button.addEventListener('click', async () => {
      const name = button.dataset.enter!;
      serverBrowserPath = serverBrowserPath ? `${serverBrowserPath}/${name}` : name;
      await renderServerBrowser();
    }));
  } catch (error) { list.textContent = error instanceof Error ? error.message : String(error); }
  const up = document.querySelector<HTMLButtonElement>('#server-browser-up');
  if (up) up.disabled = !serverBrowserPath;
}

function filesLocation(): string {
  return `/${filesBrowserPath}`;
}

async function renderFilesBrowser(): Promise<void> {
  const load = ++filesLoad;
  selectedFiles.clear();
  filesEntries = [];
  const location = document.querySelector<HTMLElement>('#files-location');
  const list = document.querySelector<HTMLElement>('#files-list');
  if (location) location.textContent = filesLocation();
  updateFileActions();
  if (!list || !invoke) return;
  list.textContent = 'Loading files…';
  try {
    const entries = await invoke<ServerEntry[]>('server_tree', { path: filesBrowserPath, root: HOME_ROOT });
    if (load !== filesLoad) return;
    filesEntries = browseOrder(entries);
    list.innerHTML = filesEntries.length
      ? `<ul class="file-list">${filesEntries.map(filesRow).join('')}</ul>`
      : '<p class="browser-empty">This folder is empty.</p>';
  } catch (error) {
    if (load !== filesLoad) return;
    list.innerHTML = `<p class="browser-empty">${escapeHtml(error instanceof Error ? error.message : String(error))}</p>`;
  }
}

function filesRow(entry: ServerEntry): string {
  const name = escapeHtml(entry.name);
  const directory = entry.kind === 'directory';
  const meta = escapeHtml(entryMeta(entry));
  const action = (kind: FileAction) => `<button class="text-button" type="button" data-${kind}="${name}" aria-label="${kind === 'share' ? 'Share' : 'Download'} ${name}">${icon(kind)}<span>${fileActionLabel(kind, false)}</span></button>`;
  return `<li class="file-row" data-file-row="${name}">
    <input class="file-select" type="checkbox" data-select="${name}" aria-label="Select ${name}" />
    <button class="file-entry" type="button" ${directory ? `data-open="${name}"` : ''} aria-label="${directory ? 'Open' : 'Select'} ${name}"><span class="file-icon" aria-hidden="true">${icon(directory ? 'folder' : 'file')}</span><span class="file-details"><span class="file-name">${name}</span>${meta ? `<span class="file-meta">${meta}</span>` : ''}</span>${directory ? icon('arrowRight') : ''}</button>
    ${directory ? '' : `<div class="file-actions">${action('share')}${action('download')}</div>`}
  </li>`;
}

function toggleFile(name: string): void {
  if (selectedFiles.has(name)) selectedFiles.delete(name);
  else selectedFiles.add(name);
  updateFileActions();
}

function setFilesFeedback(status: string, error: string): void {
  const statusLine = document.querySelector<HTMLElement>('#files-status');
  const errorLine = document.querySelector<HTMLElement>('#files-error');
  if (statusLine) statusLine.textContent = status;
  if (errorLine) errorLine.textContent = error;
}

// Patch rows in place to preserve scroll, focus and the active long press.
function updateFileActions(): void {
  const busy = Boolean(state.transfer);
  const selection = document.querySelector<HTMLElement>('#files-selection');
  if (selection) selection.hidden = selectedFiles.size === 0;
  const count = document.querySelector('#files-selected-count');
  if (count) count.textContent = `${selectedFiles.size} selected`;
  const list = document.querySelector('#files-list');
  list?.classList.toggle('has-selection', selectedFiles.size > 0);
  document.querySelectorAll<HTMLInputElement>('#files-list [data-select]').forEach((checkbox) => {
    checkbox.checked = selectedFiles.has(checkbox.dataset.select!);
    checkbox.disabled = busy;
    checkbox.closest('.file-row')?.classList.toggle('is-selected', checkbox.checked);
  });
  document.querySelectorAll<HTMLButtonElement>('#files-list button,#files-selection button,#close-files').forEach((button) => { button.disabled = busy; });
  document.querySelectorAll<HTMLButtonElement>('#files-list [data-share],#files-list [data-download],#files-share,#files-download').forEach((button) => {
    const kind: FileAction = button.dataset.share || button.id === 'files-share' ? 'share' : 'download';
    const isTarget = state.transfer?.path ? (button.dataset.share ?? button.dataset.download) === state.transfer.path : button.id === `files-${kind}`;
    const label = button.querySelector('span');
    if (label) label.textContent = fileActionLabel(kind, busy && isTarget && state.transfer?.action === kind);
  });
  const up = document.querySelector<HTMLButtonElement>('#files-up');
  if (up) up.disabled = !filesBrowserPath || busy;
}

async function runFileAction(names: string[], action: FileAction): Promise<void> {
  if (!invoke || !state.user || state.transfer || !names.length) return;
  const entries = filesEntries.filter((entry) => names.includes(entry.name));
  if (!entries.length) return;
  state.transfer = { path: selectedFiles.size ? undefined : entries[0]?.name, action };
  setFilesFeedback(action === 'share' ? 'Preparing to share…' : 'Choose a folder to save these files.', '');
  updateFileActions();
  try {
    const destination = action === 'download' ? await invoke<Folder | null>('plugin:mobile-files|pick_local_folder') : undefined;
    if (action === 'download' && !destination) { setFilesFeedback('Download cancelled.', ''); return; }
    setFilesFeedback(action === 'share' ? 'Preparing to share…' : 'Downloading…', '');
    const result = await invoke<{ name: string; stored: boolean; count: number }>('server_files_action', {
      path: filesBrowserPath,
      root: HOME_ROOT,
      names: entries.map((entry) => entry.name),
      action,
      destination: destination?.uri,
    });
    setFilesFeedback(result.stored ? `Saved ${result.count} ${result.count === 1 ? 'file' : 'files'} to ${destination!.displayName}.` : `Sharing ${result.name}…`, '');
  } catch (error) {
    setFilesFeedback('', error instanceof Error ? error.message : String(error));
  } finally {
    state.transfer = undefined;
    updateFileActions();
  }
}

let lastAuthCallback: string | undefined;
let startupPending = true;
const startupCallbacks = new Set<string>();

async function finishCallback(url: string): Promise<void> {
  if (!url.startsWith('filesync://oauth/callback') || !invoke) return;
  // Restore the old session before accepting a new one. Otherwise a slow
  // startup request can overwrite the account/status from a successful return.
  if (startupPending) {
    startupCallbacks.add(url);
    return;
  }
  // Android can deliver the same intent through both onOpenUrl and getCurrent
  // during startup. An authorization code must only be exchanged once.
  if (lastAuthCallback === url) return;
  lastAuthCallback = url;
  state.notice = '';
  state.error = '';
  render();
  try {
    state.user = await invoke<string>('finish_login', { callbackUrl: url });
  } catch (error) {
    setError(error);
    return;
  }

  state.offline = false;
  cacheSignedInUser(state.user);
  state.notice = `Signed in as ${state.user}.`;
  render();
  await saveSessionBackup();
  try {
    state.settingsAuthorized = await invoke<boolean>('settings_authorized');
  } catch (error) {
    state.notice = '';
    setError(error);
  }
  try {
    await loadPresets();
  } catch (error) {
    state.offline = true;
    state.notice = '';
    state.error = `Your sign-in is saved. Could not load your folders. ${error instanceof Error ? error.message : String(error)}`;
    render();
    return;
  }
  try {
    applySpacePrefsToPairs();
    await persistPairs();
  } catch (error) {
    state.notice = '';
    setError(error);
  }
  render();
  void refreshEstimates();
}

async function obtainPresetFolder(preset: SyncPreset): Promise<Folder | null> {
  if (!invoke) return null;
  try {
    if (await invoke<boolean>('ensure_all_files_access')) {
      return await invoke<Folder>('create_local_folder', { subpath: preset.localSubpath });
    }
  } catch (error) {
    showError(error);
    return null;
  }
  return new Promise((resolve) => {
    const dialog = document.querySelector<HTMLDialogElement>('#permission-dialog')!;
    const status = document.querySelector<HTMLElement>('#permission-status')!;
    const openSettings = document.querySelector<HTMLButtonElement>('#open-all-files-settings')!;
    const chooseManual = document.querySelector<HTMLButtonElement>('#choose-folder-manually')!;
    const cancel = document.querySelector<HTMLButtonElement>('#cancel-permission-request')!;
    status.textContent = `File Sync can create the ${preset.localSubpath} folder on this device automatically with All files access. Without it, you can still choose a folder manually.`;
    dialog.showModal();
    const done = (value: Folder | null) => { dialog.close(); resolve(value); };
    openSettings.onclick = async () => {
      try {
        if (await invoke<boolean>('request_all_files_access')) {
          done(await invoke<Folder>('create_local_folder', { subpath: preset.localSubpath }));
        } else {
          done(await invoke<Folder | null>('pick_local_folder'));
        }
      } catch (error) { showError(error); done(null); }
    };
    chooseManual.onclick = () => { void invoke<Folder | null>('pick_local_folder').then(done); };
    cancel.onclick = () => done(null);
  });
}

async function ensureSettingsAuthorized(): Promise<boolean> {
  if (!invoke || !state.user) {
    state.error = 'Sign in before changing sync settings.';
    render();
    return false;
  }
  try {
    state.settingsAuthorized = await invoke<boolean>('settings_authorized');
    if (state.settingsAuthorized) return true;
    await beginInteractiveLogin();
  } catch (error) {
    setError(error);
  }
  return false;
}

async function beginInteractiveLogin(): Promise<void> {
  if (!invoke) return;
  const server = state.server.trim();
  if (!server) throw new Error('Open Settings to add a sync server address before signing in.');
  const authorizationUrl = await invoke<string>('begin_login', { serverUrl: server });
  state.notice = 'Complete sign-in in your browser, then return to File Sync. Saved syncs remain available.';
  state.error = '';
  render();
  try {
    // With no inAppBrowser option, Tauri opens OAuth in the system browser.
    await openUrl(authorizationUrl);
  } catch (error) {
    state.notice = '';
    throw error;
  }
}

function normalizeServerAddress(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) return '';
  let url: URL;
  try { url = new URL(trimmed); }
  catch { throw new Error('Enter a complete HTTPS server address, such as https://filesync-api.example.org.'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
    throw new Error('Use an HTTPS server address without a path, query, or login details.');
  }
  return url.origin;
}

async function loadPresets(): Promise<void> {
  if (!invoke) return;
  state.presets = await invoke<SyncPreset[]>('server_presets');
}

async function persistPairs(): Promise<void> {
  const serialized = JSON.stringify(state.pairs);
  try {
    if (invoke) await invoke<void>('update_background_syncs', { pairs: state.pairs });
    localStorage.setItem(STORAGE_KEY, serialized);
  } catch (error) {
    state.pairs = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]') as SyncPair[];
    state.error = error instanceof Error ? error.message : String(error);
    throw error;
  }
}

function readBackgroundStatus(raw: string | null): string | undefined {
  if (!raw) return undefined;
  try {
    const value = JSON.parse(raw) as { message?: unknown };
    return typeof value.message === 'string' ? value.message : undefined;
  } catch {
    return undefined;
  }
}

// Show the connection screen before native session and background status calls.
// A slow or unavailable native plugin must not leave the first launch blank.
render();
void start();
