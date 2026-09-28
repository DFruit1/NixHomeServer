import './styles.css';
import { getCurrent, onOpenUrl } from '@tauri-apps/plugin-deep-link';
import { openUrl } from '@tauri-apps/plugin-opener';
import { parseSavedPairs, type Folder, type SyncDirection, type SyncPair } from './pairs';

type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;
type TauriWindow = Window & { __TAURI__?: { core?: { invoke?: Invoke } } };
type SyncPreset = { id: string; folder: string; service: string; serviceTitle: string; title: string; description: string; serverPath: string; localSubpath: string; direction: SyncDirection };
type ServerEntry = { name: string; path: string; kind: string; size: number; modifiedUnixMs: number };

const invoke = (window as TauriWindow).__TAURI__?.core?.invoke;
const STORAGE_KEY = 'nixhomeserver.filesync.pairs.v1';
const SETTINGS_KEY = 'nixhomeserver.filesync.server.v1';
const DEFAULT_SERVER = import.meta.env.VITE_FILESYNC_DEFAULT_SERVER ?? '';
const app = document.querySelector<HTMLDivElement>('#app')!;

const state: { pairs: SyncPair[]; presets: SyncPreset[]; selectedService?: string; syncingPairId?: string; server: string; user?: string; settingsAuthorized: boolean; backgroundStatus?: string; error: string; notice: string } = {
  pairs: readPairs(),
  presets: [],
  server: localStorage.getItem(SETTINGS_KEY) ?? DEFAULT_SERVER,
  settingsAuthorized: false,
  error: '',
  notice: '',
};

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
      <div class="pair-actions">
        <button class="text-button" type="button" data-sync="${escapeHtml(pair.id)}" ${state.syncingPairId || pair.direction === 'two-way' || (pair.server && pair.server !== state.server) || !state.user || pair.account !== state.user ? 'disabled' : ''}>${state.syncingPairId === pair.id ? 'Syncing…' : pair.direction === 'two-way' ? 'Recreate pair' : pair.server && pair.server !== state.server ? 'Different server' : !state.user ? 'Sign in to sync' : pair.account !== state.user ? 'Different account' : 'Sync now'}</button>
        <button class="text-button danger-text" type="button" data-remove="${escapeHtml(pair.id)}" aria-label="Remove ${escapeHtml(pair.name)}">Remove</button>
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
            ? `<p class="account-user">Signed in as <strong>${escapeHtml(state.user)}</strong>${state.backgroundStatus ? ` · ${escapeHtml(state.backgroundStatus)}` : ''}</p><button class="secondary-button" type="button" id="unlock-settings" ${state.settingsAuthorized ? 'disabled' : ''}>${state.settingsAuthorized ? 'Settings unlocked' : 'Unlock settings'}</button><button class="text-button" type="button" id="sign-out">Sign out</button>`
            : '<p class="account-user">Sign in to sync your folders.</p><button class="secondary-button" type="button" id="sign-in">Sign in</button>'}
        </div>
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
        <p class="form-error" id="settings-error" role="alert"></p>
        <div class="dialog-actions"><button class="secondary-button" value="cancel">Cancel</button><button class="primary-button" id="save-server" type="button">Save address</button></div>
      </form>
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
    let nextServer: string;
    try { nextServer = normalizeServerAddress(input.value); }
    catch (error) {
      document.querySelector<HTMLElement>('#settings-error')!.textContent = error instanceof Error ? error.message : String(error);
      input.focus();
      return;
    }
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
