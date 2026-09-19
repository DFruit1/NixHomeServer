export const SERVER_BASE_URL_STORAGE_KEY = 'youtubeDownloader.serverBaseUrl';

export type ApiUrlOptions = {
  tauri: boolean;
  baseUrl?: string;
};

// The native shells talk to the LAN-only API host, which serves
// /api/auth-config without a browser session. Overridable at build time or in
// the connection settings.
const FALLBACK_SERVER_BASE_URL = 'https://ytdownload-app.sydneybasiniot.org';

const buildEnv = (import.meta as unknown as { env?: Record<string, string | undefined> }).env ?? {};

const buildDefaultBaseUrl = (buildEnv.VITE_SERVER_BASE_URL ?? FALLBACK_SERVER_BASE_URL).replace(/\/+$/, '');

const normalisePath = (path: string): string => (path.startsWith('/') ? path : `/${path}`);

const trimTrailingSlashes = (value: string): string => value.replace(/\/+$/, '');

export const resolveApiUrl = (path: string, options: ApiUrlOptions): string => {
  const normalised = normalisePath(path);
  if (!options.tauri) {
    return normalised;
  }
  return `${trimTrailingSlashes(options.baseUrl ?? '')}${normalised}`;
};

export const isTauriRuntime = (): boolean =>
  typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

const storedBaseUrl = (): string | undefined => {
  if (typeof window === 'undefined') {
    return undefined;
  }
  try {
    return window.localStorage?.getItem(SERVER_BASE_URL_STORAGE_KEY)?.trim() || undefined;
  } catch {
    return undefined;
  }
};

export const serverBaseUrl = (): string => trimTrailingSlashes(storedBaseUrl() ?? buildDefaultBaseUrl);

export const apiUrl = (path: string): string =>
  resolveApiUrl(path, { tauri: isTauriRuntime(), baseUrl: serverBaseUrl() });

export type ApiTransport = (url: string, init?: RequestInit) => Promise<Response>;

const browserTransport: ApiTransport = (url, init) => fetch(url, init);

let transport: ApiTransport = browserTransport;

export const setApiTransport = (next: ApiTransport): void => {
  transport = next;
};

export const resetApiTransport = (): void => {
  transport = browserTransport;
};

export const apiFetch = (path: string, init?: RequestInit): Promise<Response> =>
  transport(apiUrl(path), init);
