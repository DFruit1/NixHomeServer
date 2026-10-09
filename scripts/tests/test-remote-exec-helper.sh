#!/usr/bin/env bash
# Regression test for scripts/helpers/remote-exec.sh.
#
# The helper decides where an agent-authored command physically runs, and its
# whole value is the envelope around that command. So the checks here pin the
# envelope's two failure directions:
#
#   * it must never widen past what the owner authorized (card t_562a9a94);
#   * a transport or staging failure must never look like a successful run.
#
# Everything network-facing is mocked. `ssh` is replaced by a shell function that
# answers locally, so no session, server or real deploy is contacted and no Nix
# evaluation happens. The server-side behaviour the helper depends on
# (transient unit limits, RuntimeMaxSec enforcement) is measured live and recorded
# in the helper's own header rather than faked here.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-exec.sh"

failures=0
note_failure() {
  echo "❌ $1" >&2
  failures=$((failures + 1))
}

test_root="$(mktemp -d)"
mock_job_glob=""
# PIDs for the slot-lifetime section; empty until that section runs, so the EXIT
# trap is safe on every earlier failure path.
launcher_pid=""
unit_pid=""
cleanup() {
  if [[ -n "$launcher_pid" ]]; then
    kill -KILL "$launcher_pid" 2>/dev/null || true
  fi
  if [[ -n "$unit_pid" ]]; then
    kill -KILL -- "-${unit_pid}" 2>/dev/null || true
  fi
  rm -rf "$test_root"
  [[ -n "$mock_job_glob" ]] && rm -rf "$mock_job_glob"
  return 0
}
trap cleanup EXIT

echo "▶ remote-exec helper contract"

# --- argument validation -----------------------------------------------------

if remote_exec_run >/dev/null 2>&1; then
  note_failure "remote_exec_run accepted an empty job id and script"
fi

if remote_exec_run 'job' '' >/dev/null 2>&1; then
  note_failure "remote_exec_run accepted an empty job script"
fi

if remote_exec_cancel 'not a valid id' >/dev/null 2>&1; then
  note_failure "remote_exec_cancel accepted a job id with spaces"
fi

if remote_exec_status 'not a valid id' >/dev/null 2>&1; then
  note_failure "remote_exec_status accepted a job id with spaces"
fi

echo "  ✅ rejects empty input and malformed job ids"

# --- the job id cannot escape its namespace ----------------------------------
#
# The job id names both a systemd unit and a remote directory. Anything that
# could break out of either -- path separators, traversal, a shell metacharacter,
# an over-long name, or a leading dash that systemd would read as an option --
# must be refused before anything is created or removed.
for hostile_id in \
  '../../etc/passwd' \
  'a/b' \
  '..' \
  '--property=CPUQuota=unbounded' \
  'job;rm -rf /' \
  "job\$(id)" \
  "$(printf 'x%.0s' {1..65})"; do
  if _remote_exec_check_job_id "$hostile_id" >/dev/null 2>&1; then
    note_failure "accepted a hostile job id: '${hostile_id}'"
  fi
done

for good_id in t_562a9a94 job-1 a.b_c-9 A1; do
  _remote_exec_check_job_id "$good_id" >/dev/null 2>&1 ||
    note_failure "rejected a legitimate job id: '${good_id}'"
done

echo "  ✅ job ids are constrained to a unit- and path-safe character set"

# --- the envelope can only ever narrow ----------------------------------------
#
# The owner authorized one specific ceiling. An override that asks for more must
# be pulled back to the ceiling, not honoured: these are the values a caller (or
# a job's own environment) supplies, and honouring them would silently make the
# job more privileged than the decision that authorized it.

