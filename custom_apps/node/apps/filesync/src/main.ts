import './styles.css';
import { getCurrent, onOpenUrl } from '@tauri-apps/plugin-deep-link';
import { openUrl } from '@tauri-apps/plugin-opener';
import { parseSavedPairs, type Folder, type SyncDirection, type SyncPair } from './pairs';
import { DEFAULT_BLOCK_PERCENT, DEFAULT_WARN_PERCENT, clampPercent, evaluateSpace, formatBytes } from './storage';

type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;
type TauriWindow = Window & { __TAURI__?: { core?: { invoke?: Invoke } } };
type SyncPreset = { id: string; folder: string; service: string; serviceTitle: string; title: string; description: string; serverPath: string; localSubpath: string; direction: SyncDirection };
type ServerEntry = { name: string; path: string; kind: string; size: number; modifiedUnixMs: number };
type SyncProgress = { active: boolean; pair: string; pairs: string[]; direction: string; currentFile: string; transferred: number; skipped: number };
type SyncEstimate = { pendingBytes: number; pendingCount: number; skipped: number; direction: string; freeBytes: number; totalBytes: number };
type DeviceStorage = { freeBytes: number; totalBytes: number };

const invoke = (window as TauriWindow).__TAURI__?.core?.invoke;
const STORAGE_KEY = 'nixhomeserver.filesync.pairs.v1';
const SETTINGS_KEY = 'nixhomeserver.filesync.server.v1';
const SESSION_BACKUP_KEY = 'nixhomeserver.filesync.session-backup.v1';
const USER_KEY = 'nixhomeserver.filesync.user.v1';
const SPACE_PREFS_KEY = 'nixhomeserver.filesync.space-limits.v1';
const DEFAULT_SERVER = import.meta.env.VITE_FILESYNC_DEFAULT_SERVER ?? '';
const app = document.querySelector<HTMLDivElement>('#app')!;

