import { describe, expect, it } from 'vitest';
import { detailedServiceTips, serviceSymbols } from '../../shared/ui-constants.js';

const configuredServiceIds = Object.keys(serviceSymbols)
  .filter((serviceId) => serviceId !== 'sftp' && serviceId !== 'offsite-backups');

describe('detailed service guidance', () => {
  it.each(configuredServiceIds)('provides substantial guidance for %s', (serviceId) => {
    expect(detailedServiceTips[serviceId], `${serviceId} should have dedicated guidance`).toBeDefined();
    expect(detailedServiceTips[serviceId]!.length).toBeGreaterThanOrEqual(4);
  });
});
