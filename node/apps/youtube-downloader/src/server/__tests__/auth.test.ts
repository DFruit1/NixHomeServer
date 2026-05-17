import { describe, expect, it } from 'vitest';
import { currentUserFromHeaders, normaliseUsername, parseGroups } from '../auth.js';
import type { AppConfig } from '../config.js';

const config = {
  sharedWriteGroup: 'shared-files-read-write-access',
} as AppConfig;

describe('auth headers', () => {
  it('normalises usernames from forwarded user values', () => {
    expect(normaliseUsername('dsaw@example.test')).toBe('dsaw');
    expect(normaliseUsername('bad/user@example.test')).toBeUndefined();
  });

  it('parses comma and whitespace separated groups', () => {
    expect(parseGroups({ 'x-forwarded-groups': 'metube-users, shared-files-read-write-access users' })).toEqual([
      'metube-users',
      'shared-files-read-write-access',
      'users',
    ]);
  });

  it('marks shared writers from the existing Kanidm group', () => {
    const user = currentUserFromHeaders(
      {
        'x-forwarded-user': 'dsaw',
        'x-forwarded-email': 'dsaw@example.test',
        'x-forwarded-groups': 'metube-users,shared-files-read-write-access',
      },
      config,
    );
    expect(user.canWriteShared).toBe(true);
    expect(user.destinations).toEqual(['personal', 'shared']);
  });
});