const state: { pairs: SyncPair[]; presets: SyncPreset[]; selectedService?: string; syncingPairId?: string; removingPairId?: string; progress?: SyncProgress; server: string; user?: string; offline: boolean; settingsAuthorized: boolean; backgroundStatus?: string; error: string; notice: string; estimates: Record<string, SyncEstimate | undefined>; estimatesDone: Record<string, boolean>; deviceStorage?: DeviceStorage; warnPercent: number; blockPercent: number } = {
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
  const text = status === 'blocked'
    ? `Not enough space: ${formatBytes(estimate.pendingBytes)} needed · ${formatBytes(estimate.freeBytes)} free`
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

function serviceInitials(title: string): string {
  return title.trim().slice(0, 2).toUpperCase();
}

function serverLocation(pair: SyncPair): string {
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

function render(): void {
  const services = [...new Map(state.presets.map((preset) => [preset.service, preset.serviceTitle])).entries()];
  const selectedPresets = state.presets.filter((preset) => preset.service === state.selectedService);
  const presetSection = state.user ? `
    <section class="services-section" aria-labelledby="services-heading">
      <h2 id="services-heading">Sync from your services</h2>
      ${state.selectedService ? `
        <button class="text-button back-button" type="button" id="back-to-services">← All services</button>
        <h3 class="service-heading">${escapeHtml(services.find(([id]) => id === state.selectedService)?.[1] ?? 'Service')}</h3>
        <ul class="preset-list">${selectedPresets.map((preset) => {
          const enabled = state.pairs.some((pair) => pair.server === state.server && pair.account === state.user && (pair.serverRoot ?? 'files') === preset.id && (pair.serverPath || '') === preset.serverPath);
          const route = routeFor(preset.direction, `/${preset.localSubpath}`, `/${preset.folder}${preset.serverPath ? `/${preset.serverPath}` : ''}`);
          return `<li class="preset-row"><div class="preset-copy"><h4>${escapeHtml(preset.title)}</h4><p>${escapeHtml(preset.description)}</p><span class="preset-route"><span class="route-label">${escapeHtml(route.sourceLabel)}</span> ${escapeHtml(route.sourceValue)} <span class="route-arrow" aria-hidden="true">${route.arrow}</span> <span class="route-label">${escapeHtml(route.targetLabel)}</span> ${escapeHtml(route.targetValue)}</span></div><button class="${enabled ? 'secondary-button' : 'primary-button'}" type="button" data-enable-preset="${escapeHtml(preset.id)}" ${enabled || state.syncingPairId ? 'disabled' : ''}>${enabled ? 'Enabled' : 'Enable and sync'}</button></li>`;
        }).join('')}</ul>
      ` : `<div class="service-grid">${services.map(([id, title]) => {
        const logo = SERVICE_LOGOS[id];
        return `<button class="service-card" type="button" data-service="${escapeHtml(id)}"><span class="service-logo" aria-hidden="true"><span class="service-symbol">${escapeHtml(serviceInitials(title))}</span>${logo ? `<img src="${logo}" alt="" loading="lazy" onerror="this.remove()" />` : ''}</span><span class="service-card-name">${escapeHtml(title)}</span><span class="service-card-action">View sync options →</span></button>`;
      }).join('')}</div>`}
      ${state.presets.length === 0 ? '<p class="services-empty">No syncable service folders are available for this account yet.</p>' : ''}
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
          <span class="route-role">From</span>
          <span class="route-place">${escapeHtml(route.sourceLabel)}</span>
          <strong class="route-path">${escapeHtml(route.sourceValue)}</strong>
        </div>
        <span class="route-arrow" aria-label="${escapeHtml(directionText(pair.direction))}">${route.arrow}</span>
        <div class="route-endpoint">
          <span class="route-role">To</span>
          <span class="route-place">${escapeHtml(route.targetLabel)}</span>
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

      <section class="intro" aria-labelledby="page-title">
        <h1 id="page-title">Sync pairs</h1>
        <button class="primary-button" type="button" id="open-pair-form">Add a folder pair</button>
      </section>

      <section class="account-line" aria-label="Account">
        <div class="account-row">
          ${state.user
            ? `<p class="account-user">Signed in as <strong>${escapeHtml(state.user)}</strong>${state.offline ? ' (offline, will retry)' : ''}${state.backgroundStatus ? ` · ${escapeHtml(state.backgroundStatus)}` : ''}<span id="storage-summary">${escapeHtml(storageSummary())}</span></p><button class="secondary-button" type="button" id="unlock-settings" ${state.settingsAuthorized ? 'disabled' : ''}>${state.settingsAuthorized ? 'Settings unlocked' : 'Unlock settings'}</button><button class="text-button" type="button" id="sign-out">Sign out</button>`
            : '<p class="account-user">Sign in to sync your folders.</p><button class="secondary-button" type="button" id="sign-in">Sign in</button>'}
        </div>
      </section>

      <section class="sync-progress" id="sync-progress" aria-live="polite" ${state.progress?.active || state.syncingPairId ? '' : 'hidden'}>
        ${progressCopy(state)}
      </section>

      ${presetSection}

      <section class="pairs-section" aria-labelledby="pairs-heading">
        <h2 id="pairs-heading">Folder pairs</h2>
        ${state.pairs.length === 0
          ? '<div class="empty-state"><h3>No folders paired yet</h3><button class="text-button" id="empty-add" type="button">Add the first pair</button></div>'
          : `<ul class="pair-list">${pairRows}</ul>`}
      </section>

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
        <select id="server-root" aria-label="Server library">${state.presets.map((preset) => `<option value="${escapeHtml(preset.id)}">${escapeHtml(preset.serviceTitle)} / ${escapeHtml(preset.folder)}</option>`).join('')}</select>
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

    <dialog id="permission-dialog" class="pair-dialog" aria-labelledby="permission-heading">
      <div class="dialog-heading"><h2 id="permission-heading">All files access</h2><button class="close-button" type="button" id="cancel-permission-request" aria-label="Close dialog">×</button></div>
      <p id="permission-status"></p>
      <div class="dialog-actions"><button class="secondary-button" type="button" id="choose-folder-manually">Choose folder manually</button><button class="primary-button" type="button" id="open-all-files-settings">Open settings</button></div>
    </dialog>

    <dialog id="settings-dialog" class="pair-dialog settings-dialog" aria-labelledby="settings-heading">
      <form method="dialog" id="settings-form">
        <div class="dialog-heading"><h2 id="settings-heading">Settings</h2><button class="close-button" value="cancel" aria-label="Close settings">×</button></div>
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
let selectedServerRoot = 'files';
let hasSelectedServerFolder = false;
let serverBrowserPath = '';
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
    selectedServerRoot = 'files';
    hasSelectedServerFolder = false;
  });
  const openPairForm = async () => { if (await ensureSettingsAuthorized()) dialog.showModal(); };
  document.querySelector('#open-pair-form')?.addEventListener('click', () => void openPairForm());
  document.querySelector('#empty-add')?.addEventListener('click', () => void openPairForm());
  document.querySelectorAll<HTMLButtonElement>('[data-service]').forEach((button) => button.addEventListener('click', () => {
    state.selectedService = button.dataset.service;
    render();
  }));
  document.querySelector('#back-to-services')?.addEventListener('click', () => { state.selectedService = undefined; render(); });
  document.querySelectorAll<HTMLButtonElement>('[data-enable-preset]').forEach((button) => button.addEventListener('click', async () => {
    const preset = state.presets.find((item) => item.id === button.dataset.enablePreset);
    if (!invoke || !preset) return;
    if (!(await ensureSettingsAuthorized())) return;
    button.disabled = true;
    try {
      const folder = await obtainPresetFolder(preset);
      if (!folder) { button.disabled = false; return; }
      const pair: SyncPair = { id: crypto.randomUUID(), name: preset.title, local: folder, serverRoot: preset.id, serverFolder: preset.folder, serverPath: preset.serverPath, localSubpath: preset.localSubpath, direction: preset.direction, server: state.server, account: state.user, ...currentLimits() };
      if (state.pairs.some((item) => item.server === pair.server && item.account === pair.account && (item.serverRoot ?? 'files') === pair.serverRoot && item.serverPath === pair.serverPath)) {
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
    state.selectedService = undefined;
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
      state.selectedService = undefined;
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
    selectedServerRoot = document.querySelector<HTMLSelectElement>('#server-root')?.value || 'files';
    serverBrowserPath = '';
    await renderServerBrowser();
    browser.showModal();
  });
  document.querySelector('#server-root')?.addEventListener('change', () => {
    hasSelectedServerFolder = false;
    selectedServerPath = '';
    const label = document.querySelector<HTMLElement>('#picked-server-folder');
    if (label) label.textContent = 'No server folder selected';
  });
  document.querySelector('#close-server-browser')?.addEventListener('click', () => browser.close());
  document.querySelector('#server-browser-up')?.addEventListener('click', async () => {
    serverBrowserPath = serverBrowserPath.split('/').slice(0, -1).join('/');
    await renderServerBrowser();
  });
  document.querySelector('#choose-server-folder')?.addEventListener('click', () => {
    selectedServerPath = serverBrowserPath;
    hasSelectedServerFolder = true;
    const label = document.querySelector<HTMLElement>('#picked-server-folder');
    if (label) label.textContent = `/${state.presets.find((item) => item.id === selectedServerRoot)?.folder ?? selectedServerRoot}${selectedServerPath ? `/${selectedServerPath}` : ''}`;
    browser.close();
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
    state.pairs = [...state.pairs, { id: crypto.randomUUID(), name, local: selectedFolder, serverRoot: selectedServerRoot, serverFolder: state.presets.find((item) => item.id === selectedServerRoot)?.folder, serverPath, direction, server: state.server, account: state.user, ...currentLimits() }];
    try { await persistPairs(); }
    catch (error) { showError(error); return; }
    selectedFolder = undefined;
    selectedServerPath = '';
    selectedServerRoot = 'files';
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
      };
      state.deviceStorage = { freeBytes: Number(raw.freeBytes) || 0, totalBytes: Number(raw.totalBytes) || 0 };
    } catch {
      if (run !== estimateRun) return;
      state.estimates[pair.id] = undefined;
    }
    state.estimatesDone[pair.id] = true;
    updateSpaceUi(pair.id);
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
    state.selectedService = undefined;
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
  if (location) location.textContent = `/${state.presets.find((item) => item.id === selectedServerRoot)?.folder ?? selectedServerRoot}${serverBrowserPath ? `/${serverBrowserPath}` : ''}`;
  if (!list || !invoke) return;
  list.textContent = 'Loading folders…';
  try {
    const entries = await invoke<ServerEntry[]>('server_tree', { path: serverBrowserPath, root: selectedServerRoot });
    const directories = entries.filter((entry) => entry.kind === 'directory');
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
