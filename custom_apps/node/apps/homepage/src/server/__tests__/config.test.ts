import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { loadHomepageConfig } from '../config.js';
import { brandedPageTitle } from '../../shared/branding.js';

describe('homepage configuration branding', () => {
  it('requires and trims a portable brand name', async () => {
    const directory = await mkdtemp(path.join(tmpdir(), 'homepage-config-'));
    try {
      const configPath = path.join(directory, 'homepage.json');
      await writeFile(configPath, JSON.stringify({
        brandName: '  Family Home  ',
        domain: 'example.test',
        services: [],
        folderGuides: [],
        adminGuide: [],
      }));

      expect(loadHomepageConfig(configPath).brandName).toBe('Family Home');

      await writeFile(configPath, JSON.stringify({
        domain: 'example.test',
        services: [],
        folderGuides: [],
        adminGuide: [],
      }));
      expect(() => loadHomepageConfig(configPath)).toThrow(/brandName/);

      await writeFile(configPath, JSON.stringify({
        brandName: 42,
        domain: 'example.test',
        services: [],
        folderGuides: [],
        adminGuide: [],
      }));
      expect(() => loadHomepageConfig(configPath)).toThrow(/brandName/);

      await writeFile(configPath, JSON.stringify({
        brandName: 'x'.repeat(101),
        domain: 'example.test',
        services: [],
        folderGuides: [],
        adminGuide: [],
      }));
      expect(() => loadHomepageConfig(configPath)).toThrow(/at most 100/);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('uses neutral reserved defaults when no generated config is supplied', () => {
    expect(loadHomepageConfig(undefined)).toMatchObject({
      brandName: 'Home Server',
      domain: 'example.test',
    });
  });

  it('accepts labelled connection records and safely upgrades stale string-only addresses', async () => {
    const directory = await mkdtemp(path.join(tmpdir(), 'homepage-connections-'));
    try {
      const configPath = path.join(directory, 'homepage.json');
      await writeFile(configPath, JSON.stringify({
        brandName: 'Family Home',
        domain: 'example.test',
        services: [],
        folderGuides: [],
        adminGuide: [],
        offlineMedia: {
          enabled: true,
          connectionAddresses: [
            {
              address: ' tcp://server.internal:22000 ',
              label: ' Recommended server address ',
            },
            'tcp://100.64.0.10:22000',
            { address: 'tcp://192.168.1.10:22000', label: 42 },
            { address: 'tcp://bad\naddress:22000', label: 'Invalid' },
            { address: '', label: 'Invalid' },
            42,
          ],
          folders: [],
          devices: [],
        },
      }));

      expect(loadHomepageConfig(configPath).offlineMedia?.connectionAddresses).toEqual([
        {
          address: 'tcp://server.internal:22000',
          label: 'Recommended server address',
        },
        {
          address: 'tcp://100.64.0.10:22000',
          label: 'Server address',
        },
        {
          address: 'tcp://192.168.1.10:22000',
          label: 'Server address',
        },
      ]);

      await writeFile(configPath, JSON.stringify({
        brandName: 'Family Home',
        domain: 'example.test',
        services: [],
        folderGuides: [],
        adminGuide: [],
        offlineMedia: {
          enabled: true,
          connectionAddresses: 'tcp://server.internal:22000',
          folders: [],
          devices: [],
        },
      }));
      expect(loadHomepageConfig(configPath).offlineMedia?.connectionAddresses).toEqual([]);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it('builds portable page titles and falls back neutrally', () => {
    expect(brandedPageTitle('Family Home', 'Getting Started')).toBe('Getting Started | Family Home');
    expect(brandedPageTitle('Family Home')).toBe('Family Home');
    expect(brandedPageTitle('   ', 'For Admins')).toBe('For Admins | Home Server');
  });
});