clamp_cases=(
  "cpu:REMOTE_EXEC_CPU_PERCENT:500:200"
  "cpu:REMOTE_EXEC_CPU_PERCENT:50:50"
  "cpu:REMOTE_EXEC_CPU_PERCENT:notanumber:200"
  "runtime:REMOTE_EXEC_TIMEOUT_SEC:3600:900"
  "runtime:REMOTE_EXEC_TIMEOUT_SEC:60:60"
  "runtime:REMOTE_EXEC_TIMEOUT_SEC::900"
  # Nice is inverted: everything below the authorized 10 is a *higher* CPU
  # priority and must be raised to 10, while a lower-priority (larger) request
  # is honored up to systemd's own maximum of 19.
  "nice:REMOTE_EXEC_NICE:0:10"
  "nice:REMOTE_EXEC_NICE:5:10"
  "nice:REMOTE_EXEC_NICE:9:10"
  "nice:REMOTE_EXEC_NICE:10:10"
  "nice:REMOTE_EXEC_NICE:15:15"
  "nice:REMOTE_EXEC_NICE:19:19"
  "nice:REMOTE_EXEC_NICE:20:19"
  "nice:REMOTE_EXEC_NICE:99:19"
  "nice:REMOTE_EXEC_NICE:notanumber:10"
  "nice:REMOTE_EXEC_NICE::10"
  "nice:REMOTE_EXEC_NICE:18446744073709551617:19"
  "io:REMOTE_EXEC_IO_WEIGHT:100:10"
  "io:REMOTE_EXEC_IO_WEIGHT:1:1"
  "mem:REMOTE_EXEC_MEMORY_MAX:32G:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:512M:512M"
  "mem:REMOTE_EXEC_MEMORY_MAX:4G:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:1T:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:garbage:4G"
  # Every accepted suffix, at and around the boundary.
  "mem:REMOTE_EXEC_MEMORY_MAX:1024K:1024K"
  "mem:REMOTE_EXEC_MEMORY_MAX:4096M:4096M"
  "mem:REMOTE_EXEC_MEMORY_MAX:4097M:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:1G:1G"
  "mem:REMOTE_EXEC_MEMORY_MAX:5G:4G"
  # Suffixes above the ceiling can never be narrower for any mantissa >= 1.
  "mem:REMOTE_EXEC_MEMORY_MAX:1P:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:1T:4G"
  # Overflow-sized inputs that used to wrap into the accepted range.
  "mem:REMOTE_EXEC_MEMORY_MAX:17179869184G:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:18446744073709551617:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:99999999999999999999K:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:4294967296:4294967296"
  "mem:REMOTE_EXEC_MEMORY_MAX:4294967297:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:0:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:-1G:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:4g:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:1.5G:4G"
  "artifacts:REMOTE_EXEC_MAX_ARTIFACT_BYTES:999999999999:67108864"
  "artifacts:REMOTE_EXEC_MAX_ARTIFACT_BYTES:1024:1024"
)

for case_spec in "${clamp_cases[@]}"; do
  IFS=':' read -r kind var value expected <<<"$case_spec"
  case "$kind" in
    cpu) fn=_remote_exec_effective_cpu_percent ;;
    runtime) fn=_remote_exec_effective_runtime_sec ;;
    nice) fn=_remote_exec_effective_nice ;;
    io) fn=_remote_exec_effective_io_weight ;;
    mem) fn=_remote_exec_effective_memory_max ;;
    artifacts) fn=_remote_exec_effective_artifact_cap ;;
  esac
  # Run in a subshell with the variable assigned, because `env` can only start an
  # external command and these are shell functions.
  actual="$(
    set +u
    if [[ -n "$value" ]]; then
      export "$var=$value"
    else
      unset "$var"
    fi
    "$fn"
  )"
  if [[ "$actual" != "$expected" ]]; then
    note_failure "${fn} with ${var}=${value:-<unset>} gave '${actual}', want '${expected}'"
  fi
done

# Defaults with nothing set at all must be exactly the authorized envelope.
if [[ "$(_remote_exec_effective_cpu_percent)" != "200" ]]; then
  note_failure "default CPU ceiling is not 200"
fi
if [[ "$(_remote_exec_effective_memory_max)" != "4G" ]]; then
  note_failure "default memory ceiling is not 4G"
fi
if [[ "$(_remote_exec_effective_runtime_sec)" != "900" ]]; then
  note_failure "default runtime ceiling is not 900s"
fi

echo "  ✅ every knob clamps to the authorized ceiling or below"

# --- the runner asks for exactly the envelope --------------------------------
#
# The limits are not a comment: they must appear in the systemd-run invocation
# the helper actually issues, or the box is unprotected no matter what the
# header says.
runner_source="$TESTS_REPO_ROOT/scripts/helpers/remote-exec.sh"
for required in \
  '--property=CPUQuota=' \
  '--property=MemoryMax=' \
  '--property=RuntimeMaxSec=' \
  '--property=Nice=' \
  '--property=IOWeight=' \
  '--property=Type=exec' \
  '--unit='; do
  rg -qF -- "$required" "$runner_source" ||
    note_failure "the remote runner does not request ${required}"
