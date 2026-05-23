import { describe, expect, it } from 'vitest';
import { currentUserFromHeaders, normaliseUsername, parseGroups } from '../auth.js';
import type { AppConfig } from '../config.js';

const config = {
  sharedWriteGroup: 'files-shared-users',
} as AppConfig;

describe('auth headers', () => {
  it('normalises usernames from forwarded user values', () => {
    expect(normaliseUsername('dsaw@example.test')).toBe('dsaw');
    expect(normaliseUsername('bad/user@example.test')).toBeUndefined();
  });

  it('parses comma and whitespace separated groups', () => {
    expect(parseGroups({ 'x-forwarded-groups': 'downloads-users, files-shared-users users' })).toEqual([
      'downloads-users',
      'files-shared-users',
      'users',
    ]);
  });

  it('marks shared writers from the shared files Kanidm group', () => {
    const user = currentUserFromHeaders(
      {
        'x-forwarded-user': 'dsaw',
        'x-forwarded-email': 'dsaw@example.test',
        'x-forwarded-groups': 'downloads-users,files-shared-users',
      },
      config,
    );
    expect(user.canWriteShared).toBe(true);
    expect(user.destinations).toEqual(['personal', 'shared']);
  });
});
