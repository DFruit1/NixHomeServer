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
  ).map((pair) => ({ ...pair, server: pair.server ?? server }));
}
