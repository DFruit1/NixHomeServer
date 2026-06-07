import { describe, expect, it } from 'vitest';
import { currentUserFromHeaders, normaliseUsername, parseGroups } from '../auth.js';

describe('homepage auth helpers', () => {
  it('normalises preferred usernames without domains', () => {
    expect(normaliseUsername('alice@example.test')).toBe('alice');
    expect(normaliseUsername('bad user')).toBeUndefined();
  });

  it('parses comma and space separated groups', () => {
    expect(parseGroups({ 'x-auth-request-groups': 'users, user-files app-admin' })).toEqual([
      'app-admin',
      'user-files',
      'users',
    ]);
  });

  it('builds a current user from proxy headers', () => {
    expect(
      currentUserFromHeaders({
        'x-auth-request-preferred-username': 'alice',
        'x-auth-request-email': 'alice@example.test',
      }),
    ).toMatchObject({
      username: 'alice',
      email: 'alice@example.test',
    });
  });

  it('uses an explicit development fallback user when proxy headers are absent', () => {
    expect(currentUserFromHeaders({}, 'preview')).toMatchObject({
      username: 'preview',
    });
  });
});
