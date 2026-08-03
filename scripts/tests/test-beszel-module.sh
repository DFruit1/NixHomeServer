#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools rg

require_fixed modules/catalog.nix 'beszel = app ./beszel' \
  "Beszel should be an application in the optional module catalog."
require_fixed modules/beszel/default.nix 'nixhomeserver.modules.beszel = true;' \
  "Beszel should register only when its module is imported."
forbid_match modules/Core_Modules/monitoring/default.nix 'beszel|services[.]nix|identity[.]nix|networking[.]nix' \
  "Core monitoring should not import or configure Beszel."
forbid_match modules/beszel/services.nix 'TRUSTED_AUTH_HEADER' \
  "Beszel must not trust a forgeable header from arbitrary local processes."
require_fixed modules/beszel/backups.nix 'outputName = "beszel.sqlite";' \
  "The optional Beszel module should own its logical database backup."
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/beszel-hub"' \
  "Beszel state persistence must survive disabling or removing the module."

echo "✅ Beszel is optional while its retained data remains centrally persistent."
