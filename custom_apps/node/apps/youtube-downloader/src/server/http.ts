import { constants, createReadStream } from 'node:fs';
import { lstat, open, readFile, realpath, stat, type FileHandle } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { AppConfig } from './config.js';
import { currentUserFromHeaders } from './auth.js';
import { Database } from './db.js';
import { JobQueue, validateDownloadUrl } from './queue.js';
import { normalizeDownloadUrl } from '../shared/url.js';
import type { CreateJobRequest } from '../shared/types.js';

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.webp': 'image/webp',
};
const MAX_JSON_BODY_BYTES = 64 * 1024;

export type ServerContext = {
  config: AppConfig;
  db: Database;
  queue: JobQueue;
};

export const handleRequest = async (context: ServerContext, request: IncomingMessage, response: ServerResponse): Promise<void> => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  try {
    if (request.method === 'GET' && url.pathname === '/healthz') {
      sendJson(response, 200, { ok: true });
      return;
    }
    if (url.pathname.startsWith('/api/')) {
      await handleApi(context, request, response, url);
      return;
    }
    await serveStatic(context.config, response, url.pathname);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.includes('authenticated user') ? 401
      : message.includes('not authorised') ? 403
        : message.includes('content type') ? 415
          : message.includes('too large') ? 413
            : message.includes('not found') ? 404
              : 400;
    if (!response.destroyed && !response.writableEnded) {
      if (response.headersSent) {
        response.destroy(error instanceof Error ? error : undefined);
      } else {
        sendJson(response, status, { error: message });
      }
    }
  }
};

const handleApi = async (
  { config, db, queue }: ServerContext,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
): Promise<void> => {
  const mutationBody = request.method === 'POST' || request.method === 'DELETE'
    ? await readMutationJson<unknown>(request)
    : undefined;
  const user = currentUserFromHeaders(request.headers, config);

  if (request.method === 'GET' && url.pathname === '/api/me') {
    sendJson(response, 200, user);
    return;
  }

  if (request.method === 'POST' && url.pathname === '/api/probe') {
    const body = mutationBody as { url?: string };
    if (!body.url) {
      throw new Error('url is required');
    }
    const normalizedUrl = normalizeDownloadUrl(body.url);
    validateDownloadUrl(normalizedUrl);
    sendJson(response, 200, await queue.probe(normalizedUrl));
    return;
  }

  if (request.method === 'POST' && url.pathname === '/api/jobs') {
    const body = mutationBody as CreateJobRequest;
    const jobId = await queue.enqueue(user, body);
    sendJson(response, 201, { jobIds: [jobId] });
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/jobs') {
    sendJson(response, 200, await db.listJobs(user.username));
    return;
  }

  if (request.method === 'DELETE' && url.pathname === '/api/jobs') {
    await db.clearHistory(user.username);
    sendJson(response, 204, {});
    return;
  }

  const jobFileMatch = /^\/api\/jobs\/([^/]+)\/files\/(\d+)$/.exec(url.pathname);
  if (request.method === 'GET' && jobFileMatch) {
    const [, jobId, rawIndex] = jobFileMatch;
    await serveJobFile(db, response, jobId, Number(rawIndex), user.username);
    return;
  }

  const jobMatch = /^\/api\/jobs\/([^/]+)(?:\/([^/]+))?$/.exec(url.pathname);
  if (jobMatch) {
    const [, jobId, action] = jobMatch;
    if (request.method === 'GET' && !action) {
      const job = await db.getJobForUser(jobId, user.username);
      if (!job) {
        throw new Error('job not found');
      }
      sendJson(response, 200, job);
      return;
    }
    if (request.method === 'POST' && action === 'cancel') {
      await queue.cancel(jobId, user);
      sendJson(response, 200, { ok: true });
      return;
    }
    if (request.method === 'POST' && action === 'retry') {
      sendJson(response, 201, { jobIds: [await queue.retry(jobId, user)] });
      return;
    }
    if (request.method === 'POST' && action === 'resolve-alert') {
      const body = mutationBody as { action?: string };
      if (
        body.action !== 'download-again' &&
        body.action !== 'split-chapters' &&
        body.action !== 'single-file' &&
        body.action !== 'cancel'
      ) {
        throw new Error('invalid alert action');
      }
      await queue.resolveAlert(jobId, body.action, user);
      sendJson(response, 200, { ok: true });
      return;
    }
    if (request.method === 'DELETE' && !action) {
      const job = await db.getJobForUser(jobId, user.username);
      if (!job) {
        throw new Error('job not found');
      }
      await db.deleteJob(jobId, user.username);
      sendJson(response, 204, {});
      return;
    }
  }

  throw new Error('api route not found');
};

