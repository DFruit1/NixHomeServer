#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq nix rg

host="$(test_default_host)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
helper="$test_root/netbird-login-helper.sh"
address_helper="$test_root/netbird-address-helper.sh"
expected_address="$(nix_flake_var 'vars.networking.netbird.ip')"

if ! NIXHOMESERVER_TEST_HOST="$host" nix eval --raw --impure --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  in
    (builtins.getAttr hostName f.nixosConfigurations)
      .config.systemd.services."netbird-main-login".script
' >"$helper"; then
  echo "❌ Could not evaluate the deployed NetBird login helper."
  exit 1
fi

if ! NIXHOMESERVER_TEST_HOST="$host" nix eval --raw --impure --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  in
    (builtins.getAttr hostName f.nixosConfigurations)
      .config.systemd.services.netbird-address-verify.script
' >"$address_helper"; then
  echo "❌ Could not evaluate the deployed NetBird address verifier."
  exit 1
fi

service_json="$(NIXHOMESERVER_TEST_HOST="$host" nix eval --json --impure --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
    services = (builtins.getAttr hostName f.nixosConfigurations).config.systemd.services;
    login = services."netbird-main-login";
    address = services.netbird-address-verify;
  in {
    login = {
      inherit (login.serviceConfig) Restart RestartSec TimeoutStartSec Type;
    };
    address = {
      inherit (address.serviceConfig) Restart RestartSec TimeoutStartSec Type;
    };
  }
')"

jq -e '
  .login == {
    Restart: "on-failure",
    RestartSec: "10s",
    TimeoutStartSec: "2min",
    Type: "oneshot"
  }
  and .address == {
    Restart: "on-failure",
    RestartSec: "10s",
    TimeoutStartSec: "3min",
    Type: "oneshot"
  }
' <<<"$service_json" >/dev/null || {
  echo "❌ NetBird login or address verification no longer has bounded, retryable systemd supervision."
  jq . <<<"$service_json"
  exit 1
}

mock_netbird() {
  local command="${1:-}"
  local count=0

  case "$command" in
    status)
      if [[ -f "$MOCK_STATE_DIR/status-count" ]]; then
        IFS= read -r count <"$MOCK_STATE_DIR/status-count"
      fi
      count=$((count + 1))
      printf '%s\n' "$count" >"$MOCK_STATE_DIR/status-count"

      if ((count < MOCK_READY_AFTER)); then
        echo "Daemon status: running"
        echo "Management: Disconnected"
      else
        echo "Status: NeedsLogin"
      fi
      ;;
    up)
      shift
      if (($# != 1)) || [[ "$1" != "--setup-key-file=$MOCK_EXPECTED_SETUP_KEY" ]]; then
        echo "unexpected NetBird up arguments: $*" >&2
        return 64
      fi
      if [[ -f "$MOCK_STATE_DIR/up-count" ]]; then
        IFS= read -r count <"$MOCK_STATE_DIR/up-count"
      else
        count=0
      fi
      count=$((count + 1))
      printf '%s\n' "$count" >"$MOCK_STATE_DIR/up-count"

      if ((count <= MOCK_FAIL_UPS)); then
        echo "simulated transient enrollment failure" >&2
        return 75
      fi
      echo "simulated enrollment success"
      ;;
    *)
      echo "unexpected mock NetBird command: $command" >&2
      return 64
      ;;
  esac
}
export -f mock_netbird

expected_setup_key="$test_root/setup-key"

delayed_state="$test_root/delayed"
mkdir -p "$delayed_state"
if ! env \
  MOCK_STATE_DIR="$delayed_state" \
  MOCK_READY_AFTER=3 \
  MOCK_FAIL_UPS=0 \
  MOCK_EXPECTED_SETUP_KEY="$expected_setup_key" \
  NETBIRD_LOGIN_NETBIRD_BIN=mock_netbird \
  NETBIRD_LOGIN_SETUP_KEY_FILE="$expected_setup_key" \
  NETBIRD_LOGIN_STATUS_ATTEMPTS=4 \
  NETBIRD_LOGIN_STATUS_DELAY_SECONDS=0 \
  bash "$helper" >"$delayed_state/helper.log" 2>&1; then
  echo "❌ NetBird login did not recover from a delayed NeedsLogin status."
  cat "$delayed_state/helper.log"
  exit 1
fi

[[ "$(<"$delayed_state/status-count")" == "3" ]] || {
  echo "❌ NetBird login did not poll until the delayed status became usable."
  cat "$delayed_state/helper.log"
  exit 1
}
[[ "$(<"$delayed_state/up-count")" == "1" ]] || {
  echo "❌ NetBird login did not enroll exactly once after delayed readiness."
  cat "$delayed_state/helper.log"
  exit 1
}
rg -q 'Waiting for NetBird status to become usable' "$delayed_state/helper.log" || {
  echo "❌ NetBird login did not emit a useful delayed-readiness diagnostic."
  cat "$delayed_state/helper.log"
  exit 1
}

