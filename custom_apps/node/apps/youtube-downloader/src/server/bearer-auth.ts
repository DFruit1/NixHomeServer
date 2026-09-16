import { normaliseUsername, type Identity } from './identity.js';

export class BearerAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'BearerAuthError';
  }
}

export type SignatureAlgorithm = 'ES256' | 'RS256';

export type JsonWebKeyLike = {
  kty?: string;
  kid?: string;
  alg?: string;
  use?: string;
  [claim: string]: unknown;
};

type JwtHeader = {
  alg?: unknown;
  kid?: unknown;
  typ?: unknown;
};

type JwtPayload = Record<string, unknown>;

// The server compiles against the ES2022 lib without DOM types, so name the
// WebCrypto handles through their global constructors and a narrow facade.
type WebCryptoKey = InstanceType<typeof CryptoKey>;

type SubtleFacade = {
  importKey: (
    format: 'jwk',
    keyData: JsonWebKeyLike,
    algorithm: Record<string, unknown>,
    extractable: boolean,
    keyUsages: string[],
  ) => Promise<WebCryptoKey>;
  verify: (
    algorithm: Record<string, unknown>,
    key: WebCryptoKey,
    signature: Uint8Array,
    data: Uint8Array,
  ) => Promise<boolean>;
};

const subtle = crypto.subtle as unknown as SubtleFacade;

type AlgorithmParameters = {
  importParams: Record<string, unknown>;
  verifyParams: Record<string, unknown>;
};

