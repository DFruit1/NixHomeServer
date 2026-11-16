// Offline position plot: an equirectangular projection fitted to the fixes,
// with a lat/lon graticule. No map tiles: the API's CSP only allows
// same-origin images and connections, and the LAN view must work offline.

export interface Fix {
  lat: number;
  lon: number;
}

export interface Bounds {
  minLat: number;
  maxLat: number;
  minLon: number;
  maxLon: number;
}

const EARTH_RADIUS_M = 6371008.8;

export const validFix = (p: {
  lat?: number | null;
  lon?: number | null;
}): p is Fix =>
  typeof p.lat === "number" &&
  typeof p.lon === "number" &&
  Number.isFinite(p.lat) &&
  Number.isFinite(p.lon) &&
  Math.abs(p.lat) <= 90 &&
  Math.abs(p.lon) <= 180 &&
  !(p.lat === 0 && p.lon === 0);

/** Great-circle distance in metres. */
export function distanceM(a: Fix, b: Fix) {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad,
    dLon = (b.lon - a.lon) * rad;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Bounds of the fixes, padded to at least ~`minSpanM` metres so a
 * stationary logger is not drawn at an absurd zoom. */
export function fitBounds(fixes: Fix[], minSpanM = 50): Bounds | null {
  if (!fixes.length) return null;
  let minLat = Infinity,
    maxLat = -Infinity,
    minLon = Infinity,
    maxLon = -Infinity;
  for (const f of fixes) {
    minLat = Math.min(minLat, f.lat);
    maxLat = Math.max(maxLat, f.lat);
    minLon = Math.min(minLon, f.lon);
    maxLon = Math.max(maxLon, f.lon);
  }
  const midLat = (minLat + maxLat) / 2;
  const latSpan = minSpanM / 111320;
  const lonSpan =
    minSpanM / (111320 * Math.max(0.01, Math.cos((midLat * Math.PI) / 180)));
  const grow = (low: number, high: number, span: number): [number, number] => {
    const width = Math.max(high - low, span) * 1.2;
    const mid = (low + high) / 2;
    return [mid - width / 2, mid + width / 2];
  };
  [minLat, maxLat] = grow(minLat, maxLat, latSpan);
  [minLon, maxLon] = grow(minLon, maxLon, lonSpan);
  return { minLat, maxLat, minLon, maxLon };
}

/** Projects into a `width` × `height` box keeping metres square at the
 * centre latitude (the box is letterboxed rather than stretched). */
export function projector(bounds: Bounds, width: number, height: number) {
  const midLat = ((bounds.minLat + bounds.maxLat) / 2) * (Math.PI / 180);
  const kx = Math.cos(midLat);
  const spanX = (bounds.maxLon - bounds.minLon) * kx;
  const spanY = bounds.maxLat - bounds.minLat;
  const scale = Math.min(width / spanX, height / spanY);
  const offsetX = (width - spanX * scale) / 2;
  const offsetY = (height - spanY * scale) / 2;
  return {
    x: (lon: number) => offsetX + (lon - bounds.minLon) * kx * scale,
    y: (lat: number) => offsetY + (bounds.maxLat - lat) * scale,
    metresPerPixel: 111320 / scale,
  };
}

/** Round graticule step (degrees) giving roughly `target` lines. */
export function graticuleStep(span: number, target = 4) {
  const raw = span / target;
  const power = 10 ** Math.floor(Math.log10(raw));
  for (const m of [1, 2, 5, 10]) if (m * power >= raw) return m * power;
  return 10 * power;
}

export function graticule(low: number, high: number, target = 4) {
  const step = graticuleStep(high - low, target);
  const lines: number[] = [];
  for (let v = Math.ceil(low / step) * step; v <= high; v += step)
    lines.push(Number(v.toFixed(10)));
  const digits = Math.max(0, Math.min(7, -Math.floor(Math.log10(step))));
  return { lines, digits };
}

export const osmLink = (fix: Fix, zoom = 17) =>
  `https://www.openstreetmap.org/?mlat=${fix.lat.toFixed(7)}&mlon=${fix.lon.toFixed(7)}#map=${zoom}/${fix.lat.toFixed(6)}/${fix.lon.toFixed(6)}`;

export function formatDistance(metres: number) {
  if (!Number.isFinite(metres)) return "—";
  return metres < 1000
    ? `${metres.toFixed(metres < 10 ? 1 : 0)} m`
    : `${(metres / 1000).toFixed(2)} km`;
}