done

# The job script must reach the server as a staged file, never inside a command
# line, where agent-supplied text would be re-parsed by the remote shell.
if ! rg -qF 'chmod 0500' "$runner_source"; then
  note_failure "the staged job script is not made non-writable before it runs"
fi
if rg -qF 'bash -c "$job_script"' "$runner_source"; then
  note_failure "the job script appears to be interpolated into a remote command line"
fi

echo "  ✅ the remote runner requests the whole envelope and stages the script as a file"

# --- REMOTE_EXEC=0 keeps the suite hermetic -----------------------------------

start=$SECONDS
if REMOTE_EXEC=0 REMOTE_EXEC_HOST="dsaw@192.0.2.1" \
  remote_exec_run 't_disabled' 'echo hi' >/dev/null 2>&1; then
  note_failure "REMOTE_EXEC=0 still attempted to run a job"
fi
elapsed=$(( SECONDS - start ))
if ((elapsed > 10)); then
  note_failure "REMOTE_EXEC=0 appears to have attempted the network (${elapsed}s)"
fi

echo "  ✅ REMOTE_EXEC=0 refuses to run remotely without touching the network"

# --- an unreachable target fails closed ---------------------------------------
#
# An unreachable target must be non-zero, must say why on stderr, and must print
# nothing on stdout that a caller could mistake for a result. REMOTE_EXEC_HOST is
# pointed at a blackhole so this stays offline, and the memoized target is reset
# so the override is actually consulted.
remote_exec_host=""
stdout_file="$test_root/unreachable.out"
stderr_file="$test_root/unreachable.err"
if REMOTE_EXEC_HOST="dsaw@192.0.2.1" \
  remote_exec_run 't_unreachable' 'echo hi' \
  >"$stdout_file" 2>"$stderr_file"; then
  note_failure "an unreachable target did not fail closed"
fi

if [[ -s "$stdout_file" ]]; then
  note_failure "an unreachable target produced stdout: $(cat "$stdout_file")"
fi
grep -q "not reachable" "$stderr_file" ||
  note_failure "an unreachable target did not name the cause: $(cat "$stderr_file")"

echo "  ✅ an unreachable target fails closed with no stdout"

# --- mocked transport: success, artifacts, and the exit status ----------------
#
# The transport is a PATH shim rather than a shell function, because the helper
# runs ssh under `timeout`, which execs a real binary: a shell function would not
# shadow it and the test would silently reach the live server. The shim answers
# the real staging calls -- the archive claim in stage_archive_on_remote, the
# archive upload, the job-script write -- and then runs the staged job script the
# way the remote unit would. Nothing here contacts a server.
mock_bin="$test_root/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
# Stands in for ssh. Decides purely on the argument text.
set -uo pipefail
args="$*"
mock_dir="${MOCK_CTL:?}"

# Consuming stdin must never fail the shim: several callers pipe a heredoc that
# the matching branch never reads.
consume_stdin() { cat >/dev/null 2>&1 || true; }

