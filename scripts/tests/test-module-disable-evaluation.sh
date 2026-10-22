#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix sed

host="$(test_default_host)"

# Lightweight check: verify a representative subset of apps cleanly disable.
# Deep removal/disable validation is covered by test-module-removal-evaluation.sh.
# This test just ensures the enable=false mechanism doesn't regress for common apps.
cases=(calibre-web chaptarr forgejo freshrss ipfs langfuse prowlarr search sonarr)

# Evaluate all at once on the configured evaluation host.
cases_csv="$(IFS=,; echo "${cases[*]}")"
echo "Evaluating enable=false variants: $cases_csv"

host_literal="$(jq -cn --arg value "$host" '$value' | sed 's/${/\\${/g')"
cases_literal="$(jq -cn --arg value "$cases_csv" '$value')"

# The helper's diagnostics decide the receipt below, so they are captured rather
# than discarded, and both output files keep the call out of a command
# substitution: the helper resolves the evaluation host into a global, and a
# subshell would lose it before the receipt is written.
eval_stderr="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-disable-matrix-stderr.XXXXXX")"
eval_json="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-disable-matrix.XXXXXX")"
trap 'rm -f "$eval_stderr" "$eval_json" 2>/dev/null || true' EXIT

if ! remote_eval_batch_json "disabled=
  import ./scripts/tests/module-disable-matrix.nix {
    flake = f;
    hostName = $host_literal;
    requestedCaseNames = lib.splitString \",\" $cases_literal;
  }
" >"$eval_json" 2>"$eval_stderr"; then
  cat "$eval_stderr" >&2
  # A Nix evaluation killed by SIGINT, SIGTERM or SIGHUP reports exactly this
  # wording. Under a parallel suite run the signal comes from outside this test:
  # the workstation's memory-pressure reaper TERMs the largest consumer once
  # free memory and swap both cross their thresholds. The bare message reads
  # like a disable-matrix regression and has been mistaken for a flaky
  # assertion, so name the interruption. The test still fails.
  if grep -q 'interrupted by the user' "$eval_stderr"; then
    echo "❌ The enable=false matrix evaluation was interrupted by a signal," >&2
    echo "   not by a configuration defect in the matrix." >&2
  else
    echo "❌ The enable=false matrix evaluation failed." >&2
  fi
  exit 1
fi
cat "$eval_stderr" >&2

# Receipt: naming the host that ran the evaluation is what makes an offloaded
# test auditable instead of a claim nobody can check. An explicit REMOTE_EVAL=0
# is a deliberate local run and prints no fallback warning, so the opt-out
# itself decides the receipt; otherwise a fallback warning is what says the
# heavy evaluation ran on this workstation after all.
if [[ "${REMOTE_EVAL:-1}" != "0" ]] &&
  ! grep -q '^remote-eval: falling back to local evaluation' "$eval_stderr"; then
  echo "ℹ️ Evaluated ${#cases[@]} enable=false variants on ${remote_eval_host:-the configured evaluation host} in one batched query."
else
  echo "ℹ️ Evaluated ${#cases[@]} enable=false variants on this workstation (the configured evaluation host was not used)."
fi

disabled_json="$(jq -e '.disabled' "$eval_json")"
expected_keys="$(jq -cn '$ARGS.positional | sort' --args "${cases[@]}")"

jq -e --argjson expected "$expected_keys" '
  (keys == $expected)
  and all(
    .[];
    .valid
    and .registryPresent
    and (.drvPath | startswith("/nix/store/") and endswith(".drv"))
    and (.presentServices == [])
    and (.presentContainers == [])
    and (.presentTimers == [])
    and (.presentCaddyHosts == [])
    and (.presentPrivateHosts == [])
    and (.presentGatewayApps == [])
    and (.presentOauthClients == [])
    and (.presentKanidmGroups == [])
    and (.presentUsers == [])
    and (.presentGroups == [])
    and (.presentSecrets == [])
    and (.presentBackupApps == [])
    and (.presentGuardedServices == [])
    and (.missingPersistence == [])
  )
' <<<"$disabled_json" >/dev/null || {
  echo "❌ An enable=false app retained an active runtime, route, identity, secret, backup, integration, or lost persisted state."
  jq . <<<"$disabled_json"
  exit 1
}

echo "✅ App enable=false switches remove active surfaces while retaining module registration and persisted state."
