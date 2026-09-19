import type { IncomingHttpHeaders } from 'node:http';
import type { AppConfig } from './config.js';
import type { CurrentUser } from '../shared/types.js';
import { normaliseUsername, parseGroups, type Identity } from './identity.js';
import { createJwksKeyProvider, verifyBearerToken, type KeyProvider } from './bearer-auth.js';

export { normaliseUsername, parseGroups };
export type { Identity };

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

const headerValue = (headers: IncomingHttpHeaders, name: string): string | undefined => {
  const value = headers[name];
  if (Array.isArray(value)) {
    return value[0];
  }
  return value;
};

// Kanidm group claims may be a bare name or an SPN (name@domain); compare on
// the short, case-insensitive name so either form matches.
const normaliseGroup = (group: string): string => group.split('@', 1)[0]?.trim().toLowerCase() ?? '';

const hasGroup = (groups: string[], required: string): boolean => {
  const target = normaliseGroup(required);
  return target !== '' && groups.some((group) => normaliseGroup(group) === target);
};

const trimSlashes = (value: string): string => value.replace(/^\/+|\/+$/g, '');

const pathWithoutTrailingSlash = (value: string): string => value.replace(/\/+$/, '');

const relativePath = (root: string, child: string): string => {
  const cleanRoot = pathWithoutTrailingSlash(root);
  const cleanChild = pathWithoutTrailingSlash(child);
  if (cleanChild === cleanRoot) {
    return '';
  }
  return cleanChild.startsWith(`${cleanRoot}/`) ? cleanChild.slice(cleanRoot.length + 1) : trimSlashes(cleanChild);
};

const joinBrowserPath = (...parts: string[]): string => parts.map(trimSlashes).filter(Boolean).join('/');

export const buildCurrentUser = (identity: Identity, config: AppConfig): CurrentUser => {
  const canWriteShared = hasGroup(identity.groups, config.sharedWriteGroup);
  return {
    username: identity.username,
    email: identity.email,
    groups: identity.groups,
    canWriteShared,
    fileBrowserUrlTemplate: config.fileBrowserUrlTemplate,
    ...(config.appApkPath ? { appDownloadUrl: '/api/app/download' } : {}),
    fileBrowserPathRoots: {
      usersRoot: config.usersRoot,
      sharedMountName: config.fileBrowserSharedMountName,
      sharedRoots: [
        {
          serverRoot: config.sharedAudioRoot,
          browserPath: joinBrowserPath(config.fileBrowserSharedMountName, relativePath(config.sharedRoot, config.sharedAudioRoot)),
        },
        {
          serverRoot: config.sharedVideoRoot,
          browserPath: joinBrowserPath(config.fileBrowserSharedMountName, relativePath(config.sharedRoot, config.sharedVideoRoot)),
        },
        {
          serverRoot: config.sharedAudiobooksRoot,
          browserPath: joinBrowserPath(config.fileBrowserSharedMountName, relativePath(config.sharedRoot, config.sharedAudiobooksRoot)),
        },
      ],
    },
    destinations: canWriteShared ? ['personal', 'shared'] : ['personal'],
  };
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

  return buildCurrentUser({ username, email, groups: parseGroups(headers) }, config);
};

const keyProviders = new Map<string, KeyProvider>();

const keyProviderFor = (issuer: string): KeyProvider => {
  let provider = keyProviders.get(issuer);
  if (!provider) {
    provider = createJwksKeyProvider({ issuer });
    keyProviders.set(issuer, provider);
  }
  return provider;
};

export const authenticateRequest = async (
  headers: IncomingHttpHeaders,
  config: AppConfig,
  keyProvider?: KeyProvider,
): Promise<CurrentUser> => {
  const authorization = headerValue(headers, 'authorization');
  const issuer = config.authIssuerUrl;
  if (issuer && authorization && authorization.startsWith('Bearer ')) {
    const token = authorization.slice('Bearer '.length).trim();
    if (!token) {
      throw new Error('missing authenticated user token');
    }
    const identity = await verifyBearerToken(token, {
      issuer,
      audience: config.authAudience ?? '',
      groupsClaim: config.authGroupsClaim,
      getKey: keyProvider ?? keyProviderFor(issuer),
    });
    if (config.authRequiredGroup && !hasGroup(identity.groups, config.authRequiredGroup)) {
      throw new Error(`not authorised: group ${config.authRequiredGroup} is required`);
    }
    return buildCurrentUser(identity, config);
  }
  return currentUserFromHeaders(headers, config);
};
