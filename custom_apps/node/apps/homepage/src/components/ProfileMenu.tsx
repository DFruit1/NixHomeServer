import { $, component$, useSignal, useVisibleTask$ } from '@builder.io/qwik';
import type { ImageChangeHandler, ToggleHandler } from '../shared/ui-types.js';

export const ProfileMenu = component$(
  ({
    image,
    username,
    onImageChange,
    onImageClear,
  }: {
    image: string;
    username: string;
    onImageChange: ImageChangeHandler;
    onImageClear: ToggleHandler;
  }) => {
    const menuRef = useSignal<HTMLDetailsElement>();
    const showUnusedApps = useSignal(false);
    const closeMenu = $(() => {
      if (menuRef.value) {
        menuRef.value.open = false;
      }
    });

    useVisibleTask$(({ cleanup }) => {
      showUnusedApps.value = window.localStorage.getItem('homepage.showUnusedApps') === 'true';

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

    const updateShowUnusedApps = $((_event: Event, target: HTMLInputElement) => {
      showUnusedApps.value = target.checked;
      window.localStorage.setItem('homepage.showUnusedApps', String(target.checked));
      document.dispatchEvent(new CustomEvent('homepage-show-unused-apps-change', { detail: { show: target.checked } }));
    });

    return (
      <details ref={menuRef} class="profile-menu">
        <summary class="profile-trigger" aria-label="Open profile menu">
          {image ? <img src={image} alt="" /> : <span>{username.slice(0, 1).toUpperCase()}</span>}
        </summary>
        <section class="profile-popover" aria-label="Profile menu">
          <div class="profile-summary">
            <div class="profile-preview">{image ? <img src={image} alt="" /> : <span>{username.slice(0, 1).toUpperCase()}</span>}</div>
            <div>
              <h2>{username}</h2>
              <p>Homepage profile</p>
            </div>
          </div>
          <label class="profile-upload">
            Profile picture
            <input type="file" accept="image/*" onChange$={onImageChange} />
          </label>
          {image && (
            <button class="profile-action" type="button" onClick$={onImageClear}>
              Remove picture
            </button>
          )}
          <section class="profile-preferences" aria-label="Preferences">
            <h3>Preferences</h3>
            <label>
              <input type="checkbox" checked={showUnusedApps.value} onChange$={updateShowUnusedApps} />
              <span>Show unused apps</span>
            </label>
          </section>
          <a class="profile-signout" href="/oauth2/sign_out?rd=/oauth2/start" onClick$={closeMenu}>
            Sign out
          </a>
        </section>
      </details>
    );
  },
);
