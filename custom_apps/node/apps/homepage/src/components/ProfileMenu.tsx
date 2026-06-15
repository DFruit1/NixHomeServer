import { component$ } from '@builder.io/qwik';
import type { ImageChangeHandler, ToggleHandler } from '../shared/ui-types.js';

export const ProfileMenu = component$(
  ({
    image,
    username,
    userGroups,
    groupDescriptions,
    onImageChange,
    onImageClear,
  }: {
    image: string;
    username: string;
    userGroups: string[];
    groupDescriptions: Record<string, string>;
    onImageChange: ImageChangeHandler;
    onImageClear: ToggleHandler;
  }) => {
    const sortedUserGroups = userGroups.slice().sort((a, b) => a.localeCompare(b));
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
          <div class="profile-groups">
            <h3>My Groups</h3>
            {sortedUserGroups.length > 0 ? (
              <ul class="profile-group-list">
                {sortedUserGroups.map((group) => (
                  <li key={group}>
                    <span class="group-name" title={groupDescriptions[group] ?? 'No description available'}>
                      {group}
                    </span>
                  </li>
                ))}
              </ul>
            ) : (
              <p>No Kanidm groups were returned for this session.</p>
            )}
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
