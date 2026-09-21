import { describe, expect, it, vi } from 'vitest';

vi.mock('../client/api.js', () => ({
  isTauriRuntime: () => true,
  serverBaseUrl: () => 'https://ytdownload-app.sydneybasiniot.org',
}));

import { buildFileBrowserUrl } from '../client/file-browser-url.js';
import type { CurrentUser } from '../shared/types.js';

const currentUser: CurrentUser = {
  username: 'dsaw',
  groups: [],
  canWriteShared: true,
  destinations: ['personal', 'shared'],
  fileBrowserPathRoots: {
    usersRoot: '/mnt/data/users',
    sharedMountName: '_Shared',
    sharedRoots: [
      {
        serverRoot: '/mnt/data/shared/_Music/_YouTube',
        browserPath: '_Shared/_Music/_YouTube',
      },
    ],
  },
};

describe('file browser URLs in the native shell', () => {
  it('derives the Filebrowser host from the configured server, not tauri.localhost', () => {
    expect(
      buildFileBrowserUrl('/mnt/data/users/dsaw/_Music/_YouTube/An Album', currentUser),
    ).toBe('https://files.sydneybasiniot.org/files/_Music/_YouTube/An%20Album/');
  });

  it('maps shared output folders through the protected shared mount', () => {
    expect(
      buildFileBrowserUrl('/mnt/data/shared/_Music/_YouTube/An Album', currentUser),
    ).toBe('https://files.sydneybasiniot.org/files/_Shared/_Music/_YouTube/An%20Album/');
  });
});
