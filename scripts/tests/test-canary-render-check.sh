#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools node

CANARY_RUNNER_TEST_MODE=1 node --input-type=module <<'EOF'
const { generateTotp, hasAuthenticationBoundary, isBlankRender } = await import('./modules/homepage/canary-runner.mjs');
const cases = [
  [{ textLength: 0, visibleElements: 0, richElements: 0 }, true, 'empty HTTP 200 body'],
  [{ textLength: 12, visibleElements: 3, richElements: 0 }, true, 'near-empty visible text'],
  [{ textLength: 0, visibleElements: 2, richElements: 1 }, false, 'visible interactive application shell'],
  [{ textLength: 40, visibleElements: 2, richElements: 0 }, false, 'meaningful rendered text'],
];
for (const [metrics, expected, label] of cases) {
  const actual = isBlankRender(metrics);
  if (actual !== expected) throw new Error(`${label}: expected ${expected}, received ${actual}`);
}
if (!hasAuthenticationBoundary({ url: 'https://id.example.test/ui/login', kanidmHost: 'id.example.test' })) {
  throw new Error('Kanidm redirect was not recognised as an authentication boundary');
}
if (!hasAuthenticationBoundary({ url: 'https://books.example.test/', title: 'Kavita', text: 'Sign in with Kanidm', loginControls: 1 })) {
  throw new Error('application login surface was not recognised as an authentication boundary');
}
if (hasAuthenticationBoundary({ url: 'https://books.example.test/', title: 'Kavita', text: 'Recently added books' })) {
  throw new Error('application content was incorrectly recognised as an authentication boundary');
}
if (hasAuthenticationBoundary({ url: 'https://homepage.example.test/', title: 'Home', text: 'Passwords Kanidm login help' })) {
  throw new Error('generic homepage words were incorrectly recognised as an authentication boundary');
}
if (!hasAuthenticationBoundary({ url: 'https://videos.example.test/', title: 'Jellyfin', text: '', loginControls: 1 })) {
  throw new Error('a visible application login control was not recognised as an authentication boundary');
}
// RFC 6238 Appendix B SHA-256 vector: ASCII seed "12345678901234567890123456789012".
const rfcSeed = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA';
const rfcCode = generateTotp(rfcSeed, { timestampMs: 59_000, digits: 8, algorithm: 'sha256' });
if (rfcCode !== '46119246') throw new Error(`SHA-256 TOTP vector mismatch: ${rfcCode}`);
EOF

echo "✅ Canary blank-page render checks passed."
