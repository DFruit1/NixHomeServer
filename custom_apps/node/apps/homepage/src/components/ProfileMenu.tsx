import { component$ } from '@builder.io/qwik';
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
    return (
      <details class="profile-menu">
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
          <button class="profile-action" type="button" disabled>
            Preferences
          </button>
          <a class="profile-signout" href="/oauth2/sign_out?rd=/oauth2/start">
            Sign out
          </a>
        </section>
      </details>
    );
  },
);
