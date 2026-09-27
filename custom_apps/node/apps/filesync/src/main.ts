import './styles.css';
import { getCurrent, onOpenUrl } from '@tauri-apps/plugin-deep-link';
import { openUrl } from '@tauri-apps/plugin-opener';

type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;
type TauriWindow = Window & { __TAURI__?: { core?: { invoke?: Invoke } } };
type Folder = { uri: string; displayName: string };
type SyncDirection = 'phone-to-server' | 'server-to-phone' | 'two-way';
type SyncPair = {
  id: string;
  name: string;
  local: Folder;
  serverPath: string;
  serverRoot?: string;
  serverFolder?: string;
  localSubpath?: string;
  direction: SyncDirection;
  server?: string;
  account?: string;
};
type SyncPreset = { id: string; folder: string; service: string; serviceTitle: string; title: string; description: string; serverPath: string; localSubpath: string; direction: SyncDirection };
type ServerEntry = { name: string; path: string; kind: string; size: number; modifiedUnixMs: number };

const invoke = (window as TauriWindow).__TAURI__?.core?.invoke;
const STORAGE_KEY = 'nixhomeserver.filesync.pairs.v1';
const SETTINGS_KEY = 'nixhomeserver.filesync.server.v1';
const app = document.querySelector<HTMLDivElement>('#app')!;

const state: { platform: string; pairs: SyncPair[]; presets: SyncPreset[]; selectedService?: string; syncingPairId?: string; server: string; user?: string; settingsAuthorized: boolean; backgroundStatus?: string; error: string; notice: string } = {
  platform: 'loading',
  pairs: readPairs(),
  presets: [],
  server: localStorage.getItem(SETTINGS_KEY) ?? '',
  settingsAuthorized: false,
  error: '',
  notice: '',
};

function readPairs(): SyncPair[] {
  try {
    const value = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]') as SyncPair[];
    return Array.isArray(value)
      ? value.filter((pair) => pair && typeof pair.id === 'string').map((pair) => ({ ...pair, server: pair.server ?? localStorage.getItem(SETTINGS_KEY) ?? '' }))
      : [];
  } catch {
    return [];
  }
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]!);
}

function directionText(direction: SyncDirection): string {
  if (direction === 'phone-to-server') return 'This device to server';
  if (direction === 'server-to-phone') return 'Server to this device';
  return 'Two-way';
}

function directionArrow(direction: SyncDirection): string {
  if (direction === 'phone-to-server') return '→';
  if (direction === 'server-to-phone') return '←';
  return '↔';
}

