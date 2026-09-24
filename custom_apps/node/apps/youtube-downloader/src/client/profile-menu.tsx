import { $, component$, Slot, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { apiUrl, apiFetch } from './api.js';
import { tauriInvoke } from './tauri.js';
import { installedAppVersion, installedVersionLabel, isNewerVersion } from './app-version.js';
import type { AppVersionInfo } from '../shared/types.js';

type ProfileMenuProps = {
  image: string;
  username: string;
  signedIn?: boolean;
  onImageChange: (_event: Event, target: HTMLInputElement) => Promise<void>;
  onImageClear: () => void;
  onClearHistory: () => Promise<void>;
  onSignIn?: () => Promise<void>;
  onSignOut?: () => Promise<void>;
  appDownloadUrl?: string;
};

type UpdateState =
  | { kind: 'idle' }
  | { kind: 'checking' }
  | { kind: 'uptodate' }
  | { kind: 'available'; info: AppVersionInfo }
  | { kind: 'installing' }
  | { kind: 'handed-off' }
  | { kind: 'error'; message: string };

export const ProfileMenu = component$<ProfileMenuProps>(({ image, username, signedIn, onImageChange, onImageClear, onClearHistory, onSignIn, onSignOut, appDownloadUrl }) => {
  const menuRef = useSignal<HTMLDetailsElement>();
  const platform = useSignal<string | null>(null);
  const updateState = useSignal<UpdateState>({ kind: 'idle' });
  const closeMenu = $(() => {
    if (menuRef.value) {
      menuRef.value.open = false;
    }
  });
  const clearAndClose = $(async () => {
    await onClearHistory();
    closeMenu();
  });
  const signInAndClose = $(async () => {
    closeMenu();
    await onSignIn?.();
  });

  const checkForUpdates = $(async () => {
    updateState.value = { kind: 'checking' };
    try {
      const response = await apiFetch('/api/version');
      if (!response.ok) {
        throw new Error(`The server returned ${response.status}.`);
      }
      const info = (await response.json()) as AppVersionInfo;
      updateState.value = isNewerVersion(info.version, installedAppVersion)
        ? { kind: 'available', info }
        : { kind: 'uptodate' };
    } catch (error) {
      updateState.value = {
        kind: 'error',
        message: error instanceof Error ? error.message : String(error),
      };
    }
  });

  const installUpdate = $(async () => {
    const invoke = tauriInvoke();
    if (!invoke) {
      updateState.value = { kind: 'error', message: 'Updates are only available in the Android app.' };
      return;
    }
    updateState.value = { kind: 'installing' };
    try {
      await invoke('install_app_update');
      updateState.value = { kind: 'handed-off' };
    } catch (error) {
      updateState.value = {
        kind: 'error',
        message: error instanceof Error ? error.message : String(error),
      };
    }
  });

  useVisibleTask$(({ cleanup }) => {
    const onPointerDown = (event: PointerEvent) => {
      const menu = menuRef.value;
      if (menu?.open && event.target instanceof Node && !menu.contains(event.target)) {
        menu.open = false;
      }
    };
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && menuRef.value?.open) {
        menuRef.value.open = false;
      }
    };

    document.addEventListener('pointerdown', onPointerDown);
    document.addEventListener('keydown', onKeyDown);
    cleanup(() => {
      document.removeEventListener('pointerdown', onPointerDown);
      document.removeEventListener('keydown', onKeyDown);
    });
  });

  useVisibleTask$(async () => {
    const invoke = tauriInvoke();
    if (!invoke) {
      return;
    }
    try {
      platform.value = await invoke<string>('app_platform');
    } catch {
      platform.value = 'desktop';
    }
  });

  const state = updateState.value;
  const showUpdateCheck = platform.value === 'android';

  return (
    <details ref={menuRef} class="profile-menu">
      <summary class="profile-trigger" aria-label="Open profile menu">
        {image ? <img src={image} alt="" /> : <span>{username.slice(0, 1).toUpperCase()}</span>}
      </summary>
      <section class="profile-popover" aria-label="Profile menu">
        <div class="profile-summary">
          <div class="profile-picture-control">
            <label class="profile-picture-edit" aria-label="Edit profile picture">
              <span class="profile-preview">{image ? <img src={image} alt="" /> : <span>{username.slice(0, 1).toUpperCase()}</span>}</span>
              <span class="profile-picture-edit__overlay" aria-hidden="true">
                <svg viewBox="0 0 24 24" focusable="false">
                  <path d="M12 20h9" />
                  <path d="m16.5 3.5 4 4L8 20H4v-4L16.5 3.5Z" />
                </svg>
              </span>
              <input type="file" accept="image/*" onChange$={onImageChange} />
            </label>
            {image && (
              <button class="profile-picture-clear" type="button" aria-label="Remove profile picture" onClick$={onImageClear}>
                X
              </button>
            )}
          </div>
          <div>
            <h2>{username}</h2>
            <p>Youtube Downloader</p>
          </div>
        </div>
        <div class="profile-options">
          <h3>Options</h3>
          <Slot />
        </div>
        {appDownloadUrl && (
          <a class="profile-action" href={appDownloadUrl} download onClick$={closeMenu}>
            Download Android app
          </a>
        )}
        {showUpdateCheck && (
          <div class="profile-update">
            {state.kind === 'checking' && (
              <p class="profile-update-status" role="status">Checking for updates…</p>
            )}
            {state.kind === 'uptodate' && (
              <p class="profile-update-status" role="status">You're up to date.</p>
            )}
            {state.kind === 'available' && (
              <p class="profile-update-status" role="status">
                Update available: v{state.info.version}
                {state.info.date ? ` · ${state.info.date}` : ''}
              </p>
            )}
            {state.kind === 'available' && !state.info.apkAvailable && (
              <p class="profile-update-status">The update package is not on the server yet.</p>
            )}
            {state.kind === 'installing' && (
              <p class="profile-update-status" role="status">Preparing update…</p>
            )}
            {state.kind === 'handed-off' && (
              <p class="profile-update-status" role="status">Follow the system prompts to finish installing.</p>
            )}
            {state.kind === 'error' && (
              <p class="error" role="alert">{state.message}</p>
            )}
            {state.kind === 'available' && state.info.apkAvailable && (
              <button class="profile-action profile-action--accent" type="button" onClick$={installUpdate}>
                Install update
              </button>
            )}
            <button
              class="profile-action"
              type="button"
              disabled={state.kind === 'checking' || state.kind === 'installing'}
              onClick$={checkForUpdates}
            >
              {state.kind === 'checking' ? 'Checking…' : 'Check for updates'}
            </button>
          </div>
        )}
        <p class="profile-version">{installedVersionLabel}</p>
        <button class="profile-action" type="button" onClick$={clearAndClose}>
          Clear history
        </button>
        {onSignIn && signedIn === false ? (
          <button class="profile-signout" type="button" onClick$={signInAndClose}>
            Sign in
          </button>
        ) : onSignOut ? (
          <button class="profile-signout" type="button" onClick$={onSignOut}>
            Log out
          </button>
        ) : (
          <a class="profile-signout" href={apiUrl('/oauth2/sign_out')} onClick$={closeMenu}>
            Log out
          </a>
        )}
      </section>
    </details>
  );
});