case "$args" in
  # The two heredoc call sites are matched first, because they are the only ones
  # carrying a command, and they are also the only calls whose argument list
  # contains the remote archive path (the runner takes it as an operand) -- so a
  # looser archive pattern below would otherwise swallow them.
  #
  # The `du` and the `systemd-run` live in the stdin heredoc, not the argument
  # list, so the two `bash -s --` sites are told apart by how many operands
  # follow `--`: the runner passes 8, the sizing call passes at most 2. Counted
  # from the first `--` so ssh's own options are not counted.
  *"bash -s --"*)
    consume_stdin
    seen_sep=0
    operands=()
    for operand in "$@"; do
      if ((seen_sep)); then
        operands+=("$operand")
      elif [[ "$operand" == "--" ]]; then
        seen_sep=1
      fi
    done
    if ((${#operands[@]} <= 2)); then
      # The sizing call. This is the whole point of the offline regression:
      # the helper's own sizing heredoc, extracted verbatim from the shipped
      # source, is executed here against real files on disk. A shim that
      # invented a byte count out of a fixture file would hide a sizing bug --
      # which is exactly how a BEGIN-rule typo that reported 0 bytes for every
      # job passed this suite while it shipped.
      if [[ ! -r "${MOCK_SIZING:?}" ]]; then
        echo "mock ssh: no extracted sizing script" >&2
        exit 1
      fi
      # The operand list is passed through unchanged, so the extracted script
      # sees exactly the positional arguments the helper would send over ssh.
      bash "$MOCK_SIZING" "${operands[@]}" | tee "$mock_dir/sizing_log"
      exit "${PIPESTATUS[0]}"
    fi
    if [[ -f "/tmp/nixhomeserver-remote-exec.${mock_dir##*/}/job.sh" ]]; then
      # The remote runner creates source/ and results/ before running the job,
      # and exports the results path. The shim does the same so a job writing to
      # NIXHOMESERVER_REMOTE_EXEC_RESULTS_DIR behaves as it would remotely.
      job_root="/tmp/nixhomeserver-remote-exec.${mock_dir##*/}"
      mkdir -p "$job_root/source" "$job_root/results"
      (
        cd "$job_root/source"
        NIXHOMESERVER_REMOTE_EXEC_JOB_DIR="$job_root"
        NIXHOMESERVER_REMOTE_EXEC_RESULTS_DIR="$job_root/results"
        NIXHOMESERVER_REMOTE_EXEC_SOURCE_DIR="$job_root/source"
        export NIXHOMESERVER_REMOTE_EXEC_JOB_DIR \
          NIXHOMESERVER_REMOTE_EXEC_RESULTS_DIR NIXHOMESERVER_REMOTE_EXEC_SOURCE_DIR
        bash "$job_root/job.sh" 2>&1
      )
      exit $?
    fi
    exit 0
    ;;
  # The archive-claim call: the repo's staging helper reads the upload from
  # stdin and prints the absolute path it claimed.
  *"stage nixhomeserver-remote-exec"*)
    consume_stdin
    printf '/tmp/nixhomeserver-remote-exec-archive.MOCK\n'
    exit 0
    ;;
  # The archive upload itself.
  *"cat > /tmp/nixhomeserver-remote-exec-archive.MOCK"*)
    consume_stdin
    exit 0
    ;;
  # Reachability probe.
  *" true")
    exit 0
    ;;
  *"mktemp -d /tmp/nixhomeserver-remote-exec"*)
    # Must match the helper's containment guard, which refuses anything outside
    # /tmp/nixhomeserver-remote-exec.* -- that guard is part of the contract.
    printf '/tmp/nixhomeserver-remote-exec.%s\n' "${mock_dir##*/}"
    exit 0
    ;;
  # The job script write: this is the script the job will run.
  *"cat > /tmp/nixhomeserver-remote-exec.${mock_dir##*/}/job.sh"*)
    mkdir -p "/tmp/nixhomeserver-remote-exec.${mock_dir##*/}"
    cat >"/tmp/nixhomeserver-remote-exec.${mock_dir##*/}/job.sh"
    exit 0
    ;;
  *chmod*)
    consume_stdin
    exit 0
    ;;
  # Artifact tar stream. The helper untars this locally, so the shim must emit a
  # real archive -- an empty stream would fail the local extraction and hide
  # whether the cap logic is right.
  *"-cf - ."*)
    tar -C "/tmp/nixhomeserver-remote-exec.${mock_dir##*/}/results" -cf - . 2>/dev/null
    exit 0
    ;;
  # Cleanup.
  *"rm -rf"*)
    consume_stdin
    # Record that a reap happened, so the test can assert the job directory does
    # not outlive the call. The directory itself is left in place because the
    # artifact fetch reads it before the reap.
    : >"${MOCK_CTL}/reaped"
    exit 0
    ;;
esac
cat >/dev/null 2>&1 || true
exit 0
MOCK_SSH
sed -i "1s|.*|#!$(type -P bash)|" "$mock_bin/ssh"
chmod +x "$mock_bin/ssh"

mock_dir="$test_root/jobdir"
rm -rf "$mock_dir"
mkdir -p "$mock_dir"
# The shim writes into the real /tmp namespace because the helper's containment
# guard requires it; the EXIT trap removes it.
rm -rf "/tmp/nixhomeserver-remote-exec.${mock_dir##*/}"
mock_job_glob="/tmp/nixhomeserver-remote-exec.${mock_dir##*/}"
export MOCK_CTL="$mock_dir"

