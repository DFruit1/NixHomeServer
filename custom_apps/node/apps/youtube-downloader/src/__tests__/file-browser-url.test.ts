import { describe, expect, it } from 'vitest';
import { buildFileBrowserUrl } from '../root.js';
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

const location = {
  hostname: 'ytdownload.sydneybasiniot.org',
  protocol: 'https:',
};

describe('file browser URLs', () => {
  it('maps personal output folders to Filestash /files paths', () => {
    expect(
      buildFileBrowserUrl(
        '/mnt/data/users/dsaw/_Music/_YouTube/Simi and Chapchap/No Headphones No Service Blue Archive OST Rock cover album [0_G3K4DrAdU]',
        currentUser,
        location,
      ),
    ).toBe(
      'https://files.sydneybasiniot.org/files/_Music/_YouTube/Simi%20and%20Chapchap/No%20Headphones%20No%20Service%20Blue%20Archive%20OST%20Rock%20cover%20album%20%5B0_G3K4DrAdU%5D/',
    );
  });

  it('maps shared output folders through the protected shared mount', () => {
    expect(
      buildFileBrowserUrl(
        '/mnt/data/shared/_Music/_YouTube/Simi and Chapchap/No Headphones No Service Blue Archive OST Rock cover album [0_G3K4DrAdU]',
        currentUser,
        location,
      ),
    ).toBe(
      'https://files.sydneybasiniot.org/files/_Shared/_Music/_YouTube/Simi%20and%20Chapchap/No%20Headphones%20No%20Service%20Blue%20Archive%20OST%20Rock%20cover%20album%20%5B0_G3K4DrAdU%5D/',
    );
  });
});
