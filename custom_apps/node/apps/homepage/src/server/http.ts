import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
import { enrollOfflineMediaDevice, getOfflineMediaSetup, OfflineMediaInputError, removeOfflineMediaDevice } from './offlineMedia.js';
import { installSftpPublicKey, normalisePublicKey } from './sftpKey.js';
import { assertFeatureAccess, buildHomepageData } from './homepageData.js';
import { getCanaryFailure, getCanaryStatus, triggerCanary } from './canary.js';

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};
const MAX_JSON_BODY_BYTES = 64 * 1024;

export const handleRequest = async (config: AppConfig, request: IncomingMessage, response: ServerResponse): Promise<void> => {
  if (await handleApiRequest(config, request, response)) {
    return;
  }
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  try {
    await serveStatic(config, response, url.pathname);
  } catch (error) {
    if (error instanceof URIError && !response.destroyed && !response.writableEnded) {
      sendJson(response, 400, { error: error.message });
      return;
    }
    throw error;
  }
};

export const handleApiRequest = async (config: AppConfig, request: IncomingMessage, response: ServerResponse): Promise<boolean> => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  try {
    if (request.method === 'GET' && url.pathname === '/healthz') {
      sendJson(response, 200, { ok: true });
      return true;
    }

    if (request.method === 'GET' && url.pathname === '/api/home') {
      sendJson(response, 200, await buildHomepageData(config, request.headers));
      return true;
    }

    if (request.method === 'GET' && url.pathname === '/api/canary') {
      sendJson(response, 200, await getCanaryStatus(config, request.headers));
      return true;
    }

    if (request.method === 'POST' && url.pathname === '/api/canary/run') {
      await readMutationJson<Record<string, never>>(request);
      sendJson(response, 202, await triggerCanary(config, request.headers));
      return true;
    }

    if (request.method === 'GET' && url.pathname.startsWith('/api/canary/failures/')) {
      const runId = decodeURIComponent(url.pathname.slice('/api/canary/failures/'.length));
      sendJson(response, 200, await getCanaryFailure(config, request.headers, runId));
      return true;
    }

    if (request.method === 'POST' && url.pathname === '/api/sftp-key') {
      const body = await readMutationJson<{ publicKey?: string }>(request);
      const user = currentUserFromHeaders(request.headers, config.devUser);
      if (!config.homepage.sftp?.enabled) {
        throw new Error('SFTP access is not enabled');
      }
      assertFeatureAccess(user, config.homepage.sftp.requiredAllGroups, config.homepage.sftp.requiredAnyGroups);
      const publicKey = normalisePublicKey(body.publicKey);
      sendJson(response, 200, await installSftpPublicKey(config, user, publicKey));
      return true;
    }

    if (request.method === 'GET' && (url.pathname === '/api/offline-media' || url.pathname === '/api/offline-music')) {
      const user = currentUserFromHeaders(request.headers, config.devUser);
      if (!config.homepage.offlineMedia?.enabled) {
        throw new Error('offline media access is not enabled');
      }
      assertFeatureAccess(user, config.homepage.offlineMedia?.requiredAllGroups, config.homepage.offlineMedia?.requiredAnyGroups);
      sendJson(response, 200, await getOfflineMediaSetup(config, user));
      return true;
    }

    if (request.method === 'POST' && (url.pathname === '/api/offline-media/devices' || url.pathname === '/api/offline-music/device')) {
      const body = await readMutationJson<{ deviceId?: string; deviceName?: string }>(request);
      const user = currentUserFromHeaders(request.headers, config.devUser);
      if (!config.homepage.offlineMedia?.enabled) {
        throw new Error('offline media access is not enabled');
      }
      assertFeatureAccess(user, config.homepage.offlineMedia?.requiredAllGroups, config.homepage.offlineMedia?.requiredAnyGroups);
      sendJson(response, 200, await enrollOfflineMediaDevice(config, user, body));
      return true;
    }

    if (request.method === 'DELETE' && url.pathname.startsWith('/api/offline-media/devices/')) {
      await readMutationJson<Record<string, never>>(request);
      const user = currentUserFromHeaders(request.headers, config.devUser);
      if (!config.homepage.offlineMedia?.enabled) {
        throw new Error('offline media access is not enabled');
      }
      assertFeatureAccess(user, config.homepage.offlineMedia?.requiredAllGroups, config.homepage.offlineMedia?.requiredAnyGroups);
      const deviceId = decodeURIComponent(url.pathname.slice('/api/offline-media/devices/'.length));
      sendJson(response, 200, await removeOfflineMediaDevice(config, user, deviceId));
      return true;
    }

    if (url.pathname.startsWith('/api/')) {
      sendJson(response, 404, { error: 'api route not found' });
      return true;
    }

    return false;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.includes('authenticated user') ? 401
      : message.includes('not authorised') ? 403
        : message.includes('content type') ? 415
          : message.includes('too large') ? 413
            : error instanceof SyntaxError || error instanceof URIError || error instanceof OfflineMediaInputError ? 400
              : message.startsWith('public key ') || message.startsWith('publicKey ')
                || message === 'invalid OpenSSH public key'
                || message === 'invalid or corrupted OpenSSH public key' ? 400
                : message.includes('already active') ? 409
                  : message.includes('not found') || message.includes('not enabled') ? 404
                    : 500;
    if (!response.destroyed && !response.writableEnded) {
      if (response.headersSent) {
        response.destroy(error instanceof Error ? error : undefined);
      } else {
        sendJson(response, status, { error: message });
      }
    }
    return true;
  }
};