# Extract the sizing heredoc from the shipped source and run it for real, so the
# offline regression exercises the code that actually sizes a job's artifacts.
# The call site is located by the assignment it feeds rather than by its exact
# operand list, so the check survives a change in how the cap is passed and only
# fails when the sizing code itself is moved or renamed.
sizing_script="$mock_dir/sizing.sh"
if ! awk '/artifact_size=/ { seen = 1 }
         seen && /^REMOTE_EOF$/ { exit }
         seen && /bash -s --/ { body = 1; next }
         body { print }' "$runner_source" >"$sizing_script"; then
  echo "❌ could not read the sizing heredoc from ${runner_source}" >&2
  exit 1
fi
if [[ ! -s "$sizing_script" ]] || ! grep -q 'du -sb' "$sizing_script"; then
  echo "❌ extracted sizing script is missing its du/awk body:" >&2
  cat "$sizing_script" >&2
  exit 1
fi
chmod +x "$sizing_script"
export MOCK_SIZING="$sizing_script"

mock_orig_path="$PATH"
export PATH="$mock_bin:$PATH"

output="$(remote_exec_run 't_mockok' 'echo hello-remote' \
  2>"$test_root/mock.err")" ||
  note_failure "a mocked successful job did not succeed: $(cat "$test_root/mock.err")"

grep -q "hello-remote" <<<"$output" ||
  note_failure "the remote job's stdout did not reach the caller: ${output}"

echo "  ✅ a successful job returns its output"

# The remote job's own exit status must survive: a caller that saw 0 for a failed
# job would treat a broken command as a passing one.
if remote_exec_run 't_mockfail' 'echo on-stdout; exit 42' \
  >"$test_root/fail.out" 2>"$test_root/fail.err"; then
  note_failure "a job that exited 42 was reported as success"
fi
grep -q "on-stdout" "$test_root/fail.out" ||
  note_failure "a failing job's stdout was swallowed: $(cat "$test_root/fail.out")"
grep -q "exited 42" "$test_root/fail.err" ||
  note_failure "the failing job's exit status was not reported: $(cat "$test_root/fail.err")"

echo "  ✅ a failing job propagates its remote exit status"

# EX_TEMPFAIL (75) is how the unit reports a busy slot. The unit's own stderr is
# discarded by the runner, so the helper itself must name the cause and must not
# report the run as a success.
if remote_exec_run 't_slotbusy' 'exit 75' \
  >"$test_root/slotbusy.out" 2>"$test_root/slotbusy.err"; then
  note_failure "a job that exited 75 was reported as success"
fi
grep -q "another job already holds the server slot" "$test_root/slotbusy.err" ||
  note_failure "the helper did not name the busy slot for an EX_TEMPFAIL run: $(cat "$test_root/slotbusy.err")"
grep -q "exited 75" "$test_root/slotbusy.err" ||
  note_failure "the helper did not report the EX_TEMPFAIL status: $(cat "$test_root/slotbusy.err")"

echo "  ✅ EX_TEMPFAIL from the unit is reported as a busy slot"

# --- artifacts come back, and the cap refuses to transfer ----------------------

remote_exec_run 't_artifacts' \
  'printf "artifact-body\n" > "$NIXHOMESERVER_REMOTE_EXEC_RESULTS_DIR/report.txt"' \
  >/dev/null 2>"$test_root/art.err" ||
  note_failure "an artifact-producing job did not succeed: $(cat "$test_root/art.err")"

results_dir="$test_root/results"
rm -rf "$results_dir"
REMOTE_EXEC_RESULTS_DIR="$results_dir" remote_exec_run 't_fetch' \
  'printf "artifact-body\n" > "$NIXHOMESERVER_REMOTE_EXEC_RESULTS_DIR/report.txt"' \
  >/dev/null 2>"$test_root/fetch.err" ||
  note_failure "an artifact-producing job did not succeed: $(cat "$test_root/fetch.err")"

# The round trip is the point: a deliverable must actually arrive on the
# workstation, because nothing syncs a working tree back over plain SSH.
if [[ ! -f "$results_dir/report.txt" ]]; then
  note_failure "the job's artifact did not arrive in ${results_dir}: $(ls -A "$results_dir" 2>&1)"