const serveJobFile = async (
  db: Database,
  response: ServerResponse,
  jobId: string,
  fileIndex: number,
  username: string,
): Promise<void> => {
  if (!Number.isInteger(fileIndex) || fileIndex < 0) {
    throw new Error('job file not found');
  }
  const job = await db.getJobForUser(jobId, username);
  const relativePath = job?.files[fileIndex];
  if (!job?.outputFolder || !relativePath || !/\.(?:jpe?g|png|webp)$/i.test(relativePath)) {
    throw new Error('job file not found');
  }

  const root = path.resolve(job.outputFolder);
  const candidate = path.resolve(root, relativePath);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
    throw new Error('job file not found');
  }

  const handle = await openVerifiedJobFile(root, candidate);
  try {
    response.statusCode = 200;
    response.setHeader('content-type', CONTENT_TYPES[path.extname(candidate).toLowerCase()] ?? 'application/octet-stream');
    response.setHeader('cache-control', 'private, max-age=3600');
    await pipeline(handle.createReadStream({ autoClose: false }), response);
  } finally {
    await handle.close();
  }
};

const openVerifiedJobFile = async (root: string, candidate: string): Promise<FileHandle> => {
  let handle: FileHandle | undefined;
  try {
    await assertPathHasNoSymlinks(root, candidate);
    const [realRoot, realCandidate] = await Promise.all([realpath(root), realpath(candidate)]);
    if (
      realRoot !== root
      || realCandidate !== candidate
      || (realCandidate !== realRoot && !realCandidate.startsWith(`${realRoot}${path.sep}`))
    ) {
      throw new Error('path is not canonical');
    }
    handle = await open(candidate, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const file = await handle.stat();
    if (!file.isFile()) {
      throw new Error('path is not a regular file');
    }
    return handle;
  } catch {
    await handle?.close().catch(() => undefined);
    throw new Error('job file not found');
  }
};

const assertPathHasNoSymlinks = async (root: string, candidate: string): Promise<void> => {
  const relative = path.relative(root, candidate);
  const segments = relative ? relative.split(path.sep) : [];
  let current = root;
  const rootInfo = await lstat(current);
  if (rootInfo.isSymbolicLink() || !rootInfo.isDirectory()) {
    throw new Error('job file not found');
  }
  for (const [index, segment] of segments.entries()) {
    current = path.join(current, segment);
    const info = await lstat(current);
    if (info.isSymbolicLink() || (index < segments.length - 1 ? !info.isDirectory() : !info.isFile())) {
      throw new Error('job file not found');
    }
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
  if (status === 204) {
    response.end();
    return;
  }
  response.setHeader('content-type', 'application/json; charset=utf-8');
  response.end(JSON.stringify(value));
};

const serveStatic = async (config: AppConfig, response: ServerResponse, rawPath: string): Promise<void> => {
  const requested = rawPath === '/' ? '/index.html' : rawPath;
  const candidate = path.resolve(config.staticDir, `.${decodeURIComponent(requested)}`);
  const root = path.resolve(config.staticDir);
  if (candidate !== root && !candidate.startsWith(`${root}${path.sep}`)) {
    throw new Error('static path not found');
  }
  try {
    const file = await stat(candidate);
    if (!file.isFile()) {
      throw new Error('static path not found');
    }
    response.statusCode = 200;
    response.setHeader('content-type', CONTENT_TYPES[path.extname(candidate)] ?? 'application/octet-stream');
    createReadStream(candidate).pipe(response);
  } catch {
    const index = await readFile(path.join(config.staticDir, 'index.html'));
    response.statusCode = 200;
    response.setHeader('content-type', 'text/html; charset=utf-8');
    response.end(index);
  }
};
