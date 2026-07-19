import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import type { AppConfig } from './config.js';
import type { Database } from './db.js';
import { csvHeader, messageToCsvRow, messageToJsonlRow } from './export.js';
import type { MqttBridge } from './mqttBridge.js';
import { commandPresets } from './presets.js';
import type { Direction, MessageFilters, PublishRequest } from '../shared/types.js';

const CONTENT_TYPES: Record<string, string> = {
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};
const MAX_JSON_BODY_BYTES = 64 * 1024;

export type ServerContext = {
  config: AppConfig;
  db: Database;
  mqttBridge: MqttBridge;
};

export const handleApiRequest = async (
  context: ServerContext,
  request: IncomingMessage,
  response: ServerResponse,
): Promise<boolean> => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  if (request.method === 'GET' && url.pathname === '/healthz') {
    sendJson(response, 200, { ok: true });
    return true;
  }
  if (!url.pathname.startsWith('/api/')) {
    return false;
  }

  try {
    await handleApi(context, request, response, url);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message.includes('not authorised') ? 403
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
  return true;
};

const handleApi = async (
  { config, db, mqttBridge }: ServerContext,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
): Promise<void> => {
  if (request.method === 'GET' && url.pathname === '/api/status') {
    sendJson(response, 200, await mqttBridge.status());
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/topics') {
    sendJson(response, 200, {
      subscribedTopics: config.mqttSubscribeTopics,
      observedTopics: await db.observedTopics(),
    });
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/presets') {
    sendJson(response, 200, commandPresets);
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/messages') {
    sendJson(response, 200, await db.listMessages(filtersFromUrl(url)));
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/messages/export') {
    const filters = filtersFromUrl(url);
    const format = url.searchParams.get('format') === 'jsonl' ? 'jsonl' : 'csv';
    response.statusCode = 200;
    response.setHeader('content-type', format === 'jsonl' ? 'application/x-ndjson; charset=utf-8' : 'text/csv; charset=utf-8');
    response.setHeader('content-disposition', `attachment; filename="groundwater-mqtt-${new Date().toISOString()}.${format}"`);
    if (format === 'csv' && !(await writeChunk(response, csvHeader()))) {
      return;
    }
    for (const message of db.iterateMessages(filters)) {
      const chunk = format === 'jsonl' ? messageToJsonlRow(message) : messageToCsvRow(message);
      if (!(await writeChunk(response, chunk))) {
        return;
      }
    }
    if (!response.destroyed && !response.writableEnded) {
      response.end();
    }
    return;
  }

  if (request.method === 'GET' && url.pathname === '/api/events') {
    response.statusCode = 200;
    response.setHeader('content-type', 'text/event-stream; charset=utf-8');
    response.setHeader('cache-control', 'no-cache, no-transform');
    response.setHeader('connection', 'keep-alive');
    response.flushHeaders?.();
    const send = (value: unknown) => {
      response.write(`data: ${JSON.stringify(value)}\n\n`);
    };
    const unsubscribe = mqttBridge.onEvent(send);
    const heartbeat = setInterval(() => response.write(': heartbeat\n\n'), 30000);
    request.on('close', () => {
      clearInterval(heartbeat);
      unsubscribe();
      response.end();
    });
    return;
  }

  if (request.method === 'POST' && url.pathname === '/api/publish') {
    const body = await readMutationJson<PublishRequest>(request);
    const message = await mqttBridge.publish(body);
    sendJson(response, 201, { ok: true, messageId: message.id });
    return;
  }

  throw new Error('api route not found');
};

const filtersFromUrl = (url: URL): MessageFilters => {
  const direction = url.searchParams.get('direction');
  return {
    topic: url.searchParams.get('topic') || undefined,
    direction: direction === 'inbound' || direction === 'outbound' ? (direction as Direction) : undefined,
    from: url.searchParams.get('from') || undefined,
    to: url.searchParams.get('to') || undefined,
    search: url.searchParams.get('search') || undefined,
    limit: numberParam(url, 'limit'),
    offset: numberParam(url, 'offset'),
  };
};

const numberParam = (url: URL, key: string): number | undefined => {
  const raw = url.searchParams.get(key);
  if (!raw) {
    return undefined;
  }
  const value = Number.parseInt(raw, 10);
  return Number.isFinite(value) ? value : undefined;
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

const writeChunk = async (response: ServerResponse, chunk: string): Promise<boolean> => {
  if (response.destroyed || response.writableEnded) {
    return false;
  }
  if (response.write(chunk)) {
    return true;
  }
  return new Promise<boolean>((resolve) => {
    const cleanup = () => {
      response.off('drain', onDrain);
      response.off('close', onTermination);
      response.off('error', onTermination);
    };
    const onDrain = () => {
      cleanup();
      resolve(true);
    };
    const onTermination = () => {
      cleanup();
      resolve(false);
    };
    response.once('drain', onDrain);
    response.once('close', onTermination);
    response.once('error', onTermination);
    if (response.destroyed || response.writableEnded) {
      onTermination();
    }
  });
};

const sendJson = (response: ServerResponse, status: number, value: unknown): void => {
  response.statusCode = status;
  response.setHeader('content-type', 'application/json; charset=utf-8');
  response.end(JSON.stringify(value));
};

export const tryServeStaticAsset = async (config: AppConfig, response: ServerResponse, rawPath: string): Promise<boolean> => {
  const ext = path.extname(rawPath);
  if (!ext) {
    return false;
  }
  const candidate = path.resolve(config.staticDir, `.${decodeURIComponent(rawPath)}`);
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
    response.setHeader('content-type', CONTENT_TYPES[ext] ?? 'application/octet-stream');
    createReadStream(candidate).pipe(response);
    return true;
  } catch {
    if (rawPath === '/index.html') {
      const index = await readFile(path.join(config.staticDir, 'index.html'));
      response.statusCode = 200;
      response.setHeader('content-type', 'text/html; charset=utf-8');
      response.end(index);
      return true;
    }
    return false;
  }
};