elif [[ "$(cat "$results_dir/report.txt")" != "artifact-body" ]]; then
  note_failure "the returned artifact has the wrong contents: $(cat "$results_dir/report.txt")"
fi

# The sizing call must report the size of the tree it actually measured. A run
# that returned 0 here would skip the transfer and leave nothing behind, which
# is the defect these assertions exist to catch.
expected_size="$(du -sb "$results_dir" | awk '{ print $1 + 0 }')"
if ((expected_size == 0)); then
  note_failure "the fetched artifact set is unexpectedly empty"
elif [[ ! -f "$MOCK_CTL/sizing_log" ]]; then
  note_failure "the mocked transport never recorded a sizing call"
elif ! grep -qx "$expected_size" "$MOCK_CTL/sizing_log"; then
  note_failure "the sizing heredoc reported '${expected_size}'-less output: $(cat "$MOCK_CTL/sizing_log")"
fi

# An empty results tree sizes as 0 bytes, and the transport must not be asked for
# an empty archive: 0 must reach the cap comparison rather than a failure. The
# tree is cleaned first so it is genuinely empty and not left over from an
# earlier job in this suite.
mkdir -p "$mock_job_glob/results"
find "$mock_job_glob/results" -mindepth 1 -delete
"$MOCK_SIZING" "$mock_job_glob" >"$mock_dir/empty.size" 2>"$mock_dir/empty.err" ||
  note_failure "the sizing heredoc failed on an empty results dir: $(cat "$mock_dir/empty.err")"
if [[ "$(cat "$mock_dir/empty.size")" != "0" ]]; then
  note_failure "an empty artifact set did not size as 0: $(cat "$mock_dir/empty.size")"
fi

# And it must fail, not report a plausible zero, when the results tree is gone --
# du and awk share a pipe under pipefail, so a missing directory is a failure.
if "$MOCK_SIZING" "$mock_dir/no-such-job" >"$mock_dir/missing.out" \
  2>"$mock_dir/missing.err"; then
  note_failure "the sizing heredoc accepted a missing results directory"
fi

echo "  ✅ a job's declared artifacts come back to the workstation"

# The job directory must be reaped on the success path too. A remote runner that
# cleaned up on its own exit would delete the very results/ directory the artifact
# fetch reads -- the bug that made every real run report a sizing failure -- so
# this asserts the ordering: fetch, then reap.
if [[ ! -f "$MOCK_CTL/reaped" ]]; then
  note_failure "a successful run did not reap its remote job directory"
fi

# And on the failure path, or an abandoned run leaks source and results.
rm -f "$MOCK_CTL/reaped"
remote_exec_run 't_reap' 'exit 7' >/dev/null 2>&1 || true
if [[ ! -f "$MOCK_CTL/reaped" ]]; then
  note_failure "a failing run did not reap its remote job directory"
fi
rm -f "$MOCK_CTL/reaped"

echo "  ✅ the remote job directory is reaped on both the success and failure paths"

# An oversized artifact set must be refused against a real tree, not a fixture
# count. The job writes just over the cap, and the helper's own sizing code
# measures it.
oversize_cap=1024
remote_exec_run 't_toobigseed' \
  "printf 'x%.0s' {1..$((oversize_cap + 1))} > \"\$NIXHOMESERVER_REMOTE_EXEC_RESULTS_DIR/big.bin\"" \
  >/dev/null 2>"$test_root/seed.err" ||
  note_failure "could not stage an oversized artifact set: $(cat "$test_root/seed.err")"

big_size="$(du -sb "$mock_job_glob/results" | awk '{ print $1 + 0 }')"
if ((big_size <= oversize_cap)); then
  note_failure "the staged oversized tree is only ${big_size} bytes, not over ${oversize_cap}"
fi
rm -f "$MOCK_CTL/sizing_log" "$MOCK_CTL/reaped"
if REMOTE_EXEC_MAX_ARTIFACT_BYTES="$oversize_cap" \
  REMOTE_EXEC_RESULTS_DIR="$test_root/toobig" \
  remote_exec_run 't_toobig' 'echo x' \
  >"$test_root/big.out" 2>"$test_root/big.err"; then
  note_failure "an oversized artifact set was accepted"
