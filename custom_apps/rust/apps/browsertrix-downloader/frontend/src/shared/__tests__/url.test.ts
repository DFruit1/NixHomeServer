import { describe, expect, it } from 'vitest';
import {
  DEFAULT_PAGE_LIMIT,
  DEFAULT_TIME_LIMIT_MINUTES,
  isPrivateAddressLiteral,
  normalizeArchiveUrl,
  parseCrawlUrl,
} from '../url.js';

describe('parseCrawlUrl', () => {
  it('accepts plain http and https URLs', () => {
    expect(parseCrawlUrl('https://example.com/page?b=2&a=1')?.url).toBe('https://example.com/page?b=2&a=1');
    expect(parseCrawlUrl('http://example.org')?.hostname).toBe('example.org');
  });

  it('trims surrounding whitespace', () => {
    expect(parseCrawlUrl('  https://example.com  ')?.hostname).toBe('example.com');
  });

  it('rejects non-http schemes and malformed URLs', () => {
    expect(parseCrawlUrl('ftp://example.com')).toBeUndefined();
    expect(parseCrawlUrl('javascript:alert(1)')).toBeUndefined();
    expect(parseCrawlUrl('not a url')).toBeUndefined();
    expect(parseCrawlUrl('')).toBeUndefined();
  });

  it('rejects embedded credentials and oversized URLs', () => {
    expect(parseCrawlUrl('https://user:pass@example.com')).toBeUndefined();
    expect(parseCrawlUrl(`https://example.com/${'a'.repeat(2100)}`)).toBeUndefined();
  });

  it('rejects hostnames with unsafe characters', () => {
    expect(parseCrawlUrl('https://exa mple.com')).toBeUndefined();
    expect(parseCrawlUrl('https://exa%20mple.com')).toBeUndefined();
  });
});

describe('isPrivateAddressLiteral', () => {
  it('flags loopback, private, and link-local IPv4', () => {
    for (const host of ['127.0.0.1', '10.1.2.3', '172.16.0.1', '192.168.8.12', '169.254.1.1', '0.0.0.0']) {
      expect(isPrivateAddressLiteral(host)).toBe(true);
    }
  });

  it('flags IPv6 and localhost names', () => {
    expect(isPrivateAddressLiteral('::1')).toBe(true);
    expect(isPrivateAddressLiteral('fe80::1')).toBe(true);
    expect(isPrivateAddressLiteral('localhost')).toBe(true);
  });

  it('allows public addresses', () => {
    expect(isPrivateAddressLiteral('93.184.216.34')).toBe(false);
    expect(isPrivateAddressLiteral('example.com')).toBe(false);
  });
});

describe('shared constants', () => {
  it('exposes defaults used by the queue clamp', () => {
    expect(DEFAULT_PAGE_LIMIT).toBeGreaterThan(0);
    expect(DEFAULT_TIME_LIMIT_MINUTES).toBeGreaterThan(0);
    expect(normalizeArchiveUrl('  https://example.com  ')).toBe('https://example.com');
  });
});
