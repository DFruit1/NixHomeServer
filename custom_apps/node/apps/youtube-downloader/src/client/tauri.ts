import {
  SERVER_BASE_URL_STORAGE_KEY,
  apiFetch,
  setApiTransport,
} from './api.js';

type InvokeArgs = Record<string, unknown>;
type Invoke = <T>(command: string, args?: InvokeArgs) => Promise<T>;

type TauriGlobal = {
  __TAURI__?: { core?: { invoke?: Invoke } };
};

export type AuthStatus = {
  signedIn: boolean;
  username?: string | null;
  expiresAt?: number | null;
};

export type AuthConfig = {
  issuer: string | null;
  clientId: string | null;
  groupsClaim: string;
};

export const tauriInvoke = (): Invoke | undefined =>
  typeof window === 'undefined' ? undefined : (window as unknown as TauriGlobal).__TAURI__?.core?.invoke;

const headerPairs = (headers: HeadersInit | undefined): Array<[string, string]> => {
  if (!headers) {
    return [];
  }
  if (Array.isArray(headers)) {
    return headers.map(([ name, value ]) => [ String(name), String(value) ]);
  }
  if (headers instanceof Headers) {
    const pairs: Array<[string, string]> = [];
    headers.forEach((value, name) => pairs.push([ name, value ]));
    return pairs;
  }
  return Object.entries(headers)
    .filter((entry): entry is [ string, string ] => entry[1] != null)
    .map(([ name, value ]) => [ name, String(value) ]);
};

export const installTauriTransport = (): boolean => {
  const invoke = tauriInvoke();
  if (!invoke) {
    return false;
  }
  setApiTransport(async (url, init) => {
    const rawBody = init?.body;
    const body = rawBody == null ? null : typeof rawBody === 'string' ? rawBody : String(rawBody);
    const result = await invoke<{ status: number; body: string; headers: Array<[string, string]> }>(
      'api_request',
      {
        method: init?.method ?? 'GET',
        url,
        headers: headerPairs(init?.headers),
        body,
      },
    );
    return new Response(result.body, { status: result.status, headers: result.headers });
  });
  return true;
};

export const getAuthStatus = (): Promise<AuthStatus> => {
  const invoke = tauriInvoke();
  if (!invoke) {
    return Promise.resolve({ signedIn: false });
  }
  return invoke<AuthStatus>('oauth_status');
};

export const signIn = (issuer: string, clientId: string): Promise<AuthStatus> => {
  const invoke = tauriInvoke();
  if (!invoke) {
    throw new Error('Sign-in is only available in the desktop or mobile app.');
  }
  return invoke<AuthStatus>('oauth_login', { issuer, clientId });
};

export const signOut = (): Promise<void> => {
  const invoke = tauriInvoke();
  if (!invoke) {
    return Promise.resolve();
  }
  return invoke<void>('oauth_logout');
};

export type PendingJob = {
  id: string;
  url: string;
  addedAt: number;
  mediaType?: string | null;
  lastError?: string | null;
};

export type FlushOutcome = {
  sent: number;
  remaining: number;
  errors: string[];
};

export const storeServerBaseUrl = (url: string): void => {
  const trimmed = url.trim().replace(/\/+$/, '');
  window.localStorage.setItem(SERVER_BASE_URL_STORAGE_KEY, trimmed);
  // Persist for the Rust-side background queue flush.
  void tauriInvoke()?.('set_server_base_url', { url: trimmed }).catch(() => undefined);
};

export const listPendingJobs = async (): Promise<PendingJob[]> => {
  const invoke = tauriInvoke();
  if (!invoke) {
    return [];
  }
  return (await invoke<PendingJob[]>('queue_list').catch(() => [])) ?? [];
};

export const addPendingJob = async (url: string, mediaType?: string): Promise<void> => {
  await tauriInvoke()?.('queue_add', { url, mediaType: mediaType ?? 'audio' }).catch(() => undefined);
};

export const removePendingJob = async (id: string): Promise<void> => {
  await tauriInvoke()?.('queue_remove', { id }).catch(() => undefined);
};

export const flushPendingJobs = async (): Promise<FlushOutcome> => {
  const invoke = tauriInvoke();
  if (!invoke) {
    return { sent: 0, remaining: 0, errors: [] };
  }
  return invoke<FlushOutcome>('queue_flush').catch((error) => ({
    sent: 0,
    remaining: 0,
    errors: [ error instanceof Error ? error.message : String(error) ],
  }));
};

export const fetchAuthConfig = async (): Promise<AuthConfig> => {
  const response = await apiFetch('/api/auth-config');
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      throw new Error(
        'This looks like the web address. Sign-in needs the API host, for example https://ytdownload-app.<your-domain>.',
      );
    }
    throw new Error(`The server returned ${response.status} for its sign-in configuration.`);
  }
  return response.json() as Promise<AuthConfig>;
};