function render(): void {
  const services = [...new Map(state.presets.map((preset) => [preset.service, preset.serviceTitle])).entries()];
  const selectedPresets = state.presets.filter((preset) => preset.service === state.selectedService);
  const presetSection = state.user ? `
    <section class="services-section" aria-labelledby="services-heading">
      <div class="section-title-row"><h2 id="services-heading">Sync from your services</h2></div>
      ${state.selectedService ? `
        <button class="text-button back-button" type="button" id="back-to-services">← All services</button>
        <h3 class="service-heading">${escapeHtml(services.find(([id]) => id === state.selectedService)?.[1] ?? 'Service')}</h3>
        <ul class="preset-list">${selectedPresets.map((preset) => {
          const enabled = state.pairs.some((pair) => pair.server === state.server && pair.account === state.user && (pair.serverRoot ?? 'files') === preset.id && (pair.serverPath || '') === preset.serverPath);
          return `<li class="preset-row"><div><h4>${escapeHtml(preset.title)}</h4><p>${escapeHtml(preset.description)}</p><span class="preset-route">Server /${escapeHtml(preset.folder)} ${directionArrow(preset.direction)} This device /${escapeHtml(preset.localSubpath)}</span></div><button class="${enabled ? 'secondary-button' : 'primary-button'}" type="button" data-enable-preset="${escapeHtml(preset.id)}" ${enabled || state.syncingPairId ? 'disabled' : ''}>${enabled ? 'Enabled' : 'Enable and sync'}</button></li>`;
        }).join('')}</ul>
      ` : `<div class="service-grid">${services.map(([id, title]) => `<button class="service-card" type="button" data-service="${escapeHtml(id)}"><span class="service-card-name">${escapeHtml(title)}</span><span class="service-card-symbol" aria-hidden="true">${escapeHtml(title.slice(0, 2).toUpperCase())}</span><span class="service-card-action">View sync options →</span></button>`).join('')}</div>`}
      ${state.presets.length === 0 ? '<p class="services-empty">No syncable service folders are available for this account yet.</p>' : ''}
    </section>` : '';
  const pairRows = state.pairs.map((pair) => `
    <li class="pair-row" data-pair-id="${escapeHtml(pair.id)}">
      <div class="pair-paths">
        <div class="pair-location">
          <span class="location-label">This device</span>
          <strong>${escapeHtml(pair.local.displayName)}${pair.localSubpath ? ` / ${escapeHtml(pair.localSubpath)}` : ''}</strong>
        </div>
        <span class="pair-direction" aria-label="${escapeHtml(directionText(pair.direction))}">${directionArrow(pair.direction)}</span>
        <div class="pair-location">
          <span class="location-label">Server</span>
          <strong>${escapeHtml(pair.serverRoot && pair.serverRoot !== 'files' ? `/${pair.serverFolder ?? pair.serverRoot}${pair.serverPath ? `/${pair.serverPath}` : ''}` : pair.serverPath ? `/_Files/${pair.serverPath}` : '/_Files')}</strong>
        </div>
      </div>
      <div class="pair-meta">
        <span>${escapeHtml(pair.name)}</span>
        <span>${escapeHtml(directionText(pair.direction))}</span>
        <button class="text-button" type="button" data-sync="${escapeHtml(pair.id)}" ${state.syncingPairId || pair.direction === 'two-way' || (pair.server && pair.server !== state.server) || !state.user || pair.account !== state.user ? 'disabled' : ''}>${state.syncingPairId === pair.id ? 'Syncing…' : pair.direction === 'two-way' ? 'Recreate pair' : pair.server && pair.server !== state.server ? 'Different server' : !state.user ? 'Sign in to sync' : pair.account !== state.user ? 'Different account' : 'Sync now'}</button>
        <button class="text-button danger-text" type="button" data-remove="${escapeHtml(pair.id)}" aria-label="Remove ${escapeHtml(pair.name)}">Remove</button>
      </div>
    </li>
  `).join('');

  app.innerHTML = `
    <main class="shell">
      <header class="topbar">
        <a class="brand" href="#" aria-label="File Sync home"><span class="brand-mark" aria-hidden="true">FS</span><span>File Sync</span></a>
        <span class="prototype-label">Prototype</span>
      </header>

      <section class="intro" aria-labelledby="page-title">
        <div>
          <p class="eyebrow">NixHomeServer</p>
          <h1 id="page-title">Sync pairs</h1>
          <p class="intro-copy">Choose a folder on this device and its server folder. The arrow shows which way files will move. Sync checks file contents first, so large folders can take time to scan.</p>
        </div>
        <button class="primary-button" type="button" id="open-pair-form">Add a folder pair</button>
      </section>

      <section class="server-line" aria-label="Server connection">
        <label for="server-address">Server address</label>
        <div class="server-input-row">
          <input id="server-address" type="url" placeholder="https://filesync-api.example.net" value="${escapeHtml(state.server)}" autocomplete="url" />
          <button class="secondary-button" type="button" id="save-server">Save</button>
        </div>
        <div class="account-row">
          ${state.user
            ? `<p>Signed in to Kanidm as <strong>${escapeHtml(state.user)}</strong>. Saved syncs stay connected. ${state.settingsAuthorized ? 'Settings unlocked for 24 hours after sign-in.' : 'Sign in again to change sync settings.'}${state.platform === 'android' ? ` Android checks saved pairs about every 15 minutes on unmetered networks; the system may defer a run.${state.backgroundStatus ? ` ${escapeHtml(state.backgroundStatus)}` : ''}` : ''}</p><button class="secondary-button" type="button" id="unlock-settings" ${state.settingsAuthorized ? 'disabled' : ''}>${state.settingsAuthorized ? 'Settings unlocked' : 'Unlock settings'}</button><button class="text-button" type="button" id="sign-out">Sign out</button>`
            : '<p>Sign in with Kanidm. Your account needs access to personal files. File Sync requests offline access so it can stay connected between manual syncs.</p><button class="secondary-button" type="button" id="sign-in">Sign in with Kanidm</button>'}
        </div>
      </section>

      ${presetSection}

      <section class="pairs-section" aria-labelledby="pairs-heading">
        <div class="section-title-row">
          <h2 id="pairs-heading">Folder pairs</h2>
          <span class="item-count">${state.pairs.length}</span>
        </div>
        ${state.pairs.length === 0
          ? '<div class="empty-state"><h3>No folders paired yet</h3><p>Add a local folder and a server destination to define a sync pair.</p><button class="text-button" id="empty-add" type="button">Add the first pair</button></div>'
          : `<ul class="pair-list">${pairRows}</ul>`}
      </section>

      <p class="prototype-note">Sign-in uses Kanidm. SFTP keys are not used by this app.</p>
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
        <p class="form-hint">Files copy one way; same-name destination files are replaced, and deletions never propagate. Two-way conflict handling will be added later.</p>
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
  `;

  bindEvents();
}

let selectedFolder: Folder | undefined;
let selectedServerPath = '';
let selectedServerRoot = 'files';
let hasSelectedServerFolder = false;
let serverBrowserPath = '';

