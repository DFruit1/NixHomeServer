import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import path from 'node:path';
import { currentUserFromHeaders } from './auth.js';
import type { AppConfig } from './config.js';
import { enrollOfflineMediaDevice, getOfflineMediaSetup, OfflineMediaInputError, removeOfflineMediaDevice } from './offlineMedia.js';
import { applyBuildMode, getBuildMode, BuildModeInputError } from './buildMode.js';
import { applyPowerSchedule, getPowerSchedule, PowerScheduleInputError } from './power.js';
import { installSftpPublicKey, normalisePublicKey } from './sftpKey.js';
import { assertFeatureAccess, buildHomepageData } from './homepageData.js';
import { getCanaryFailure, getCanaryStatus, triggerCanary } from './canary.js';
import { getMkvProgress } from './mkvmaker.js';
import {
  VaultHttpError,
  buildVaultStatus,
  vaultFreshrssPassword,
  vaultKavitaKeysGet,
  vaultKavitaKeysMutate,
  vaultLock,
  vaultSshKeyAdd,
  vaultSshKeys,
  vaultSyncthingKeyGet,
  vaultSyncthingKeyRotate,
  vaultUnlock,
  type VaultHttpResponse,
} from './vault.js';
import { clearVaultSessionCookie, setVaultSessionCookie } from './vaultSession.js';
import {
  readMutationJson,
  sendJson,
  serveStaticWithSpaFallback,
  tryServeStaticAsset as tryServeStaticFile,
} from '../shared/node-common/http-protocol.js';

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
    if (await handleVaultApiRequest(config, request, response, url.pathname)) {
      return true;
    }

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

    if (request.method === 'GET' && url.pathname === '/api/mkvmaker/progress') {
      sendJson(response, 200, await getMkvProgress(config, request.headers));
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

    if (request.method === 'GET' && url.pathname === '/api/power-schedule') {
      sendJson(response, 200, await getPowerSchedule(config, request.headers));
      return true;
    }

    if (request.method === 'POST' && url.pathname === '/api/power-schedule') {
      const body = await readMutationJson<unknown>(request);
      sendJson(response, 200, await applyPowerSchedule(config, request.headers, body));
      return true;
    }

    if (request.method === 'GET' && url.pathname === '/api/build-mode') {
      sendJson(response, 200, await getBuildMode(config, request.headers));
      return true;
    }

    if (request.method === 'POST' && url.pathname === '/api/build-mode') {
      const body = await readMutationJson<unknown>(request);
      sendJson(response, 200, await applyBuildMode(config, request.headers, body));
      return true;
    }

    if (url.pathname.startsWith('/api/')) {
      sendJson(response, 404, { error: 'api route not found' });
      return true;
    }

    return false;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = vaultHttpErrorStatus(error) ?? (message.includes('authenticated user') ? 401
      : message.includes('not authorised') ? 403
          : message.includes('content type') ? 415
            : message.includes('too large') ? 413
              : error instanceof SyntaxError || error instanceof URIError || error instanceof OfflineMediaInputError || error instanceof PowerScheduleInputError || error instanceof BuildModeInputError ? 400
              : message.startsWith('public key ') || message.startsWith('publicKey ')
                || message === 'invalid OpenSSH public key'
                || message === 'invalid or corrupted OpenSSH public key' ? 400
                : message.includes('already active') ? 409
                  : message.includes('not found') || message.includes('not enabled') ? 404
                    : 500);
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

const sendVaultResponse = (response: ServerResponse, result: VaultHttpResponse): void => {
  if (result.sessionToken) {
    setVaultSessionCookie(response, result.sessionToken);
  }
  if (result.clearSessionCookie) {
    clearVaultSessionCookie(response);
  }
  sendJson(response, result.status, result.body);
};

const vaultHttpErrorStatus = (error: unknown): number | undefined =>
  error instanceof VaultHttpError ? error.status : undefined;

export const handleVaultApiRequest = async (
  config: AppConfig,
  request: IncomingMessage,
  response: ServerResponse,
  pathname: string,
): Promise<boolean> => {
  if (!pathname.startsWith('/api/vault')) {
    return false;
  }
  try {
    if (request.method === 'GET' && pathname === '/api/vault') {
      sendJson(response, 200, buildVaultStatus(config, request.headers));
      return true;
    }

    if (pathname === '/api/vault/session') {
      if (request.method === 'POST') {
        const body = await readMutationJson<{ password?: unknown; totp?: unknown; pendingId?: unknown }>(request);
        sendVaultResponse(response, await vaultUnlock(config, request.headers, body));
        return true;
      }
      if (request.method === 'DELETE') {
        await readMutationJson<Record<string, never>>(request);
        sendVaultResponse(response, vaultLock(config, request.headers));
        return true;
      }
    }

    if (request.method === 'GET' && pathname === '/api/vault/ssh-keys') {
      sendVaultResponse(response, await vaultSshKeys(config, request.headers));
      return true;
    }

    if (request.method === 'POST' && pathname === '/api/vault/ssh-keys') {
      const body = await readMutationJson<{ publicKey?: unknown }>(request);
      sendVaultResponse(response, await vaultSshKeyAdd(config, request.headers, body));
      return true;
    }

    if (request.method === 'GET' && pathname === '/api/vault/syncthing') {
      sendVaultResponse(response, await vaultSyncthingKeyGet(config, request.headers));
      return true;
    }

    if (request.method === 'POST' && pathname === '/api/vault/syncthing') {
      await readMutationJson<Record<string, never>>(request);
      sendVaultResponse(response, await vaultSyncthingKeyRotate(config, request.headers));
      return true;
    }

    if (request.method === 'POST' && pathname === '/api/vault/freshrss') {
      await readMutationJson<Record<string, never>>(request);
      sendVaultResponse(response, await vaultFreshrssPassword(config, request.headers));
      return true;
    }

    if (request.method === 'GET' && pathname === '/api/vault/kavita') {
      sendVaultResponse(response, await vaultKavitaKeysGet(config, request.headers));
      return true;
    }

    if (request.method === 'POST' && pathname === '/api/vault/kavita') {
      const body = await readMutationJson<{ action?: unknown; name?: unknown; authKeyId?: unknown }>(request);
      sendVaultResponse(response, await vaultKavitaKeysMutate(config, request.headers, body));
      return true;
    }

    if (pathname.startsWith('/api/vault/')) {
      sendJson(response, 404, { error: 'api route not found' });
      return true;
    }

    return false;
  } catch (error) {
    if (!response.destroyed && !response.writableEnded && !response.headersSent) {
      const status = vaultHttpErrorStatus(error) ?? 500;
      if (status !== 500) {
        const message = error instanceof Error ? error.message : String(error);
        sendJson(response, status, { error: message });
        return true;
      }
    }
    throw error;
  }
};

export const tryServeStaticAsset = (
  config: AppConfig,
  response: ServerResponse,
  rawPath: string,
): Promise<boolean> => tryServeStaticFile(config.staticDir, response, rawPath);

const serveStatic = async (config: AppConfig, response: ServerResponse, rawPath: string): Promise<void> =>
  serveStaticWithSpaFallback(config.staticDir, response, rawPath);