fi
grep -q "refusing to transfer" "$test_root/big.err" ||
  note_failure "an oversized artifact set did not say why: $(cat "$test_root/big.err")"
grep -q "over the ${oversize_cap}-byte cap" "$test_root/big.err" ||
  note_failure "the refusal did not name the cap it used: $(cat "$test_root/big.err")"
grep -qx "$big_size" "$MOCK_CTL/sizing_log" ||
  note_failure "the cap check ran against a supplied count, not the measured ${big_size}: $(cat "$MOCK_CTL/sizing_log" 2>&1)"
if [[ -e "$test_root/toobig" ]]; then
  note_failure "an oversized artifact set was still transferred: $(ls -A "$test_root/toobig" 2>&1)"
fi
if [[ ! -f "$MOCK_CTL/reaped" ]]; then
  note_failure "a refused oversized artifact set did not reap its job directory"
fi

echo "  ✅ an oversized artifact set is refused rather than transferred"

# Restore PATH before the EXIT trap runs rm, or cleanup cannot find it.
export PATH="${mock_orig_path}"
unset MOCK_CTL MOCK_SIZING
rm -rf "$mock_dir"

# --- the single-job slot is owned by the unit, not the launcher ----------------
#
# The slot lock used to live in the ssh runner, which holds it only while it
# waits on systemd-run. A transient unit does not inherit the runner's
# descriptors, so a dropped connection or a client-side timeout released the
# slot while the unit it had started kept running -- and the next job could
# overlap the first inside its 900 s allowance. The lock must belong to a
# process whose lifetime is the job's.
#
# The wrapper below is extracted verbatim from the shipped runner and driven
# against real processes and real flock, so this is a lifecycle test of the
# shipped mechanism rather than of a mock. Only its lock path is redirected to a
# per-test file, because this suite runs in parallel with other tests and the
# shipped path is a fixed global; the shipped path itself is pinned by an
# assertion below.

slot_lock="$test_root/slot.lock"
slot_script="$test_root/slot.sh"
if ! awk "/<<'SLOT_EOF'/{body=1;next} body && /^SLOT_EOF\$/{exit} body{print}" \
  "$runner_source" >"$slot_script"; then
  echo "❌ could not read the unit slot wrapper from ${runner_source}" >&2
  exit 1
fi
if [[ ! -s "$slot_script" ]] || ! grep -q 'flock -n 9' "$slot_script"; then
  echo "❌ the unit slot wrapper is missing its lock acquisition:" >&2
  cat "$slot_script" >&2
  exit 1
fi
grep -q 'another job already holds the server slot' "$slot_script" ||
  note_failure "the unit slot wrapper no longer names the refused slot"
sed -i "s#/tmp/nixhomeserver-remote-exec.lock#${slot_lock}#g" "$slot_script"
chmod +x "$slot_script"

# The unit, not the runner, must hold the slot: the wrapper must exist, the unit
# must be launched through it, the shipped lock path must be the wrapper's, and
# the slot fd must be opened exactly once -- in the wrapper, never in the runner.
rg -qF "<<'SLOT_EOF'" "$runner_source" ||
  note_failure "the runner no longer stages a unit-owned slot wrapper"
rg -qF '"$bash_path" "$remote_dir/slot.sh" "$bash_path" "$remote_dir/job.sh"' "$runner_source" ||
  note_failure "the unit is not launched through the slot wrapper"
rg -qF 'exec 9>/tmp/nixhomeserver-remote-exec.lock' "$runner_source" ||
  note_failure "the slot wrapper does not open the shipped lock path"
slot_fd_opens="$(rg -c 'exec 9>' "$runner_source" 2>/dev/null || true)"
[[ "$slot_fd_opens" == "1" ]] ||
  note_failure "the slot lock fd is opened ${slot_fd_opens:-0} time(s); it must live only in the unit wrapper"

if [[ ! -s "$slot_script" ]] || ! rg -qF "$slot_lock" "$slot_script"; then
  echo "❌ the extracted slot wrapper was not redirected to a per-test lock" >&2
  exit 1
fi

bash_bin="$(type -P bash)"
unit_pid_file="$test_root/unit.pid"
unit_ready="$test_root/unit.ready"
launcher_script="$test_root/launcher.sh"

