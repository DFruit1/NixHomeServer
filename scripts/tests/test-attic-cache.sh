#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

host="$(test_default_host)"
attic_json="$(
  nix eval --json ".#nixosConfigurations.${host}.config" \
    --apply 'cfg: {
      atticdEnabled = cfg.services.atticd.enable;
      listen = cfg.services.atticd.settings.listen;
      apiEndpoint = cfg.services.atticd.settings.api-endpoint;
      allowedHosts = cfg.services.atticd.settings.allowed-hosts;
      substituters = cfg.nix.settings.substituters;
      extraOptions = cfg.nix.extraOptions;
      firewallPorts = cfg.networking.firewall.allowedTCPPorts;
      secretPresent = cfg.age.secrets ? atticServerEnv;
      persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
      postBuildHook = cfg.nix.settings.post-build-hook or "";
      watcherPresent = cfg.systemd.services ? attic-watch-store;
      atticdService = {
        environment = cfg.systemd.services.atticd.serviceConfig.Environment or [];
        memoryHigh = cfg.systemd.services.atticd.serviceConfig.MemoryHigh or "";
        memoryMax = cfg.systemd.services.atticd.serviceConfig.MemoryMax or "";
        memorySwapMax = cfg.systemd.services.atticd.serviceConfig.MemorySwapMax or "";
        restart = cfg.systemd.services.atticd.serviceConfig.Restart or "";
      };
      bootstrap = {
        after = cfg.systemd.services.attic-cache-bootstrap.after;
        requires = cfg.systemd.services.attic-cache-bootstrap.requires;
        script = cfg.systemd.services.attic-cache-bootstrap.script;
        restart = cfg.systemd.services.attic-cache-bootstrap.serviceConfig.Restart;
      };
    }'
)"

removed_options="$(
  nix eval --json ".#nixosConfigurations.${host}.options.repo.attic" \
    --apply 'options: {
      enable = options ? enable;
      watchJobs = options ? watchJobs;
    }'
)"

jq -e '
  .atticdEnabled
  and (.listen == "127.0.0.1:8080")
  and (.apiEndpoint == "http://127.0.0.1:8080/")
  and ((.allowedHosts | sort) == (["127.0.0.1:8080", "localhost:8080"] | sort))
  and (.substituters | index("http://127.0.0.1:8080/nixhomeserver") != null)
  and (.extraOptions | contains("!include /var/lib/atticd/nix.conf"))
  and (.firewallPorts | index(8080) == null)
  and .secretPresent
  and (.persistence | index("/var/lib/atticd") != null)
  and (.postBuildHook | contains("nixhomeserver-attic-post-build"))
  and (.watcherPresent | not)
  and (.atticdService.environment | index("MALLOC_ARENA_MAX=2") != null)
  and (.atticdService.environment | index("MALLOC_MMAP_THRESHOLD_=131072") != null)
  and (.atticdService.environment | index("MALLOC_TRIM_THRESHOLD_=131072") != null)
  and (.atticdService.memoryHigh == "1G")
  and (.atticdService.memoryMax == "2G")
  and (.atticdService.memorySwapMax == "256M")
  and (.atticdService.restart == "on-failure")
  and (.bootstrap.after | index("atticd.service") != null)
  and (.bootstrap.requires | index("atticd.service") != null)
  and (.bootstrap.restart == "on-failure")
  and (.bootstrap.script | contains("cache_name=nixhomeserver"))
  and (.bootstrap.script | contains("token-file ="))
  and (.bootstrap.script | contains(">\"$client_token_file\""))
  and ((.bootstrap.script | contains("attic login")) | not)
  and (.bootstrap.script | contains("cache create \"$cache_name\" --public --priority 39"))
  and (.bootstrap.script | contains("cache configure \"$cache_name\""))
  and (.bootstrap.script | contains("extra-trusted-public-keys ="))
  and (.bootstrap.script | contains("try-restart nix-daemon.service"))
' <<<"$attic_json" >/dev/null || {
  echo "❌ Evaluated Attic cache contract is incomplete." >&2
  jq . <<<"$attic_json" >&2
  exit 1
}

if ! jq -e '(.enable | not) and (.watchJobs | not)' <<<"$removed_options" >/dev/null; then
  echo "❌ Attic still exposes removed enable or watcher-concurrency options." >&2
  exit 1
fi

for hook_contract in \
  'attic push --no-closure --jobs 1' \
  'flock -w 300' \
  'timeout 300' \
  'exit 0'; do
  require_fixed modules/attic/services.nix "$hook_contract" \
    "the bounded Attic post-build hook must remain failure-isolated and serialized"
done

for fixed_cache in \
  '"https://cache.nixos.org"' \
  '"https://nix-community.cachix.org"'; do
  require_fixed modules/Core_Modules/base-system/default.nix "$fixed_cache" \
    "the official and community Nix caches must be fixed platform defaults"
done
require_fixed modules/Core_Modules/base-system/default.nix \
  '"nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="' \
  "the community cache signing key must be fixed with its substituter"

require_fixed secrets/manifest.nix 'atticServerEnv = {' \
  "Attic's JWT signing environment must be manifest-managed"
require_fixed scripts/helpers/generate-managed-secrets.sh \
  'ATTIC_SERVER_TOKEN_HS256_SECRET_BASE64=' \
  "Attic's generated secret must use the server's documented environment format"
require_fixed modules/Core_Modules/age/default.nix 'atticServerEnv = {' \
  "Attic's server environment must be materialized through agenix"
require_fixed modules/attic/bootstrap.nix '${pkgs.diffutils}/bin/cmp --silent' \
  "Attic bootstrap must use the packaged cmp binary instead of relying on its service PATH"
require_fixed documentation/operations.md 'systemctl status atticd.service attic-cache-bootstrap.service' \
  "operations guidance must expose the Attic health boundary"
require_fixed documentation/custom-app-development.md 'attic cache info nixhomeserver' \
  "custom app guidance must explain how to inspect the development cache"

echo "✅ Attic local binary-cache configuration checks passed."
