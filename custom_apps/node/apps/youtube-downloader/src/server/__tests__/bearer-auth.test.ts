import { generateKeyPairSync, sign as signBytes } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  BearerAuthError,
  createJwksKeyProvider,
  importVerificationKey,
  verifyBearerToken,
  type FetchLike,
  type JsonWebKeyLike,
  type SignatureAlgorithm,
} from '../bearer-auth.js';

const issuer = 'https://id.example.test/oauth2/openid/youtube-downloader-app';
const audience = 'youtube-downloader-app';

const b64url = (input: string): string => Buffer.from(input).toString('base64url');

const makeSigner = (algorithm: SignatureAlgorithm) => {
  const pair = algorithm === 'ES256'
    ? generateKeyPairSync('ec', { namedCurve: 'P-256' })
    : generateKeyPairSync('rsa', { modulusLength: 2048 });
  const jwk = pair.publicKey.export({ format: 'jwk' }) as unknown as JsonWebKeyLike;
  const verificationKey = importVerificationKey(algorithm, jwk);
  const signToken = (header: Record<string, unknown>, payload: Record<string, unknown>): string => {
    const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
    const signature = algorithm === 'ES256'
      ? signBytes('sha256', Buffer.from(signingInput), { key: pair.privateKey, dsaEncoding: 'ieee-p1363' })
      : signBytes('sha256', Buffer.from(signingInput), pair.privateKey);
    return `${signingInput}.${signature.toString('base64url')}`;
  };
  return { jwk, verificationKey, signToken };
};

const basePayload = (overrides: Record<string, unknown> = {}): Record<string, unknown> => ({
  iss: issuer,
  aud: audience,
  exp: Math.floor(Date.now() / 1000) + 300,
  preferred_username: 'dsaw@example.test',
  email: 'dsaw@example.test',
  groups: [ 'downloads-users', 'files-shared-users' ],
  ...overrides,
});

describe('bearer token verification', () => {
  it('accepts a signed token and returns the identity', async () => {
    const signer = makeSigner('ES256');
    const token = signer.signToken({ alg: 'ES256', kid: 'k1' }, basePayload());

    await expect(
      verifyBearerToken(token, { issuer, audience, getKey: async () => signer.verificationKey }),
    ).resolves.toEqual({
      username: 'dsaw',
      email: 'dsaw@example.test',
      groups: [ 'downloads-users', 'files-shared-users' ],
    });
  });

  it('parses a whitespace separated groups claim', async () => {
    const signer = makeSigner('ES256');
    const token = signer.signToken({ alg: 'ES256' }, basePayload({ groups: 'downloads-users users' }));

    const identity = await verifyBearerToken(token, { issuer, audience, getKey: async () => signer.verificationKey });
    expect(identity.groups).toEqual([ 'downloads-users', 'users' ]);
  });

  it('rejects a token for another audience', async () => {
    const signer = makeSigner('ES256');
    const token = signer.signToken({ alg: 'ES256' }, basePayload({ aud: 'some-other-client' }));

    await expect(
      verifyBearerToken(token, { issuer, audience, getKey: async () => signer.verificationKey }),
    ).rejects.toBeInstanceOf(BearerAuthError);
  });

  it('rejects a token from another issuer', async () => {
    const signer = makeSigner('ES256');
    const token = signer.signToken({ alg: 'ES256' }, basePayload({ iss: 'https://evil.example.test' }));

    await expect(
      verifyBearerToken(token, { issuer, audience, getKey: async () => signer.verificationKey }),
    ).rejects.toBeInstanceOf(BearerAuthError);
  });

  it('rejects an expired token', async () => {
    const signer = makeSigner('ES256');
    const token = signer.signToken({ alg: 'ES256' }, basePayload({ exp: Math.floor(Date.now() / 1000) - 10 }));

    await expect(
      verifyBearerToken(token, { issuer, audience, getKey: async () => signer.verificationKey }),
    ).rejects.toBeInstanceOf(BearerAuthError);
  });

  it('rejects a token signed by another key', async () => {
    const signer = makeSigner('ES256');
    const other = makeSigner('ES256');
    const token = signer.signToken({ alg: 'ES256' }, basePayload());

    await expect(
      verifyBearerToken(token, { issuer, audience, getKey: async () => other.verificationKey }),
    ).rejects.toBeInstanceOf(BearerAuthError);
  });

  it('rejects an unsupported algorithm', async () => {
    const signer = makeSigner('ES256');
    const token = signer.signToken({ alg: 'none' }, basePayload());

    await expect(
      verifyBearerToken(token, { issuer, audience, getKey: async () => signer.verificationKey }),
    ).rejects.toBeInstanceOf(BearerAuthError);
  });
});

describe('jwks key provider', () => {
  it('resolves a signing key through issuer discovery and verifies with it', async () => {
    const signer = makeSigner('ES256');
    const keyWithId: JsonWebKeyLike = { ...signer.jwk, kid: 'k1' };

    const requested: string[] = [];
    const fetchImpl: FetchLike = async (url) => {
      requested.push(url);
      if (url.endsWith('/.well-known/openid-configuration')) {
        return new Response(JSON.stringify({ jwks_uri: `${issuer}/.well-known/jwks.json` }), { status: 200 });
      }
      return new Response(JSON.stringify({ keys: [ keyWithId ] }), { status: 200 });
    };

    const provider = createJwksKeyProvider({ issuer, fetchImpl });
    const token = signer.signToken({ alg: 'ES256', kid: 'k1' }, basePayload());

    await expect(verifyBearerToken(token, { issuer, audience, getKey: provider })).resolves.toMatchObject({
      username: 'dsaw',
    });
    expect(requested).toEqual([
      `${issuer}/.well-known/openid-configuration`,
      `${issuer}/.well-known/jwks.json`,
    ]);
  });

  it('imports an RS256 key without a kid', async () => {
    const signer = makeSigner('RS256');
    const key = await importVerificationKey('RS256', signer.jwk);
    expect(key.type).toBe('public');
  });
});
