import type { IncomingHttpHeaders } from 'node:http';

export type Identity = {
  username: string;
  email?: string;
  groups: string[];
};

const GROUP_HEADERS = [
  'x-forwarded-groups',
  'x-auth-request-groups',
] as const;

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
  return [ ...groups ].sort();
};
