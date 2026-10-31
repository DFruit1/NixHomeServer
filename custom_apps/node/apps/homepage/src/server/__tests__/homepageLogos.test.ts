import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

// Owner explicitly requested a replacement guard. Change this pin only with
// explicit consent for a Homepage logo change (AGENTS.md).
const approvedProwlarrHash = '403dc15cb69809c1ee88900f2cb5868ac263ea44745bc72fb68c153622c38ada';
const read = (path: string) => readFileSync(new URL(path, import.meta.url));

describe('approved Homepage logos', () => {
  it('retains the approved text-free Prowlarr mark and its catalog mapping', () => {
    const logo = read('../../../public/logos/prowlarr.svg');
    expect(createHash('sha256').update(logo).digest('hex')).toBe(approvedProwlarrHash);
    const registration = read('../../../../../../../modules/prowlarr/registration.nix').toString();
    expect(registration).toMatch(/logoUrl\s*=\s*"\/logos\/prowlarr\.svg"/);
    expect(read('../../../../../../../modules/Core_Modules/kanidm/assets/apps/prowlarr.svg')).toEqual(logo);
  });
});
