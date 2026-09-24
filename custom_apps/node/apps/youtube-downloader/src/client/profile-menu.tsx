import { $, component$, Slot, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import { apiUrl } from './api.js';

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

export const ProfileMenu = component$<ProfileMenuProps>(({ image, username, signedIn, onImageChange, onImageClear, onClearHistory, onSignIn, onSignOut, appDownloadUrl }) => {
  const menuRef = useSignal<HTMLDetailsElement>();
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
