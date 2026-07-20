import { describe, expect, it } from 'vitest';
import { currentUserFromHeaders, normaliseUsername, parseGroups } from '../auth.js';

describe('homepage auth helpers', () => {
  it('normalises preferred usernames without domains', () => {
    expect(normaliseUsername('alice@example.test')).toBe('alice');
    expect(normaliseUsername('a..b@example.test')).toBe('a..b');
    expect(normaliseUsername('Alice@example.test')).toBeUndefined();
    expect(normaliseUsername('-alice@example.test')).toBeUndefined();
    expect(normaliseUsername('bad user')).toBeUndefined();
  });

  it('parses comma and space separated groups', () => {
    expect(parseGroups({ 'x-auth-request-groups': 'users, files-personal-users app-admin' })).toEqual([
      'app-admin',
      'files-personal-users',
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

  it('does not treat an email address as an authenticated username', () => {
    expect(() => currentUserFromHeaders({
      'x-auth-request-email': 'operator@example.test',
      'x-forwarded-email': 'operator@another.example.test',
    })).toThrow('missing authenticated user header');
  });

  it('preserves email metadata when a separate valid username claim is present', () => {
    expect(currentUserFromHeaders({
      'x-auth-request-user': 'alice',
      'x-auth-request-email': 'alice@example.test',
    })).toEqual({
      username: 'alice',
      email: 'alice@example.test',
      groups: [],
    });
  });

  it('uses an explicit development fallback user when proxy headers are absent', () => {
    expect(currentUserFromHeaders({}, 'preview')).toMatchObject({
      username: 'preview',
    });
  });
});
