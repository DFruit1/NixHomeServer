export const CRAWL_SCOPES = ['page', 'prefix', 'host'] as const;

export const DEFAULT_PAGE_LIMIT = 25;
export const MAX_PAGE_LIMIT = 500;
export const DEFAULT_TIME_LIMIT_MINUTES = 10;
export const MAX_TIME_LIMIT_MINUTES = 120;

export type ParsedCrawlUrl = {
  url: string;
  hostname: string;
};

export const normalizeArchiveUrl = (value: string): string => value.trim();

export const parseCrawlUrl = (value: string): ParsedCrawlUrl | undefined => {
  const raw = normalizeArchiveUrl(value);
  if (!raw || raw.length > 2048) {
    return undefined;
  }
  if (/\s/.test(raw)) {
    return undefined;
  }
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    return undefined;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    return undefined;
  }
  const hostname = parsed.hostname.toLowerCase().replace(/\.$/, '');
  if (!hostname || hostname.length > 253) {
    return undefined;
  }
  if (!/^[a-z0-9._-]+$/.test(hostname)) {
    return undefined;
  }
  if (parsed.username || parsed.password) {
    return undefined;
  }
  parsed.hash = '';
  return { url: parsed.toString(), hostname };
};

export const isPrivateIpv4 = (parts: number[]): boolean =>
  parts[0] === 127
  || parts[0] === 10
  || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31)
  || (parts[0] === 192 && parts[1] === 168)
  || (parts[0] === 169 && parts[1] === 254)
  || (parts[0] === 0)
  || (parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127);

export const isPrivateIpv6 = (expanded: string): boolean =>
  expanded === '::1'
  || expanded === '::'
  || expanded.startsWith('fc')
  || expanded.startsWith('fd')
  || expanded.startsWith('fe80');

export const isPrivateAddressLiteral = (hostname: string): boolean => {
  const ipv4 = hostname.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ipv4) {
    const parts = ipv4.slice(1).map(Number);
    return parts.every((part) => part >= 0 && part <= 255) && isPrivateIpv4(parts);
  }
  if (hostname.includes(':')) {
    return isPrivateIpv6(hostname);
  }
  return hostname === 'localhost';
};