# The launcher stands in for the ssh runner: it starts the unit and then waits,
# exactly as the real launcher blocks in systemd-run --wait. The unit's job
# writes $unit_ready only after slot.sh has taken the lock, so the marker proves
# the slot is held without this test ever racing the unit for the lock file.
cat >"$launcher_script" <<LAUNCH_EOF
#!${bash_bin}
set -uo pipefail
setsid "${bash_bin}" "${slot_script}" "${bash_bin}" -c \
  'printf started > "\$1"; sleep 120' _ "${unit_ready}" &
echo \$! >"${unit_pid_file}"
wait
LAUNCH_EOF
chmod +x "$launcher_script"

slot_held() { ! flock -n "$slot_lock" true 2>/dev/null; }
wait_for_unit() {
  local i
  for ((i = 0; i < 250; i++)); do
    [[ -f "$unit_ready" ]] && return 0
    sleep 0.02
  done
  return 1
}
wait_slot_free() {
  local i
  for ((i = 0; i < 250; i++)); do
    if flock -n "$slot_lock" true 2>/dev/null; then return 0; fi
    sleep 0.02
  done
  return 1
}

# A second job must be refused with EX_TEMPFAIL and the busy-slot message.
deny_check() {
  local when="$1" status
  if "${bash_bin}" "$slot_script" true >/dev/null 2>"$test_root/deny.err"; then
    note_failure "a second job was admitted ${when}"
  else
    status=$?
    ((status == 75)) ||
      note_failure "a refused job exited ${status} ${when}, want 75"
  fi
  grep -q 'another job already holds the server slot' "$test_root/deny.err" ||
    note_failure "the refusal ${when} did not name the busy slot"
}

start_unit() {
  rm -f "$unit_ready" "$unit_pid_file"
  "$launcher_script" &
  launcher_pid=$!
  wait_for_unit || note_failure "a started unit never reached its job"
  unit_pid="$(cat "$unit_pid_file" 2>/dev/null || true)"
  slot_held || note_failure "the unit's job ran without the slot held"
}

stop_unit() {
  if [[ -n "$unit_pid" ]]; then
    kill -KILL -- "-${unit_pid}" 2>/dev/null || true
  fi
  if [[ -n "$launcher_pid" ]]; then
    kill -KILL "$launcher_pid" 2>/dev/null || true
  fi
  unit_pid=""
  launcher_pid=""
  wait 2>/dev/null || true
  wait_slot_free || note_failure "the slot was not released after the unit ended"
}

# Round 1: the ordinary connected run, then launcher loss. The unit must still
# hold the slot after the launcher is gone.
start_unit
deny_check "while a unit held the slot"
kill -KILL "$launcher_pid" 2>/dev/null || true
wait "$launcher_pid" 2>/dev/null || true
launcher_pid=""
sleep 0.1
kill -0 "$unit_pid" 2>/dev/null ||
  note_failure "the unit did not survive its launcher"
slot_held || note_failure "the slot was released when the launcher died"
deny_check "after the launcher died but the unit still ran"
stop_unit

# Round 2: client timeout. The helper wraps the launcher in `timeout`, so a
# wall-clock expiry kills the launcher while the unit runs on; --foreground
# keeps timeout from signalling anything but the launcher itself.
rm -f "$unit_ready" "$unit_pid_file"
timeout --foreground -s KILL 1 "$launcher_script" >/dev/null 2>&1 &
launcher_pid=$!
wait_for_unit || note_failure "a unit started under timeout never reached its job"
unit_pid="$(cat "$unit_pid_file" 2>/dev/null || true)"
slot_held || note_failure "the unit ran without the slot held (timeout round)"
for ((i = 0; i < 250; i++)); do
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.02
done
wait "$launcher_pid" 2>/dev/null || true
launcher_pid=""
kill -0 "$unit_pid" 2>/dev/null ||
  note_failure "the unit did not survive the client timeout"
slot_held || note_failure "the slot was released when the client timeout fired"
deny_check "after the client timeout killed the launcher"
stop_unit

echo "  ✅ the single-job slot is owned by the unit, not the launcher"

# --- summary -----------------------------------------------------------------

if ((failures > 0)); then
  echo "❌ remote-exec helper regression test failed (${failures} check(s))" >&2
  exit 1
fi

echo "✅ remote-exec helper regression test passed"
