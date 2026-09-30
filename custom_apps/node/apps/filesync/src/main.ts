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
type FileTransfer = { path: string; action: FileAction };

const invoke = (window as TauriWindow).__TAURI__?.core?.invoke;
const STORAGE_KEY = 'nixhomeserver.filesync.pairs.v1';
const SETTINGS_KEY = 'nixhomeserver.filesync.server.v1';
const SESSION_BACKUP_KEY = 'nixhomeserver.filesync.session-backup.v1';
const USER_KEY = 'nixhomeserver.filesync.user.v1';
const SPACE_PREFS_KEY = 'nixhomeserver.filesync.space-limits.v1';
const DEFAULT_SERVER = import.meta.env.VITE_FILESYNC_DEFAULT_SERVER ?? '';
const app = document.querySelector<HTMLDivElement>('#app')!;

const state: { pairs: SyncPair[]; presets: SyncPreset[]; syncingPairId?: string; removingPairId?: string; progress?: SyncProgress; server: string; user?: string; offline: boolean; settingsAuthorized: boolean; backgroundStatus?: string; error: string; notice: string; estimates: Record<string, SyncEstimate | undefined>; estimatesDone: Record<string, boolean>; deviceStorage?: DeviceStorage; warnPercent: number; blockPercent: number; transfer?: FileTransfer } = {
  pairs: readPairs(),
  presets: [],
  server: localStorage.getItem(SETTINGS_KEY) ?? DEFAULT_SERVER,
  settingsAuthorized: false,
  offline: false,
  error: '',
  notice: '',
  estimates: {},
  estimatesDone: {},
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

function directionText(direction: SyncDirection): string {
  if (direction === 'phone-to-server') return 'Files move from this device to the server';
  if (direction === 'server-to-phone') return 'Files move from the server to this device';
  return 'Files move both ways';
}

function spaceLine(pair: SyncPair, estimate?: SyncEstimate): string {
  if (pair.direction === 'two-way' || !state.user) return '';
  const id = escapeHtml(pair.id);
  if (!estimate) {
    return state.estimatesDone[pair.id]
      ? ''
      : `<p class="pair-space" data-space-for="${id}">Checking size…</p>`;
  }
  if (estimate.pendingBytes <= 0) return `<p class="pair-space" data-space-for="${id}">Already in sync</p>`;
  const status = spaceStatus(pair, estimate);
  if (pair.direction !== 'server-to-phone') {
    return `<p class="pair-space" data-space-for="${id}">≈ ${escapeHtml(formatBytes(estimate.pendingBytes))} to upload</p>`;
  }
  // The blocked case leaves the reason to the disabled Sync button, which
  // already reads "Not enough space"; repeating it here said the same words
  // twice within one row. The warn case keeps its prefix because weight alone
  // is too weak a cue for it.
  const text = status === 'blocked'
    ? `${formatBytes(estimate.pendingBytes)} needed · ${formatBytes(estimate.freeBytes)} free`
    : status === 'warn'
      ? `Low space: ≈ ${formatBytes(estimate.pendingBytes)} to download · ${formatBytes(estimate.freeBytes)} free`
      : `≈ ${formatBytes(estimate.pendingBytes)} to download · ${formatBytes(estimate.freeBytes)} free`;
  const tone = status === 'blocked' ? ' space-blocked' : status === 'warn' ? ' space-warn' : '';
  return `<p class="pair-space${tone}" data-space-for="${id}">${escapeHtml(text)}</p>`;
}

function storageSummary(): string {
  if (!state.deviceStorage || !state.user) return '';
  return ` · ${formatBytes(state.deviceStorage.freeBytes)} free of ${formatBytes(state.deviceStorage.totalBytes)} on this device`;
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
function presetSizeLine(preset: SyncPreset, pair?: SyncPair): string {
  const id = escapeHtml(preset.id);
  if (!pair) return '';
  const estimate = state.estimates[pair.id];
  if (!estimate) {
    return state.estimatesDone[pair.id]
      ? ''
      : `<p class="suggest-size" data-preset-size-for="${id}">Checking size…</p>`;
  }
  const total = Number(estimate.remoteTotalBytes) || 0;
  if (total <= 0) return `<p class="suggest-size" data-preset-size-for="${id}">Server folder is empty</p>`;
  const pending = estimate.pendingBytes;
  const verb = preset.direction === 'phone-to-server' ? 'to upload' : 'to download';
  const text = pending > 0
    ? `${formatBytes(total)} on the server · ${formatBytes(pending)} ${verb}`
    : `${formatBytes(total)} on the server`;
  return `<p class="suggest-size" data-preset-size-for="${id}">${escapeHtml(text)}</p>`;
}

function progressCopy(progress?: SyncProgress, syncingPairId?: string): string {
  if (progress?.active) {
    const names = progress.pairs.length > 1 ? `${progress.pairs.length} folders` : progress.pair;
    const arrow = progress.direction === 'server-to-phone' ? '↓' : '↑';
    const file = progress.currentFile ? ` ${arrow} ${escapeHtml(progress.currentFile)}` : ' preparing…';
    return `<p class="progress-title">Syncing ${escapeHtml(names)}…${file}</p><p class="progress-counts">${progress.transferred} copied · ${progress.skipped} unchanged</p>`;
  }
  if (syncingPairId) return '<p class="progress-title">Syncing…</p>';
  return '';
}

const SERVICE_LOGOS: Record<string, string> = {
  files: '/logos/filestash.svg',
  'offline-media': '/logos/syncthing.svg',
  jellyfin: '/logos/jellyfin.svg',
  audiobookshelf: '/logos/audiobookshelf.svg',
  kavita: '/logos/kavita.svg',
};

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
  return `<span class="route-line"><span class="route-place">${escapeHtml(route.sourceLabel)}</span> <strong>${escapeHtml(route.sourceValue)}</strong> <span class="route-arrow" aria-hidden="true">${route.arrow}</span> <span class="route-place">${escapeHtml(route.targetLabel)}</span> <strong>${escapeHtml(route.targetValue)}</strong></span>`;
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

function render(): void {
  // Most people set up the folders the server already suggests, so the
  // suggested list is the page's primary content until something is paired.
  // A suggestion that is already set up stays in the list and reports its
  // size instead of offering a second Enable, so the list doubles as the
  // answer to "how big is each of my folders?".
  const hasPairs = state.pairs.length > 0;
  const suggestSection = state.user ? `
    <section class="suggest-section" ${state.presets.length ? 'aria-labelledby="suggest-heading"' : ''}>
      ${state.presets.length ? `
        <h2 id="suggest-heading">Suggested folders</h2>
        <ul class="suggest-list">${state.presets.map((preset) => {
          const pair = pairForPreset(preset);
          const size = presetSizeLine(preset, pair);
          return `<li class="suggest-row${pair ? ' is-set-up' : ''}" data-preset-row="${escapeHtml(preset.id)}">
            <span class="service-logo" aria-hidden="true">${serviceMark(preset.service, preset.serviceTitle)}</span>
            <div class="suggest-copy">
              <h3>${escapeHtml(preset.serviceTitle)}</h3>
              <p>${escapeHtml(preset.title)}</p>
            </div>
            ${pair ? size : `<button class="${hasPairs ? 'secondary-button' : 'primary-button'}" type="button" data-enable-preset="${escapeHtml(preset.id)}" ${state.syncingPairId ? 'disabled' : ''}>Enable</button>`}
            ${routeLine(preset.direction, `/${preset.localSubpath}`, presetServerLocation(preset))}
          </li>`;
        }).join('')}</ul>
      ` : '<p class="services-empty">No suggested folders are available for this account yet.</p>'}
      <div class="section-actions">
        <button class="text-button" type="button" id="open-files">Browse server files</button>
        <button class="text-button" type="button" id="open-pair-form">Pair your own folders</button>
      </div>
    </section>` : '';
  const pairRows = state.pairs.map((pair) => {
    const route = routeFor(pair.direction, localLocation(pair), serverLocation(pair));
    const estimate = state.estimates[pair.id];
    const blocked = spaceStatus(pair, estimate) === 'blocked';
    const busy = Boolean(state.syncingPairId || state.removingPairId);
    const unavailable = pair.direction === 'two-way' || (pair.server && pair.server !== state.server) || !state.user || pair.account !== state.user;
    const syncLabel = state.syncingPairId === pair.id ? 'Syncing…' : blocked ? 'Not enough space' : pair.direction === 'two-way' ? 'Recreate pair' : pair.server && pair.server !== state.server ? 'Different server' : !state.user ? 'Sign in to sync' : pair.account !== state.user ? 'Different account' : 'Sync now';
    return `
    <li class="pair-row" data-pair-id="${escapeHtml(pair.id)}">
      <h3 class="pair-name">${escapeHtml(pair.name)}</h3>
      <div class="pair-route">
        <div class="route-endpoint">
          <span class="route-role">From <span class="route-place">${escapeHtml(route.sourceLabel)}</span></span>
          <strong class="route-path">${escapeHtml(route.sourceValue)}</strong>
        </div>
        <span class="route-arrow" aria-label="${escapeHtml(directionText(pair.direction))}">${route.arrow}</span>
        <div class="route-endpoint">
          <span class="route-role">To <span class="route-place">${escapeHtml(route.targetLabel)}</span></span>
          <strong class="route-path">${escapeHtml(route.targetValue)}</strong>
        </div>
      </div>
      ${spaceLine(pair, estimate)}
      <div class="pair-actions">
        <button class="text-button" type="button" data-sync="${escapeHtml(pair.id)}" ${busy || blocked || unavailable ? 'disabled' : ''}>${syncLabel}</button>
        <button class="text-button danger-text" type="button" data-remove="${escapeHtml(pair.id)}" aria-label="Remove ${escapeHtml(pair.name)}" ${state.syncingPairId || state.removingPairId ? 'disabled' : ''}>${state.removingPairId === pair.id ? 'Removing…' : 'Remove'}</button>
      </div>
    </li>
  `;
  }).join('');

  app.innerHTML = `
    <main class="shell">
      <header class="topbar">
        <a class="brand" href="#" aria-label="File Sync home"><span class="brand-mark" aria-hidden="true">FS</span><span>File Sync</span></a>
        <button class="text-button settings-button" type="button" id="open-settings" aria-haspopup="dialog">Settings</button>
      </header>

      <section class="sync-progress" id="sync-progress" aria-live="polite" ${state.progress?.active || state.syncingPairId ? '' : 'hidden'}>
        ${progressCopy(state)}
      </section>

      <h1 class="page-title">${hasPairs ? 'Folder pairs' : 'Set up your folders'}</h1>
      ${!hasPairs && state.user ? '<p class="page-lead">Pick a folder below. File Sync copies it to this device and keeps it up to date.</p>' : ''}

      ${hasPairs ? `
        <section class="pairs-section">
          <ul class="pair-list">${pairRows}</ul>
        </section>
      ` : ''}

      ${suggestSection}

      <div class="toast" role="status" aria-live="polite" ${state.notice ? '' : 'hidden'}>${escapeHtml(state.notice)}</div>
      <div class="toast error-toast" role="alert" ${state.error ? '' : 'hidden'}>${escapeHtml(state.error)}</div>
    </main>

    <dialog id="pair-dialog" class="pair-dialog">
      <form method="dialog" id="pair-form">
        <div class="dialog-heading"><h2>Add a folder pair</h2><button class="close-button" value="cancel" aria-label="Close dialog">×</button></div>
        <label for="pair-name">Pair name</label>
        <input id="pair-name" name="name" required maxlength="64" placeholder="For example, Field notes" />
        <label for="pick-folder">Folder on this device</label>
        <div class="picker-row"><span id="picked-folder">No folder selected</span><button class="secondary-button" id="pick-folder" type="button">Choose folder</button></div>
        <label for="browse-server">Folder on server</label>
        <div class="picker-row"><span id="picked-server-folder">No server folder selected</span><button class="secondary-button" id="browse-server" type="button">Browse server</button></div>
        <fieldset>
          <legend>Sync direction</legend>
          <label class="direction-choice"><input type="radio" name="direction" value="phone-to-server" checked /><span>This device <b>→</b> Server</span></label>
          <label class="direction-choice"><input type="radio" name="direction" value="server-to-phone" /><span>Server <b>→</b> This device</span></label>
        </fieldset>
        <p class="form-error" id="form-error" role="alert"></p>
        <div class="dialog-actions"><button class="secondary-button" value="cancel">Cancel</button><button class="primary-button" id="save-pair" type="button">Save pair</button></div>
      </form>
    </dialog>

    <dialog id="server-browser" class="pair-dialog server-browser">
      <div class="dialog-heading"><h2>Choose a server folder</h2><button class="close-button" type="button" id="close-server-browser" aria-label="Close dialog">×</button></div>
      <p class="browser-location" id="server-browser-location">/</p>
      <div class="browser-list" id="server-browser-list"></div>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="server-browser-up">Up one level</button><button class="primary-button" type="button" id="choose-server-folder">Use this folder</button></div>
    </dialog>

    <dialog id="files-dialog" class="pair-dialog files-dialog" aria-labelledby="files-heading">
      <div class="dialog-heading"><h2 id="files-heading">Server files</h2><button class="close-button" type="button" id="close-files" aria-label="Close files">×</button></div>
      <p class="browser-location" id="files-location">/</p>
      <div class="browser-list" id="files-list"></div>
      <p class="form-error" id="files-error" role="alert"></p>
      <p class="files-status" id="files-status" role="status" aria-live="polite"></p>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="files-up">Up one level</button></div>
    </dialog>

    <dialog id="permission-dialog" class="pair-dialog" aria-labelledby="permission-heading">
      <div class="dialog-heading"><h2 id="permission-heading">All files access</h2><button class="close-button" type="button" id="cancel-permission-request" aria-label="Close dialog">×</button></div>
      <p id="permission-status"></p>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="choose-folder-manually">Choose folder manually</button><button class="primary-button" type="button" id="open-all-files-settings">Open settings</button></div>
    </dialog>

    <dialog id="settings-dialog" class="pair-dialog settings-dialog" aria-labelledby="settings-heading">
      <div class="dialog-heading"><h2 id="settings-heading">Settings</h2><button class="close-button" value="cancel" aria-label="Close settings">×</button></div>
      <div class="settings-account">
        <p class="account-user">${state.user
          ? `Signed in as <strong>${escapeHtml(state.user)}</strong>${state.offline ? ' · offline, will retry' : ''}${state.backgroundStatus ? ` · ${escapeHtml(state.backgroundStatus)}` : ''}<span id="storage-summary">${escapeHtml(storageSummary())}</span>`
          : 'Sign in to sync your folders.'}</p>
        <div class="settings-account-actions">
          ${state.user
            ? `${state.settingsAuthorized ? '' : '<button class="secondary-button" type="button" id="unlock-settings">Unlock settings</button>'}<button class="secondary-button" type="button" id="sign-out">Sign out</button>`
            : '<button class="primary-button" type="button" id="sign-in">Sign in</button>'}
        </div>
      </div>
      <form method="dialog" id="settings-form">
        <label for="server-address">Server address</label>
        <input id="server-address" type="url" value="${escapeHtml(state.server)}" autocomplete="url" autocapitalize="none" spellcheck="false" />
        <fieldset>
          <legend>Sync storage limits</legend>
          <p class="settings-hint">Downloads always keep 15% of device storage free.</p>
          <label for="warn-limit">Warn when a sync would use more than this share of free space (%)</label>
          <input id="warn-limit" type="number" min="1" max="100" value="${state.warnPercent}" />
          <label for="block-limit">Stop a sync above this share of free space (%)</label>
          <input id="block-limit" type="number" min="1" max="100" value="${state.blockPercent}" />
        </fieldset>
        <p class="form-error" id="settings-error" role="alert"></p>
        <div class="dialog-actions"><button class="secondary-button" value="cancel">Cancel</button><button class="primary-button" id="save-server" type="button">Save address</button></div>
      </form>
    </dialog>

    <dialog id="remove-dialog" class="pair-dialog settings-dialog" aria-labelledby="remove-heading">
      <div class="dialog-heading"><h2 id="remove-heading">Remove folder pair</h2><button class="close-button" type="button" id="cancel-remove" aria-label="Close dialog">×</button></div>
      <p id="remove-copy"></p>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="cancel-remove-button">Cancel</button><button class="primary-button" type="button" id="confirm-remove">Remove pair</button></div>
    </dialog>
  `;

  bindEvents();
}

let selectedFolder: Folder | undefined;
let selectedServerPath = '';
let selectedServerRoot = HOME_ROOT;
let hasSelectedServerFolder = false;
let serverBrowserPath = '';
let filesBrowserPath = '';
let pendingRemoveId: string | undefined;
let progressTimer: number | undefined;

function bindEvents(): void {
  const dialog = document.querySelector<HTMLDialogElement>('#pair-dialog')!;
  const browser = document.querySelector<HTMLDialogElement>('#server-browser')!;
  const settingsDialog = document.querySelector<HTMLDialogElement>('#settings-dialog')!;
  document.querySelector('#open-settings')?.addEventListener('click', () => settingsDialog.showModal());
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
    void refreshEstimates();
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
    if (state.user && nextServer !== state.server && invoke) {
      try { await invoke<void>('logout'); localStorage.removeItem(SESSION_BACKUP_KEY); localStorage.removeItem(USER_KEY); state.user = undefined; state.offline = false; state.settingsAuthorized = false; }
      catch (error) { setError(error); return; }
    }
    state.server = nextServer;
    state.presets = [];
    localStorage.setItem(SETTINGS_KEY, state.server);
    state.notice = state.server ? 'Server address saved on this device.' : 'Server address cleared.';
    state.error = '';
    try { await persistPairs(); } catch { /* The notice already explains the save; pairs retry on next change. */ }
    render();
    void refreshEstimates();
  });

  document.querySelector('#sign-in')?.addEventListener('click', async () => {
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
  });

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
    filesBrowserPath = '';
    state.transfer = undefined;
    setFilesFeedback('', '');
    await renderFilesBrowser();
    filesDialog.showModal();
  });
  document.querySelector('#close-files')?.addEventListener('click', () => filesDialog.close());
  document.querySelector('#files-up')?.addEventListener('click', async () => {
    filesBrowserPath = parentPath(filesBrowserPath);
    state.transfer = undefined;
    setFilesFeedback('', '');
    await renderFilesBrowser();
  });
  filesDialog.addEventListener('close', () => { state.transfer = undefined; });
  // The list is re-rendered on every navigation, so one delegated listener on
  // the container covers folders and both file actions.
  document.querySelector<HTMLElement>('#files-list')?.addEventListener('click', async (event) => {
    const target = (event.target as HTMLElement).closest<HTMLElement>('[data-open],[data-share],[data-download]');
    if (!target) return;
    const name = target.dataset.open ?? target.dataset.share ?? target.dataset.download;
    if (!name) return;
    if (target.dataset.open) {
      filesBrowserPath = joinPath(filesBrowserPath, name);
      state.transfer = undefined;
      setFilesFeedback('', '');
      await renderFilesBrowser();
      return;
    }
    const action = target.dataset.share ? 'share' : 'download';
    await runFileAction(name, action as FileAction, Number(target.dataset.size ?? 0));
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
      if (!pair) return;
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
      void refreshEstimates();
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
  const changed = JSON.stringify(next ?? null) !== JSON.stringify(state.progress ?? null);
  state.progress = next;
  if (!changed) return;
  const banner = document.querySelector<HTMLElement>('#sync-progress');
  if (!banner) return;
  if (next?.active || state.syncingPairId) {
    banner.hidden = false;
    banner.innerHTML = progressCopy(next, state.syncingPairId);
  } else {
    banner.hidden = true;
    banner.innerHTML = '';
  }
}

let estimateRun = 0;

async function refreshEstimates(): Promise<void> {
  if (!invoke || !state.user) return;
  const run = ++estimateRun;
  state.estimates = {};
  state.estimatesDone = {};
  for (const pair of state.pairs) updateSpaceUi(pair.id);
  for (const preset of state.presets) updatePresetSize(preset);
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
    for (const preset of state.presets) {
      if (pairForPreset(preset)?.id === pair.id) updatePresetSize(preset);
    }
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
  const button = document.querySelector<HTMLButtonElement>(`[data-sync="${CSS.escape(pairId)}"]`);
  if (button && !state.syncingPairId && !state.removingPairId) {
    const blocked = spaceStatus(pair, state.estimates[pairId]) === 'blocked';
    const unavailable = pair.direction === 'two-way' || (pair.server && pair.server !== state.server) || !state.user || pair.account !== state.user;
    button.disabled = blocked || unavailable;
    if (!unavailable && state.syncingPairId !== pairId) {
      button.textContent = blocked ? 'Not enough space' : 'Sync now';
    }
  }
  const summary = document.querySelector('#storage-summary');
  if (summary) summary.textContent = storageSummary();
}

// A suggestion that is set up reports the folder's size in its own row, so the
// same estimate has to refresh that line too. The line is patched in place for
// the same reason the paired space line is: a full re-render would drop the
// Enable button's focus mid-sync.
function updatePresetSize(preset: SyncPreset): void {
  const line = document.querySelector(`[data-preset-size-for="${CSS.escape(preset.id)}"]`);
  const html = presetSizeLine(preset, pairForPreset(preset));
  if (line) {
    if (html) line.outerHTML = html;
    else line.remove();
    return;
  }
  if (!html) return;
  const row = document.querySelector(`[data-preset-row="${CSS.escape(preset.id)}"]`);
  row?.querySelector('.suggest-copy')?.insertAdjacentHTML('afterend', html);
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
      ? directories.map((entry) => `<button class="browser-entry" type="button" data-enter="${escapeHtml(entry.name)}"><span aria-hidden="true">▰</span>${escapeHtml(entry.name)}</button>`).join('')
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
  const location = document.querySelector<HTMLElement>('#files-location');
  const list = document.querySelector<HTMLElement>('#files-list');
  if (location) location.textContent = filesLocation();
  const up = document.querySelector<HTMLButtonElement>('#files-up');
  if (up) up.disabled = !filesBrowserPath || Boolean(state.transfer);
  if (!list || !invoke) return;
  list.textContent = 'Loading files…';
  let entries: ServerEntry[];
  try {
    entries = await invoke<ServerEntry[]>('server_tree', { path: filesBrowserPath, root: HOME_ROOT });
  } catch (error) {
    list.innerHTML = `<p class="browser-empty">${escapeHtml(error instanceof Error ? error.message : String(error))}</p>`;
    return;
  }
  const ordered = browseOrder(entries);
  if (!ordered.length) {
    list.innerHTML = '<p class="browser-empty">This folder is empty.</p>';
    return;
  }
  list.innerHTML = `<ul class="file-list">${ordered.map((entry) => filesRow(entry)).join('')}</ul>`;
}

function filesRow(entry: ServerEntry): string {
  const name = escapeHtml(entry.name);
  const busy = state.transfer?.path === entry.name;
  if (entry.kind === 'directory') {
    return `<li class="file-row"><button class="file-entry" type="button" data-open="${name}" ${state.transfer ? 'disabled' : ''}><span class="file-icon" aria-hidden="true">▰</span><span class="file-name">${name}</span></button></li>`;
  }
  const meta = escapeHtml(entryMeta(entry));
  const size = Number.isFinite(entry.size) && entry.size > 0 ? entry.size : 0;
  const action = (kind: FileAction) => `<button class="text-button" type="button" data-${kind}="${name}" data-size="${size}" ${state.transfer ? 'disabled' : ''}>${fileActionLabel(kind, busy && state.transfer?.action === kind)}</button>`;
  return `<li class="file-row"><div class="file-copy"><span class="file-name">${name}</span>${meta ? `<span class="file-meta">${meta}</span>` : ''}</div><div class="file-actions">${action('share')}${action('download')}</div></li>`;
}

function setFilesFeedback(status: string, error: string): void {
  const statusLine = document.querySelector<HTMLElement>('#files-status');
  const errorLine = document.querySelector<HTMLElement>('#files-error');
  if (statusLine) statusLine.textContent = status;
  if (errorLine) errorLine.textContent = error;
}

// A transfer only changes button state, so the rows are patched in place. Going
// back through renderFilesBrowser would blank the list back to "Loading files…"
// at the exact moment the user is watching a row they just tapped.
function updateFileActions(name: string): void {
  const busy = Boolean(state.transfer);
  document.querySelectorAll<HTMLButtonElement>('#files-list [data-share],#files-list [data-download]').forEach((button) => {
    const kind: FileAction = button.dataset.share ? 'share' : 'download';
    const isTarget = (button.dataset.share ?? button.dataset.download) === name;
    button.disabled = busy;
    button.textContent = fileActionLabel(kind, isTarget && state.transfer?.action === kind);
  });
  document.querySelectorAll<HTMLButtonElement>('#files-list [data-open]').forEach((button) => { button.disabled = busy; });
  const up = document.querySelector<HTMLButtonElement>('#files-up');
  if (up) up.disabled = !filesBrowserPath || busy;
}

async function runFileAction(name: string, action: FileAction, size: number): Promise<void> {
  if (!invoke || !state.user || state.transfer) return;
  const relativePath = joinPath(filesBrowserPath, name);
  state.transfer = { path: name, action };
  setFilesFeedback(action === 'share' ? 'Sharing…' : 'Downloading…', '');
  updateFileActions(name);
  try {
    const result = await invoke<{ name: string; stored: boolean }>('server_file_action', {
      path: relativePath,
      root: HOME_ROOT,
      name,
      action,
      size: Number.isFinite(size) && size > 0 ? size : undefined,
    });
    setFilesFeedback(result.stored ? `Saved to Downloads as ${result.name}.` : `Sharing ${result.name}…`, '');
  } catch (error) {
    setFilesFeedback('', error instanceof Error ? error.message : String(error));
  }
  state.transfer = undefined;
  updateFileActions(name);
}

async function finishCallback(url: string): Promise<void> {
  if (!url.startsWith('filesync://oauth/callback') || !invoke) return;
  try {
    state.user = await invoke<string>('finish_login', { callbackUrl: url });
    state.offline = false;
    cacheSignedInUser(state.user);
    state.settingsAuthorized = await invoke<boolean>('settings_authorized');
    await saveSessionBackup();
    await loadPresets();
    applySpacePrefsToPairs();
    await persistPairs();
    state.error = '';
    state.notice = `Signed in as ${state.user}.`;
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error);
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
  // With no inAppBrowser option, Tauri opens OAuth in the system browser.
  await openUrl(authorizationUrl);
  state.notice = 'Complete sign-in in your browser, then return to File Sync. Saved syncs remain available.';
  state.error = '';
  render();
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
