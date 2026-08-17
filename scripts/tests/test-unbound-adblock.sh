#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash chmod id jq mktemp nix sed

host="$(test_default_host)"

enabled_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  base = builtins.getAttr hostName f.nixosConfigurations;
  cfg = base.config;
  invalidCfg = (base.extendModules {
    modules = [{
      repo.unbound.adblock.urls = [];
      repo.unbound.adblock.allowlist = [ ".." "-invalid.example" ];
    }];
  }).config;
in {
  server = cfg.services.unbound.settings.server;
  include = cfg.services.unbound.settings.include;
  adblock = cfg.repo.unbound.adblock;
  adblockService = cfg.systemd.services ? unbound-adblock;
  adblockTimer = cfg.systemd.timers ? unbound-adblock-refresh;
  adblockBefore = cfg.systemd.services.unbound-adblock.before;
  adblockAfter = cfg.systemd.services.unbound-adblock.after;
  onFailure = cfg.systemd.services.unbound-adblock.unitConfig.OnFailure;
  timerCal = cfg.systemd.timers.unbound-adblock-refresh.timerConfig.OnCalendar;
  timerPersistent = cfg.systemd.timers.unbound-adblock-refresh.timerConfig.Persistent;
  serviceScript = cfg.systemd.services.unbound-adblock.script;
  invalidMessages = map (entry: entry.message) (builtins.filter (entry: !entry.assertion) invalidCfg.assertions);
}')"

jq -e '
  (.adblock.enable == true)
  and (.adblock.blocklistFile == "/var/lib/unbound/adblock.conf")
  and (.include == ["/var/lib/unbound/adblock.conf"])
  and (.adblockService == true)
  and (.adblockTimer == true)
  and (.adblockBefore | index("unbound.service") != null)
  and (.adblockAfter | index("dnscrypt-proxy.service") != null)
  and (.onFailure == ["nixhomeserver-failure-alert@%n.service"])
  and (.timerCal == "*-*-* 03:15:00 UTC")
  and (.timerPersistent == true)
  and (.server | ."hide-identity" == true)
  and (.server | ."hide-version" == true)
  and (.server | ."prefetch-key" == true)
  and (.server | ."serve-expired" == true)
  and (.server | ."aggressive-nsec" == true)
  and (.server | ."private-address" | length >= 6)
  and (.server | ."rrset-cache-size" == "64m")
  and (.server | ."msg-cache-size" == "32m")
  and (.serviceScript | contains("local-zone: \"%s\""))
  and (.serviceScript | contains("--max-filesize 67108864"))
  and (.serviceScript | contains("--retry 5 --retry-all-errors"))
  and (.serviceScript | contains("--priority daemon.alert"))
  and (.serviceScript | contains("systemctl --no-block reload unbound.service"))
  and (.serviceScript | contains("mv -f \"$tmp_file\" \"$blocklist_file\""))
  and (.invalidMessages | any(contains("must contain at least one HTTPS source")))
  and (.invalidMessages | any(contains("must be bare domain names")))
' <<<"$enabled_json" >/dev/null || {
  echo "❌ Unbound ad-block or hardening surfaces are missing or malformed."
  jq . <<<"$enabled_json"
  exit 1
}

disabled_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  host = (builtins.getAttr hostName f.nixosConfigurations).extendModules {
    modules = [ { repo.unbound.adblock.enable = lib.mkForce false; } ];
  };
  cfg = host.config;
in {
  include = cfg.services.unbound.settings.include or null;
  adblockService = cfg.systemd.services ? unbound-adblock;
  adblockTimer = cfg.systemd.timers ? unbound-adblock-refresh;
  server = cfg.services.unbound.settings.server;
}')"

jq -e '
  (.include == null)
  and (.adblockService == false)
  and (.adblockTimer == false)
  and (.server | ."hide-identity" == true)
  and (.server | ."serve-expired" == true)
  and (.server | ."private-address" | length >= 6)
' <<<"$disabled_json" >/dev/null || {
  echo "❌ Disabling Unbound ad-block left a runtime surface or dropped hardening."
  jq . <<<"$disabled_json"
  exit 1
}

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/state"

jq -r '.serviceScript' <<<"$enabled_json" >"$tmpdir/unbound-adblock.sh"
sed -i \
  -e "s|/var/lib/unbound|$tmpdir/state|g" \
  -e "s|-o unbound -g unbound|-o $(id -u) -g $(id -g)|g" \
  "$tmpdir/unbound-adblock.sh"

cat >"$tmpdir/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$tmpdir/bin/curl"

printf 'last-good blocklist\n' >"$tmpdir/state/adblock.conf"
if ! PATH="$tmpdir/bin:$PATH" bash "$tmpdir/unbound-adblock.sh" >/dev/null 2>&1; then
  echo "❌ A total Unbound blocklist download failure must degrade gracefully so resolver activation can continue."
  exit 1
fi
if [[ "$(cat "$tmpdir/state/adblock.conf")" != "last-good blocklist" ]]; then
  echo "❌ A total Unbound blocklist download failure replaced the last-good fragment."
  exit 1
fi

echo "✅ Unbound ad-block and resolver hardening evaluate with correct enable/disable surfaces."
