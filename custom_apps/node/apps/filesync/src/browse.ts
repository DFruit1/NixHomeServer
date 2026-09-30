import { formatBytes } from './storage.ts';

export type BrowseEntry = {
  name: string;
  path: string;
  kind: string;
  size: number;
  modifiedUnixMs: number;
};

export type FileAction = 'share' | 'download';

const MODIFIED_DATE = new Intl.DateTimeFormat('en-GB', {
  day: 'numeric',
  month: 'short',
  year: 'numeric',
});

export function joinPath(base: string, name: string): string {
  return base ? `${base}/${name}` : name;
}

export function parentPath(path: string): string {
  const parts = path.split('/');
  return parts.length > 1 ? parts.slice(0, -1).join('/') : '';
}

// Folders come first so navigation stays at the top of the list, and anything
// that is neither a folder nor a file (a socket, a device node) is hidden
// because a read-only browser has nothing to offer for it.
export function browseOrder(entries: BrowseEntry[]): BrowseEntry[] {
  return entries
    .filter((entry) => entry.kind === 'directory' || entry.kind === 'file')
    .sort((left, right) => {
      if (left.kind !== right.kind) return left.kind === 'directory' ? -1 : 1;
      return left.name.toLowerCase().localeCompare(right.name.toLowerCase());
    });
}

export function directoriesOnly(entries: BrowseEntry[]): BrowseEntry[] {
  return browseOrder(entries).filter((entry) => entry.kind === 'directory');
}

export function formatModified(unixMs: number): string {
  if (!Number.isFinite(unixMs) || unixMs <= 0) return '';
  return MODIFIED_DATE.format(new Date(unixMs));
}

export function entryMeta(entry: BrowseEntry): string {
  const size = entry.kind === 'directory' ? '' : formatBytes(entry.size);
  return [size, formatModified(entry.modifiedUnixMs)].filter(Boolean).join(' · ');
}

export function fileActionLabel(action: FileAction, busy: boolean): string {
  if (busy) return action === 'share' ? 'Sharing…' : 'Downloading…';
  return action === 'share' ? 'Share' : 'Download';
}
