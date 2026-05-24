import type { IncomingHttpHeaders } from 'node:http';
import type { AppConfig } from './config.js';
import type { CurrentUser } from '../shared/types.js';

const USER_HEADERS = [
  'x-forwarded-preferred-username',
  'x-auth-request-preferred-username',
  'x-forwarded-login',
  'x-auth-request-login',
  'x-forwarded-email',
  'x-auth-request-email',
  'x-forwarded-user',
  'x-auth-request-user',
] as const;

const EMAIL_HEADERS = ['x-forwarded-email', 'x-auth-request-email'] as const;
const GROUP_HEADERS = ['x-forwarded-groups', 'x-auth-request-groups'] as const;

const headerValue = (headers: IncomingHttpHeaders, name: string): string | undefined => {
  const value = headers[name];
  if (Array.isArray(value)) {
    return value[0];
  }
  return value;
};

export const normaliseUsername = (value: string | undefined): string | undefined => {
  if (!value) {
    return undefined;
  }
  const first = value.split(',', 1)[0]?.trim();
  if (!first) {
    return undefined;
  }
  const localPart = first.split('@', 1)[0];
  return /^[A-Za-z0-9._-]{1,64}$/.test(localPart) ? localPart : undefined;
};

export const parseGroups = (headers: IncomingHttpHeaders): string[] => {
  const groups = new Set<string>();
  for (const name of GROUP_HEADERS) {
    const value = headerValue(headers, name);
    if (!value) {
      continue;
    }
    for (const group of value.split(/[,\s]+/)) {
      const clean = group.trim();
      if (clean) {
        groups.add(clean);
      }
    }
  }
  return [...groups].sort();
};

export const currentUserFromHeaders = (headers: IncomingHttpHeaders, config: AppConfig): CurrentUser => {
  let username: string | undefined;
  for (const name of USER_HEADERS) {
    username = normaliseUsername(headerValue(headers, name));
    if (username) {
      break;
    }
  }
  if (!username) {
    throw new Error('missing authenticated user header');
  }

  let email: string | undefined;
  for (const name of EMAIL_HEADERS) {
    email = headerValue(headers, name)?.split(',', 1)[0]?.trim();
    if (email) {
      break;
    }
  }

  const groups = parseGroups(headers);
  const canWriteShared = groups.includes(config.sharedWriteGroup);
  return {
    username,
    email,
    groups,
    canWriteShared,
    destinations: canWriteShared ? ['personal', 'shared'] : ['personal'],
  };
};
