import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';

export const JSON_CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.gif': 'image/gif',
  '.html': 'text/html; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.wasm': 'application/wasm',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
};

export const MAX_JSON_BODY_BYTES = 64 * 1024;

export const headerValue = (value: string | string[] | undefined, firstListValue = true): string | undefined => {
  if (Array.isArray(value)) {
    return value.length === 1 ? value[0]?.trim() : undefined;
  }
  if (!value) {
    return undefined;
  }
  return (firstListValue ? value.split(',', 1)[0] : value).trim();
};

export const assertSameOrigin = (request: IncomingMessage): void => {
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
};

export const readBoundedBody = async (request: IncomingMessage, maxBytes = MAX_JSON_BODY_BYTES): Promise<string> => {
  const declaredLength = headerValue(request.headers['content-length'], false);
  if (declaredLength && Number(declaredLength) > maxBytes) {
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
      if (size > maxBytes) {
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

export const readMutationJson = async <T>(request: IncomingMessage, maxBytes = MAX_JSON_BODY_BYTES): Promise<T> => {
  assertSameOrigin(request);
  const contentType = headerValue(request.headers['content-type'], false)?.split(';', 1)[0]?.trim().toLowerCase();
  if (contentType !== 'application/json') {
    throw new Error('JSON content type is required');
  }
  const text = await readBoundedBody(request, maxBytes);
  const parsed = text ? (JSON.parse(text) as unknown) : {};
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new SyntaxError('JSON request body must be an object');
  }
  return parsed as T;
};

export const sendJson = (response: ServerResponse, status: number, value: unknown): void => {
  response.statusCode = status;
  if (status === 204) {
    response.end();
    return;
  }
  response.setHeader('content-type', 'application/json; charset=utf-8');
  response.end(JSON.stringify(value));
};

export type StaticAssetOptions = {
  requireFileExtension?: boolean;
  mapRootToIndex?: boolean;
};

export const tryServeStaticAsset = async (
  staticDir: string,
  response: ServerResponse,
  rawPath: string,
  options: StaticAssetOptions = {},
): Promise<boolean> => {
  const requested = options.mapRootToIndex === false ? rawPath : rawPath === '/' ? '/index.html' : rawPath;
  const extension = path.extname(requested);
  if (options.requireFileExtension && !extension) {
    return false;
  }
  const candidate = path.resolve(staticDir, `.${decodeURIComponent(requested)}`);
  const root = path.resolve(staticDir);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
    return false;
  }
  try {
    const file = await stat(candidate);
    if (!file.isFile()) {
      return false;
    }
    response.statusCode = 200;
    response.setHeader('content-type', JSON_CONTENT_TYPES[extension] ?? 'application/octet-stream');
    createReadStream(candidate).pipe(response);
    return true;
  } catch {
    return false;
  }
};

export const serveStaticWithSpaFallback = async (
  staticDir: string,
  response: ServerResponse,
  rawPath: string,
  options: StaticAssetOptions = {},
): Promise<void> => {
  const requested = rawPath === '/' ? '/index.html' : rawPath;
  const candidate = path.resolve(staticDir, `.${decodeURIComponent(requested)}`);
  const root = path.resolve(staticDir);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
    throw new Error('static path not found');
  }
  if (await tryServeStaticAsset(staticDir, response, rawPath, options)) {
    return;
  }
  try {
    const index = await readFile(path.join(staticDir, 'index.html'));
    response.statusCode = 200;
    response.setHeader('content-type', 'text/html; charset=utf-8');
    response.end(index);
  } catch {
    throw new Error('static path not found');
  }
};