function bindEvents(): void {
  const dialog = document.querySelector<HTMLDialogElement>('#pair-dialog')!;
  const browser = document.querySelector<HTMLDialogElement>('#server-browser')!;
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
      const folder = await invoke<Folder | null>('pick_local_folder');
      if (!folder) { button.disabled = false; return; }
      const pair: SyncPair = { id: crypto.randomUUID(), name: preset.title, local: folder, serverRoot: preset.id, serverFolder: preset.folder, serverPath: preset.serverPath, localSubpath: preset.localSubpath, direction: preset.direction, server: state.server, account: state.user };
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
        try {
          const result = await invoke<{ transferred: number; skipped: number }>('sync_pair', { pair });
          state.notice = `Sync complete: ${result.transferred} transferred, ${result.skipped} unchanged.`;
        } catch (error) {
          showError(error);
          state.notice = 'Pair saved. Use Sync now to retry.';
        }
        state.syncingPairId = undefined;
      }
    } catch (error) { showError(error); }
    render();
  }));
  document.querySelector('#save-server')?.addEventListener('click', async () => {
    const input = document.querySelector<HTMLInputElement>('#server-address')!;
    const nextServer = input.value.trim().replace(/\/+$/, '');
    if (nextServer !== state.server && state.user && !(await ensureSettingsAuthorized())) return;
    if (state.user && nextServer !== state.server && invoke) {
      try { await invoke<void>('logout'); state.user = undefined; state.settingsAuthorized = false; }
      catch (error) { setError(error); return; }
    }
    state.server = nextServer;
    state.presets = [];
    state.selectedService = undefined;
    localStorage.setItem(SETTINGS_KEY, state.server);
    state.notice = state.server ? 'Server address saved on this device.' : 'Server address cleared.';
    state.error = '';
    render();
  });

  document.querySelector('#sign-in')?.addEventListener('click', async () => {
    if (!invoke) return;
    const server = state.server.trim();
    if (!server) {
      state.error = 'Save the sync server address before signing in.';
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
      state.user = undefined;
      state.settingsAuthorized = false;
      state.presets = [];
      state.selectedService = undefined;
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
    state.pairs = [...state.pairs, { id: crypto.randomUUID(), name, local: selectedFolder, serverRoot: selectedServerRoot, serverFolder: state.presets.find((item) => item.id === selectedServerRoot)?.folder, serverPath, direction, server: state.server, account: state.user }];
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
  });

  document.querySelectorAll<HTMLButtonElement>('[data-remove]').forEach((button) => {
    button.addEventListener('click', async () => {
      if (!(await ensureSettingsAuthorized())) return;
      const pair = state.pairs.find((item) => item.id === button.dataset.remove);
      if (!pair || !window.confirm(`Remove the “${pair.name}” folder pair? This only removes its settings.`)) return;
      state.pairs = state.pairs.filter((item) => item.id !== pair.id);
      try { await persistPairs(); }
      catch (error) { showError(error); return; }
      if (!state.pairs.some((item) => item.local.uri === pair.local.uri) && invoke) {
        void invoke<void>('forget_local_folder', { folderUri: pair.local.uri }).catch(() => undefined);
      }
      state.notice = 'Folder pair removed.';
      render();
    });
  });

  document.querySelectorAll<HTMLButtonElement>('[data-sync]').forEach((button) => {
    button.addEventListener('click', async () => {
      if (!invoke || !state.user) { state.error = 'Sign in before syncing.'; render(); return; }
      const pair = state.pairs.find((item) => item.id === button.dataset.sync);
      if (!pair) return;
      state.syncingPairId = pair.id;
      button.disabled = true;
      button.textContent = 'Syncing…';
      try {
        const result = await invoke<{ transferred: number; skipped: number }>('sync_pair', { pair });
        state.notice = `Sync complete: ${result.transferred} transferred, ${result.skipped} unchanged.`;
        state.error = '';
      } catch (error) { showError(error); }
      state.syncingPairId = undefined;
      render();
    });
  });

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
  }
  render();
}

async function start(): Promise<void> {
  if (invoke) {
    try {
      await onOpenUrl((urls) => { for (const url of urls) void finishCallback(url); });
    } catch { /* The browser preview does not provide native deep links. */ }
    try {
      state.platform = await invoke<string>('platform_name');
    } catch {
      state.platform = 'unknown';
    }
    try {
      state.user = await invoke<string | null>('current_user') ?? undefined;
      state.backgroundStatus = readBackgroundStatus(await invoke<string | null>('background_sync_status'));
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
  } else {
    state.platform = 'browser';
  }
  render();
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
    state.settingsAuthorized = await invoke<boolean>('settings_authorized');
    await loadPresets();
    await persistPairs();
    state.error = '';
    state.notice = `Signed in as ${state.user}.`;
  } catch (error) {
    state.error = error instanceof Error ? error.message : String(error);
  }
  render();
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
  if (!server) throw new Error('Save the sync server address before signing in.');
  const authorizationUrl = await invoke<string>('begin_login', { serverUrl: server });
  await openUrl(authorizationUrl);
  state.notice = 'Complete sign-in in your browser, return to File Sync, then retry the settings change. Saved syncs remain available.';
  state.error = '';
  render();
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

void start();
