export type Folder = { uri: string; displayName: string };
export type SyncDirection = 'phone-to-server' | 'server-to-phone' | 'two-way';
export type SyncPair = {
  id: string;
  name: string;
  local: Folder;
  serverPath: string;
  serverRoot?: string;
  serverFolder?: string;
  localSubpath?: string;
  direction: SyncDirection;
  server?: string;
  account?: string;
  storageWarn?: number;
  storageBlock?: number;
};

export function parseSavedPairs(raw: string | null, server: string): SyncPair[] {
  let saved: unknown;
  try { saved = JSON.parse(raw ?? '[]'); } catch { return []; }
  if (!Array.isArray(saved)) return [];
  return saved.filter((pair): pair is SyncPair =>
    pair !== null && typeof pair === 'object' &&
    typeof pair.id === 'string' && pair.id.length > 0 &&
    typeof pair.name === 'string' &&
    pair.local !== null && typeof pair.local === 'object' &&
    typeof pair.local.uri === 'string' && typeof pair.local.displayName === 'string' &&
    typeof pair.serverPath === 'string' &&
    ['phone-to-server', 'server-to-phone', 'two-way'].includes(pair.direction)
  ).map((pair) => {
    const safe = { ...pair };
    for (const key of ['serverRoot', 'serverFolder', 'localSubpath', 'server', 'account'] as const) {
      if (typeof safe[key] !== 'string') delete safe[key];
    }
    for (const key of ['storageWarn', 'storageBlock'] as const) {
      if (typeof safe[key] !== 'number' || !Number.isFinite(safe[key]) || safe[key] <= 0 || safe[key] > 1) delete safe[key];
    }
    return { ...safe, server: safe.server ?? server };
  });
}
