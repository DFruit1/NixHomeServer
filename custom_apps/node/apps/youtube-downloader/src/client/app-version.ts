// Baked into the bundle by Vite `define` from package.json, so the label
// reflects the build the user is actually running (web deploy or APK).
declare const __APP_VERSION__: string | undefined;
declare const __APP_VERSION_DATE__: string | undefined;

export const installedAppVersion: string =
  typeof __APP_VERSION__ === 'string' && __APP_VERSION__ !== '' ? __APP_VERSION__ : '0.0.0-dev';

export const installedAppDate: string =
  typeof __APP_VERSION_DATE__ === 'string' ? __APP_VERSION_DATE__ : '';

export const installedVersionLabel: string =
  installedAppDate === '' ? `v${installedAppVersion}` : `v${installedAppVersion} · ${installedAppDate}`;

/** True when `candidate` ranks above `current` in a dotted numeric version. */
export const isNewerVersion = (candidate: string, current: string): boolean => {
  const parse = (value: string): number[] =>
    value
      .trim()
      .split('.')
      .map((segment) => Number.parseInt(segment, 10) || 0);
  const left = parse(candidate);
  const right = parse(current);
  const length = Math.max(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const candidatePart = left[index] ?? 0;
    const currentPart = right[index] ?? 0;
    if (candidatePart > currentPart) {
      return true;
    }
    if (candidatePart < currentPart) {
      return false;
    }
  }
  return false;
};