const algorithmParameters: Record<SignatureAlgorithm, AlgorithmParameters> = {
  ES256: {
    importParams: { name: 'ECDSA', namedCurve: 'P-256' },
    verifyParams: { name: 'ECDSA', hash: 'SHA-256' },
  },
  RS256: {
    importParams: { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    verifyParams: { name: 'RSASSA-PKCS1-v1_5' },
  },
};

export const importVerificationKey = (
  algorithm: SignatureAlgorithm,
  jwk: JsonWebKeyLike,
): Promise<WebCryptoKey> =>
  subtle.importKey('jwk', jwk, algorithmParameters[algorithm].importParams, false, [ 'verify' ]);

const decodeJsonSegment = <T>(segment: string): T => {
  let decoded: string;
  try {
    decoded = Buffer.from(segment, 'base64url').toString('utf8');
  } catch {
    throw new BearerAuthError('invalid authenticated user token');
  }
  try {
    return JSON.parse(decoded) as T;
  } catch {
    throw new BearerAuthError('invalid authenticated user token');
  }
};

const isSignatureAlgorithm = (value: unknown): value is SignatureAlgorithm =>
  value === 'ES256' || value === 'RS256';

const claimString = (value: unknown): string | undefined =>
  typeof value === 'string' && value.trim() ? value : undefined;

const claimGroups = (value: unknown): string[] => {
  if (Array.isArray(value)) {
    return value.filter((entry): entry is string => typeof entry === 'string' && entry.trim() !== '');
  }
  if (typeof value === 'string') {
    return value.split(/[,\s]+/).map((entry) => entry.trim()).filter(Boolean);
  }
  return [];
};

const audienceMatches = (audience: unknown, expected: string): boolean => {
  if (typeof audience === 'string') {
    return audience === expected;
  }
  if (Array.isArray(audience)) {
    return audience.includes(expected);
  }
  return false;
};

export type VerifyBearerOptions = {
  issuer: string;
  audience: string;
  groupsClaim?: string;
  now?: number;
  clockToleranceSeconds?: number;
  getKey: (kid: string | undefined, algorithm: SignatureAlgorithm) => Promise<WebCryptoKey>;
};

export const verifyBearerToken = async (token: string, options: VerifyBearerOptions): Promise<Identity> => {
  const segments = token.split('.');
  if (segments.length !== 3) {
    throw new BearerAuthError('invalid authenticated user token');
  }
  const [ encodedHeader, encodedPayload, encodedSignature ] = segments;
  const header = decodeJsonSegment<JwtHeader>(encodedHeader);
  if (!isSignatureAlgorithm(header.alg)) {
    throw new BearerAuthError('invalid authenticated user token algorithm');
  }
  const kid = typeof header.kid === 'string' ? header.kid : undefined;
  const key = await options.getKey(kid, header.alg);
  const valid = await subtle.verify(
    algorithmParameters[header.alg].verifyParams,
    key,
    Buffer.from(encodedSignature, 'base64url'),
    Buffer.from(`${encodedHeader}.${encodedPayload}`),
  );
  if (!valid) {
    throw new BearerAuthError('invalid authenticated user token signature');
  }

  const payload = decodeJsonSegment<JwtPayload>(encodedPayload);
  const now = options.now ?? Math.floor(Date.now() / 1000);
  const tolerance = options.clockToleranceSeconds ?? 0;

  const issuerClaim = payload.iss;
  if (claimString(issuerClaim) !== options.issuer) {
    throw new BearerAuthError('invalid authenticated user token issuer');
  }
  if (!audienceMatches(payload.aud, options.audience)) {
    throw new BearerAuthError('invalid authenticated user token audience');
  }
  if (typeof payload.exp === 'number' && now >= payload.exp + tolerance) {
    throw new BearerAuthError('expired authenticated user token');
  }
  if (typeof payload.nbf === 'number' && now + tolerance < payload.nbf) {
    throw new BearerAuthError('inactive authenticated user token');
  }

  const username = normaliseUsername(
    claimString(payload.preferred_username)
    ?? claimString(payload.name)
    ?? claimString(payload.email),
  );
  if (!username) {
    throw new BearerAuthError('authenticated user token has no usable username');
  }

  return {
    username,
    email: claimString(payload.email),
    groups: claimGroups(payload[options.groupsClaim ?? 'groups']),
  };
};

export type KeyProvider = (kid: string | undefined, algorithm: SignatureAlgorithm) => Promise<WebCryptoKey>;

type CacheEntry<T> = {
  value: T;
  expiresAt: number;
};

export type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

export type JwksKeyProviderOptions = {
  issuer: string;
  fetchImpl?: FetchLike;
  ttlSeconds?: number;
  now?: () => number;
};

type JsonWebKeySet = {
  keys?: JsonWebKeyLike[];
};

type OpenIdConfiguration = {
  jwks_uri?: string;
};

export const createJwksKeyProvider = (options: JwksKeyProviderOptions): KeyProvider => {
  const fetchImpl = options.fetchImpl ?? ((url, init) => fetch(url, init));
  const ttlMs = (options.ttlSeconds ?? 600) * 1000;
  const now = options.now ?? (() => Date.now());
  const issuer = options.issuer.replace(/\/+$/, '');
  const jwksUriCache = new Map<string, CacheEntry<Promise<string>>>();
  const keyCache = new Map<string, CacheEntry<Promise<WebCryptoKey>>>();

  const fetchJson = async <T>(url: string): Promise<T> => {
    const response = await fetchImpl(url, { headers: { accept: 'application/json' } });
    if (!response.ok) {
      throw new BearerAuthError(`failed to fetch ${url} (${response.status})`);
    }
    return response.json() as Promise<T>;
  };

  const resolveJwksUri = (): Promise<string> => {
    const cached = jwksUriCache.get(issuer);
    if (cached && cached.expiresAt > now()) {
      return cached.value;
    }
    const pending = fetchJson<OpenIdConfiguration>(`${issuer}/.well-known/openid-configuration`)
      .then((document) => {
        if (!document.jwks_uri) {
          throw new BearerAuthError('authenticated user issuer discovery has no jwks_uri');
        }
        return document.jwks_uri;
      });
    pending.catch(() => jwksUriCache.delete(issuer));
    jwksUriCache.set(issuer, { value: pending, expiresAt: now() + ttlMs });
    return pending;
  };

  return async (kid, algorithm) => {
    const cacheKey = `${algorithm}:${kid ?? '-'}`;
    const cached = keyCache.get(cacheKey);
    if (cached && cached.expiresAt > now()) {
      return cached.value;
    }
    const pending = (async () => {
      const jwksUri = await resolveJwksUri();
      const document = await fetchJson<JsonWebKeySet>(jwksUri);
      const keys = (document.keys ?? []).filter((key) => key.kty);
      const jwk = kid ? keys.find((key) => key.kid === kid) : keys[0];
      if (!jwk) {
        throw new BearerAuthError('authenticated user signing key not found');
      }
      return importVerificationKey(algorithm, jwk);
    })();
    pending.catch(() => keyCache.delete(cacheKey));
    keyCache.set(cacheKey, { value: pending, expiresAt: now() + ttlMs });
    return pending;
  };
};
