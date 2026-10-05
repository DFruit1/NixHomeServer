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
cleanup() {
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
  "nice:REMOTE_EXEC_NICE:0:0"
  "nice:REMOTE_EXEC_NICE:19:10"
  "io:REMOTE_EXEC_IO_WEIGHT:100:10"
  "io:REMOTE_EXEC_IO_WEIGHT:1:1"
  "mem:REMOTE_EXEC_MEMORY_MAX:32G:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:512M:512M"
  "mem:REMOTE_EXEC_MEMORY_MAX:4G:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:1T:4G"
  "mem:REMOTE_EXEC_MEMORY_MAX:garbage:4G"
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
  '--unit=' \
  'flock -n 9'; do
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
mock_artifact_size_file="${MOCK_CTL}/artifact_size"

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
  # follow `--`: the runner passes 8, the sizing call passes 2. Counted from the
  # first `--` so ssh's own options are not counted.
  *"bash -s --"*)
    consume_stdin
    seen_sep=0
    argc=0
    for operand in "$@"; do
      if ((seen_sep)); then
        argc=$((argc + 1))
      elif [[ "$operand" == "--" ]]; then
        seen_sep=1
      fi
    done
    if ((argc <= 2)); then
      cat "$mock_artifact_size_file"
      exit 0
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
printf '0\n' >"$MOCK_CTL/artifact_size"

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

# --- artifacts come back, and the cap refuses to transfer ----------------------

remote_exec_run 't_artifacts' \
  'printf "artifact-body\n" > "$NIXHOMESERVER_REMOTE_EXEC_RESULTS_DIR/report.txt"' \
  >/dev/null 2>"$test_root/art.err" ||
  note_failure "an artifact-producing job did not succeed: $(cat "$test_root/art.err")"

results_dir="$test_root/results"
printf '42\n' >"$MOCK_CTL/artifact_size"
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

printf "$((_remote_exec_max_artifact_bytes + 1))\n" >"$MOCK_CTL/artifact_size"
if REMOTE_EXEC_RESULTS_DIR="$test_root/toobig" remote_exec_run 't_toobig' 'echo x' \
  >"$test_root/big.out" 2>"$test_root/big.err"; then
  note_failure "an oversized artifact set was accepted"
fi
grep -q "exceed" "$test_root/big.err" ||
  note_failure "an oversized artifact set did not say why: $(cat "$test_root/big.err")"

echo "  ✅ an oversized artifact set is refused rather than transferred"

# Restore PATH before the EXIT trap runs rm, or cleanup cannot find it.
export PATH="${mock_orig_path}"
unset MOCK_CTL
rm -rf "$mock_dir"

# --- summary -----------------------------------------------------------------

if ((failures > 0)); then
  echo "❌ remote-exec helper regression test failed (${failures} check(s))" >&2
  exit 1
fi

echo "✅ remote-exec helper regression test passed"