const assertSameOrigin = (request: IncomingMessage): void => {
  const fetchSite = headerValue(request.headers['sec-fetch-site']);
  if (fetchSite && fetchSite !== 'same-origin') {
    throw new Error('not authorised: request is not same-origin');
  }
  const origin = headerValue(request.headers.origin, false);
  const host = headerValue(request.headers.host, false);
  if (!origin || !host) {
    throw new Error('not authorised: origin and host headers are required');
  }
  let parsedOrigin: URL;
  try {
    parsedOrigin = new URL(origin);
  } catch {
    throw new Error('not authorised: invalid origin');
  }
  if (parsedOrigin.origin !== origin || !['http:', 'https:'].includes(parsedOrigin.protocol) || parsedOrigin.host.toLowerCase() !== host.toLowerCase()) {
    throw new Error('not authorised: origin mismatch');
  }
  const forwardedProtocol = headerValue(request.headers['x-forwarded-proto']);
  if (forwardedProtocol && `${forwardedProtocol.toLowerCase()}:` !== parsedOrigin.protocol) {
    throw new Error('not authorised: origin protocol mismatch');
  }
};

const readMutationJson = async <T>(request: IncomingMessage): Promise<T> => {
  assertSameOrigin(request);
  const contentType = headerValue(request.headers['content-type'], false)?.split(';', 1)[0]?.trim().toLowerCase();
  if (contentType !== 'application/json') {
    throw new Error('JSON content type is required');
  }
  const text = await readBoundedBody(request);
  const parsed = text ? (JSON.parse(text) as unknown) : {};
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new SyntaxError('JSON request body must be an object');
  }
  return parsed as T;
};

const readBoundedBody = async (request: IncomingMessage): Promise<string> => {
  const declaredLength = headerValue(request.headers['content-length'], false);
  if (declaredLength && Number(declaredLength) > MAX_JSON_BODY_BYTES) {
    request.resume();
    throw new Error('request body is too large');
  }
  return new Promise<string>((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    const cleanup = () => {
      request.off('data', onData);
      request.off('end', onEnd);
      request.off('aborted', onAborted);
      request.off('error', onError);
    };
    const fail = (error: Error) => {
      cleanup();
      request.resume();
      reject(error);
    };
    const onData = (chunk: Buffer | string) => {
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      size += buffer.length;
      if (size > MAX_JSON_BODY_BYTES) {
        fail(new Error('request body is too large'));
        return;
      }
      chunks.push(buffer);
    };
    const onEnd = () => {
      cleanup();
      resolve(Buffer.concat(chunks).toString('utf8'));
    };
    const onAborted = () => fail(new Error('request body was aborted'));
    const onError = (error: Error) => fail(error);
    request.on('data', onData);
    request.on('end', onEnd);
    request.on('aborted', onAborted);
    request.on('error', onError);
  });
};

const headerValue = (value: string | string[] | undefined, firstListValue = true): string | undefined => {
  if (Array.isArray(value)) {
    return value.length === 1 ? value[0]?.trim() : undefined;
  }
  if (!value) {
    return undefined;
  }
  return (firstListValue ? value.split(',', 1)[0] : value).trim();
};

const sendJson = (response: ServerResponse, status: number, value: unknown): void => {
  response.statusCode = status;
  response.setHeader('content-type', 'application/json; charset=utf-8');
  response.end(JSON.stringify(value));
};

export const tryServeStaticAsset = async (config: AppConfig, response: ServerResponse, rawPath: string): Promise<boolean> => {
  const requested = rawPath === '/' ? '/index.html' : rawPath;
  const candidate = path.resolve(config.staticDir, `.${decodeURIComponent(requested)}`);
  const root = path.resolve(config.staticDir);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
    return false;
  }
  try {
    const file = await stat(candidate);
    if (!file.isFile()) {
      return false;
    }
    response.statusCode = 200;
    response.setHeader('content-type', CONTENT_TYPES[path.extname(candidate)] ?? 'application/octet-stream');
    createReadStream(candidate).pipe(response);
    return true;
  } catch {
    return false;
  }
};

const serveStatic = async (config: AppConfig, response: ServerResponse, rawPath: string): Promise<void> => {
  if (await tryServeStaticAsset(config, response, rawPath)) {
    return;
  }

  try {
    const index = await readFile(path.join(config.staticDir, 'index.html'));
    response.statusCode = 200;
    response.setHeader('content-type', 'text/html; charset=utf-8');
    response.end(index);
  } catch {
    throw new Error('static path not found');
  }
};