retry_state="$test_root/retry"
mkdir -p "$retry_state"
set +e
env \
  MOCK_STATE_DIR="$retry_state" \
  MOCK_READY_AFTER=1 \
  MOCK_FAIL_UPS=1 \
  MOCK_EXPECTED_SETUP_KEY="$expected_setup_key" \
  NETBIRD_LOGIN_NETBIRD_BIN=mock_netbird \
  NETBIRD_LOGIN_SETUP_KEY_FILE="$expected_setup_key" \
  NETBIRD_LOGIN_STATUS_ATTEMPTS=2 \
  NETBIRD_LOGIN_STATUS_DELAY_SECONDS=0 \
  bash "$helper" >"$retry_state/first.log" 2>&1
first_rc=$?
set -e
if ((first_rc == 0)); then
  echo "❌ NetBird login hid a transient enrollment failure from systemd."
  cat "$retry_state/first.log"
  exit 1
fi
rg -q 'systemd will retry this helper' "$retry_state/first.log" || {
  echo "❌ NetBird login failure did not explain its retry behavior."
  cat "$retry_state/first.log"
  exit 1
}

if ! env \
  MOCK_STATE_DIR="$retry_state" \
  MOCK_READY_AFTER=1 \
  MOCK_FAIL_UPS=1 \
  MOCK_EXPECTED_SETUP_KEY="$expected_setup_key" \
  NETBIRD_LOGIN_NETBIRD_BIN=mock_netbird \
  NETBIRD_LOGIN_SETUP_KEY_FILE="$expected_setup_key" \
  NETBIRD_LOGIN_STATUS_ATTEMPTS=2 \
  NETBIRD_LOGIN_STATUS_DELAY_SECONDS=0 \
  bash "$helper" >"$retry_state/second.log" 2>&1; then
  echo "❌ NetBird login did not converge when systemd retried after one failed enrollment."
  cat "$retry_state/first.log" "$retry_state/second.log"
  exit 1
fi
[[ "$(<"$retry_state/up-count")" == "2" ]] || {
  echo "❌ NetBird login did not retry enrollment exactly once after the transient failure."
  cat "$retry_state/first.log" "$retry_state/second.log"
  exit 1
}

bounded_state="$test_root/bounded"
mkdir -p "$bounded_state"
set +e
env \
  MOCK_STATE_DIR="$bounded_state" \
  MOCK_READY_AFTER=99 \
  MOCK_FAIL_UPS=0 \
  MOCK_EXPECTED_SETUP_KEY="$expected_setup_key" \
  NETBIRD_LOGIN_NETBIRD_BIN=mock_netbird \
  NETBIRD_LOGIN_SETUP_KEY_FILE="$expected_setup_key" \
  NETBIRD_LOGIN_STATUS_ATTEMPTS=3 \
  NETBIRD_LOGIN_STATUS_DELAY_SECONDS=0 \
  bash "$helper" >"$bounded_state/helper.log" 2>&1
bounded_rc=$?
set -e
if ((bounded_rc == 0)); then
  echo "❌ NetBird login waited successfully despite never receiving a usable status."
  cat "$bounded_state/helper.log"
  exit 1
fi
[[ "$(<"$bounded_state/status-count")" == "3" ]] || {
  echo "❌ NetBird login did not honor its bounded status-attempt limit."
  cat "$bounded_state/helper.log"
  exit 1
}
[[ ! -e "$bounded_state/up-count" ]] || {
  echo "❌ NetBird login tried to enroll before NetBird requested login."
  cat "$bounded_state/helper.log"
  exit 1
}
rg -q 'did not become ready after 3 status attempts' "$bounded_state/helper.log" || {
  echo "❌ NetBird login timeout did not report its attempt limit."
  cat "$bounded_state/helper.log"
  exit 1
}
rg -q 'Management: Disconnected' "$bounded_state/helper.log" || {
  echo "❌ NetBird login timeout did not report the final status output."
  cat "$bounded_state/helper.log"
  exit 1
}

cat >"$test_root/ip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$MOCK_ADDRESS_STATE" ]] || count="$(<"$MOCK_ADDRESS_STATE")"
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_ADDRESS_STATE"
address="192.0.2.99"
if (( count >= MOCK_ADDRESS_READY_AFTER )); then
  address="$MOCK_EXPECTED_ADDRESS"
fi
printf '7: mock0    inet %s/16 scope global mock0\n' "$address"
EOF
cat >"$test_root/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
make_test_executable "$test_root/ip" "$test_root/sleep"

address_state="$test_root/address-delayed.count"
PATH="$test_root:$PATH" \
  MOCK_ADDRESS_STATE="$address_state" \
  MOCK_ADDRESS_READY_AFTER=3 \
  MOCK_EXPECTED_ADDRESS="$expected_address" \
  bash "$address_helper"
[[ "$(<"$address_state")" == "3" ]] || {
  echo "❌ NetBird address verification did not wait for the assigned address."
  exit 1
}

address_state="$test_root/address-retry.count"
if PATH="$test_root:$PATH" \
  MOCK_ADDRESS_STATE="$address_state" \
  MOCK_ADDRESS_READY_AFTER=121 \
  MOCK_EXPECTED_ADDRESS="$expected_address" \
  bash "$address_helper" >/dev/null 2>&1; then
  echo "❌ NetBird address verification hid a bounded readiness failure."
  exit 1
fi
PATH="$test_root:$PATH" \
  MOCK_ADDRESS_STATE="$address_state" \
  MOCK_ADDRESS_READY_AFTER=121 \
  MOCK_EXPECTED_ADDRESS="$expected_address" \
  bash "$address_helper"

echo "✅ NetBird login convergence tests passed."
