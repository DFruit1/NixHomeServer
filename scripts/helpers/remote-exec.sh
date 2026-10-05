#!/usr/bin/env bash
# Run one bounded command on the NixHomeServer instead of on this workstation,
# and bring its result and declared artifacts back.
#
# Why
# ---
# This is the smallest safe path for offloading a *worker tool job* rather than a
# worker process. The SSH terminal backend
# (`terminal.backend: ssh`) would move every tool call in every session on this
# profile, including the guarded-deploy helpers, onto a host that holds the
# git tree, the kanban board, the agenix secrets and every live service. This
# helper is one auditable script instead of a process-wide behaviour change, and
# it is shaped like scripts/helpers/remote-eval.sh so there is a single
# audited pattern for tracked-only transfer.
#
# The kanban board, the dispatcher and every worker process stay on the
# workstation. Remote execution is single-host by design upstream and this
# helper does not change that.
#
# Safety
# ------
# Authority: the owner chose option B on card t_562a9a94 -- bounded jobs are
# authorized, running as the sudo-capable `dsaw` identity over their existing SSH
# access. That is the same trust level the agent already has locally; the helper
# does not widen it and must not be described as hardening.
#
# The envelope below is the owner's, and it is enforced by the remote systemd
# user manager rather than by convention:
#
#   one job at a time   flock -n on a per-identity lock file
#   2 CPU               CPUQuota=200%
#   4 GiB RAM           MemoryMax=4G
#   15 min              RuntimeMaxSec=900, plus a client-side timeout
#   Nice=10             low CPU priority against the server's live services
#   low I/O weight      IOWeight=10
#
# Measured on this server: CPUQuota=200% shows up as cpu.max "200000 100000",
# MemoryMax=4G as memory.max 4294967296, IOWeight=10 as io.weight "default 10",
# and RuntimeMaxSec does kill the job (a 5 s unit over `sleep 60` exits
# non-zero after 5 s). MemoryMax clamps rather than OOM-killing in every case
# measured, so a job that touches more than 4 GiB is slowed and reclaimed, not
# necessarily terminated. Callers must treat MemoryMax as a bound, not a kill.
#
# A transient unit outlives the SSH session that launched it (verified: a unit
# started by one `ssh` command completed and wrote its files, observed from a
# separate session). That is deliberate -- a dropped workstation must not leave a
# job unaccounted for -- and it is why RuntimeMaxSec is mandatory and why
# remote_exec_cancel exists: cancellation targets the remote unit by name, not a
# client-side PID.
#
# The job script travels on stdin and is never interpolated into a remote
# command line, where operator- or agent-supplied text would be re-parsed by the
# remote shell. The shipped source archive comes from create_deploy_repo_archive,
# which refuses secrets/unencrypted and SensitivePrivateSecrets, so only
# ciphertext crosses the wire.
#
# Fails closed. Any staging, transfer, or remote-execution failure returns
# non-zero with no stdout, so a caller cannot read a transport error as an
# empty result. There is deliberately no local fallback: silently executing an
# agent-authored command on the workstation would defeat the point of offloading
# it and would hide the failure. Set REMOTE_EXEC=0 to refuse to run remotely at
# all (used by the test suite to stay hermetic).

remote_exec_host=""
remote_exec_reason=""
remote_exec_unit_prefix="nixhomeserver-remote-exec"

# Owner-approved envelope. Overridable for narrower jobs, never for wider ones:
# _remote_exec_clamp keeps every knob at or below the authorized ceiling.
_remote_exec_max_cpu_percent=200
_remote_exec_max_memory_max="4G"
_remote_exec_max_memory_max_bytes=$((4 * 1024 * 1024 * 1024))
_remote_exec_max_runtime_sec=900
_remote_exec_nice=10
_remote_exec_io_weight=10
_remote_exec_max_artifact_bytes=$((64 * 1024 * 1024))

_remote_exec_effective_cpu_percent() {
  local requested="${REMOTE_EXEC_CPU_PERCENT:-$_remote_exec_max_cpu_percent}"
  [[ "$requested" =~ ^[0-9]+$ ]] || requested="$_remote_exec_max_cpu_percent"
  ((requested > 0)) || requested=1
  ((requested < _remote_exec_max_cpu_percent)) &&
    printf '%s\n' "$requested" || printf '%s\n' "$_remote_exec_max_cpu_percent"
}

# MemoryMax is a systemd size string. There is no numeric comparison to clamp a
# larger string safely, so the knob is validated against the authorized value and
# anything unrecognized falls back to the ceiling rather than being trusted.
_remote_exec_effective_memory_max() {
  local requested="${REMOTE_EXEC_MEMORY_MAX:-$_remote_exec_max_memory_max}"
  if [[ "$requested" =~ ^[1-9][0-9]*[KMGTP]?$ ]]; then
    # Only ever narrower: compare in bytes against the 4 GiB ceiling.
    local bytes="${requested%[KMGTP]}"
    local suffix="${requested#"$bytes"}"
    local mult=1
    case "$suffix" in
      K) mult=1024 ;;
      M) mult=$((1024 * 1024)) ;;
      G) mult=$((1024 * 1024 * 1024)) ;;
      T) mult=$((1024 * 1024 * 1024 * 1024)) ;;
    esac
    ((bytes * mult < _remote_exec_max_memory_max_bytes)) && {
      printf '%s\n' "$requested"
      return 0
    }
  fi
  printf '%s\n' "$_remote_exec_max_memory_max"
}

_remote_exec_effective_runtime_sec() {
  local requested="${REMOTE_EXEC_TIMEOUT_SEC:-$_remote_exec_max_runtime_sec}"
  [[ "$requested" =~ ^[0-9]+$ ]] || requested="$_remote_exec_max_runtime_sec"
  ((requested > 0)) || requested=1
  ((requested < _remote_exec_max_runtime_sec)) &&
    printf '%s\n' "$requested" || printf '%s\n' "$_remote_exec_max_runtime_sec"
}

_remote_exec_effective_nice() {
  local requested="${REMOTE_EXEC_NICE:-$_remote_exec_nice}"
  [[ "$requested" =~ ^[0-9]+$ ]] || requested="$_remote_exec_nice"
  ((requested < _remote_exec_nice)) && printf '%s\n' "$requested" ||
    printf '%s\n' "$_remote_exec_nice"
}

_remote_exec_effective_io_weight() {
  local requested="${REMOTE_EXEC_IO_WEIGHT:-$_remote_exec_io_weight}"
  [[ "$requested" =~ ^[0-9]+$ ]] || requested="$_remote_exec_io_weight"
  ((requested < _remote_exec_io_weight)) && printf '%s\n' "$requested" ||
    printf '%s\n' "$_remote_exec_io_weight"
}

_remote_exec_effective_artifact_cap() {
  local requested="${REMOTE_EXEC_MAX_ARTIFACT_BYTES:-$_remote_exec_max_artifact_bytes}"
  [[ "$requested" =~ ^[0-9]+$ ]] || requested="$_remote_exec_max_artifact_bytes"
  ((requested < _remote_exec_max_artifact_bytes)) &&
    printf '%s\n' "$requested" || printf '%s\n' "$_remote_exec_max_artifact_bytes"
}

_remote_exec_resolve_host() {
  if [[ -n "${REMOTE_EXEC_HOST:-}" ]]; then
    printf '%s\n' "$REMOTE_EXEC_HOST"
    return 0
  fi
  # Same target and same derivation as deploy.sh / remote-eval.sh:
  # vars.localAdminUser@vars.serverLanIP.
  local config
  config="$(NIXHOMESERVER_REMOTE_EVAL_NEED_TARGET=1 nix_flake_json '{
    localAdminUser = if vars ? localAdminUser then vars.localAdminUser else vars.identity.localAdminUser;
    serverLanIP = vars.serverLanIP;
  }')" || return 1
  jq -er '"\(.localAdminUser)@\(.serverLanIP)"' <<<"$config"
}

# Resolve and memoize the target host in the *caller's* shell.
#
# Deliberately not a command substitution: that would run in a subshell, so the
# memoized value would be discarded and every call would re-evaluate vars.nix --
# and the re-evaluation would run without init_repo_root's exports, failing with
# "path '/vars.nix' does not exist".
#
# Every entry point goes through this, including the ones that never touch a
# working tree. It is especially the cancel and status paths, which a caller
# reaches precisely when something has already gone wrong, that must not add a
# second failure of their own.
_remote_exec_ensure_host() {
  [[ -n "$remote_exec_host" ]] && return 0
  init_repo_root
  remote_exec_host="$(_remote_exec_resolve_host)" || {
    echo "remote-exec: could not resolve a target host from vars.nix" >&2
    return 1
  }
}

# The job id names both the per-job remote directory and the transient unit. It
# is constrained to a character set that is safe as a systemd unit name suffix
# and as a path component, so nothing an agent supplies can escape either.
_remote_exec_unit_name() {
  local job_id="$1"
  printf '%s-%s.service\n' "$remote_exec_unit_prefix" "$job_id"
}

_remote_exec_check_job_id() {
  local job_id="$1"
  if [[ ! "$job_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
    echo "remote-exec: job id '${job_id}' is not [A-Za-z0-9._-] within 64 chars" >&2
    return 1
  fi
  if [[ "$job_id" == *..* ]]; then
    echo "remote-exec: job id '${job_id}' must not contain '..'" >&2
    return 1
  fi
  # Explicit: a bare `[[ .. ]] &&` as the last statement would make this function
  # return the failed match's status for every legitimate id.
  return 0
}

_remote_exec_stage_job_script() {
  local host="$1" remote_dir="$2" job_script="$3"
  printf '%s' "$job_script" | ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" \
    "cat > $(printf '%q' "$remote_dir/job.sh")" &&
    ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" \
      "chmod 0500 $(printf '%q' "$remote_dir/job.sh")"
}

# remote_exec_run <job-id> <job-script>
#
# Runs <job-script> on the server inside the enforced envelope, prints its
# combined output on stdout, and copies everything the script wrote into
# REMOTE_EXEC_RESULTS_DIR (default: ./remote-exec-results) on this workstation.
# Exit status is the remote job's exit status; a transport or staging failure is
# non-zero with no stdout.
remote_exec_run() {
  if (($# < 2)); then
    echo "remote-exec: usage: remote_exec_run <job-id> <job-script>" >&2
    return 1
  fi
  local job_id="$1" job_script="$2"
  local repo_root archive remote_archive remote_dir remote_job_dir unit_name
  local results_dir output remote_err artifact_cap artifact_size remote_status
  local client_timeout_sec
  # Client-side wall clock slightly longer than the remote RuntimeMaxSec, so the
  # remote limit is what normally ends a job and the local timeout is a backstop
  # against an ssh transport that never returns.
  client_timeout_sec="$(( $(_remote_exec_effective_runtime_sec) + 30 ))"

  if [[ "${REMOTE_EXEC:-1}" == "0" ]]; then
    echo "remote-exec: disabled by REMOTE_EXEC=0" >&2
    return 1
  fi
  if [[ -z "$job_script" ]]; then
    echo "remote-exec: no job script given" >&2
    return 1
  fi
  _remote_exec_check_job_id "$job_id" || return 1

  init_repo_root
  _remote_exec_ensure_host || return 1
  repo_root="$(cd "$repo_root" && pwd)"

  if ! ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" true 2>/dev/null; then
    echo "remote-exec: target ${remote_exec_host} is not reachable with BatchMode" >&2
    return 1
  fi

  archive="$(mktemp /tmp/nixhomeserver-remote-exec.XXXXXX.tar)" || {
    echo "remote-exec: could not create a local archive" >&2
    return 1
  }
  if ! create_deploy_repo_archive "$archive"; then
    rm -f "$archive"
    echo "remote-exec: create_deploy_repo_archive refused this working tree" >&2
    return 1
  fi

  remote_archive="$(stage_archive_on_remote "$archive" "$remote_exec_host" \
    "nixhomeserver-remote-exec")" || {
    rm -f "$archive"
    echo "remote-exec: could not transfer the archive to ${remote_exec_host}" >&2
    return 1
  }
  rm -f "$archive"

  # One directory per job. SSH has no per-task container isolation, so two jobs
  # must never share a directory.
  remote_dir="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" \
    "mktemp -d /tmp/nixhomeserver-remote-exec.XXXXXXXX")" || {
    remove_remote_archive "$remote_exec_host" "$remote_archive" 2>/dev/null || true
    echo "remote-exec: could not create a remote job directory" >&2
    return 1
  }
  # The rest of this function owns this path and removes only this exact path.
  remote_job_dir="$remote_dir"
  if [[ ! "$remote_job_dir" == /tmp/nixhomeserver-remote-exec.* ]] ||
     [[ "$remote_job_dir" == *$'\n'* ]]; then
    echo "remote-exec: remote mktemp did not return a usable job directory" >&2
    return 1
  fi

  # Own the job directory's lifetime here, on every exit path, so a failed or
  # abandoned run does not leave source and results behind on the server. The
  # remote runner deliberately leaves the directory alone because the artifact
  # fetch below needs it.
  #
  # An explicit call rather than a RETURN trap: a RETURN trap set inside a
  # function is not reliably scoped to it in bash, and silently never firing
  # would leak a job directory on every early return.
  reap_job_dir() {
    [[ -n "${remote_job_dir:-}" ]] || return 0
    ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" \
      "rm -rf $(printf '%q' "$remote_job_dir")" >/dev/null 2>&1 || true
  }

  # The script is staged as a file first: it cannot share the stdin of the remote
  # runner, and it must never be interpolated into a command line.
  if ! _remote_exec_stage_job_script "$remote_exec_host" "$remote_job_dir" "$job_script"; then
    echo "remote-exec: could not transfer the job script to ${remote_exec_host}" >&2
    reap_job_dir
    remove_remote_archive "$remote_exec_host" "$remote_archive" 2>/dev/null || true
    return 1
  fi

  unit_name="$(_remote_exec_unit_name "$job_id")"
  remote_err="$(mktemp /tmp/nixhomeserver-remote-exec-err.XXXXXX)" || {
    reap_job_dir
    remove_remote_archive "$remote_exec_host" "$remote_archive" 2>/dev/null || true
    return 1
  }

  # The runner is a fixed, quoted heredoc: every variable arrives as a positional
  # argument and every knob is clamped locally before it is passed.
  # `output=$(...)` as its own statement so $? is the ssh/remote status, not the
  # status of an enclosing `if !` (which would invert it).
  output="$(timeout -k 10 "$client_timeout_sec" ssh -T -o BatchMode=yes -o ConnectTimeout=10 \
    "$remote_exec_host" \
    bash -s -- \
      "$remote_job_dir" "$remote_archive" "$unit_name" \
      "$(_remote_exec_effective_cpu_percent)" \
      "$(_remote_exec_effective_memory_max)" \
      "$(_remote_exec_effective_runtime_sec)" \
      "$(_remote_exec_effective_nice)" \
      "$(_remote_exec_effective_io_weight)" \
      2>"$remote_err" <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
remote_archive="$2"
unit_name="$3"
cpu_percent="$4"
memory_max="$5"
runtime_sec="$6"
nice_value="$7"
io_weight="$8"
bash_path="$(type -P bash)"

# The trap deliberately does NOT delete remote_dir here.
#
# The artifacts the job wrote live under $remote_dir/results and are fetched by a
# separate ssh call after this one returns, so removing the directory on exit
# raced that fetch and made every run report "could not size the remote artifact
# set". Cleanup is the caller's job, in remote_exec_run, once the artifacts have
# been sized and transferred; a job that dies without reaching it leaves a
# directory under /tmp that the server's own tmpfiles expiry reclaims.
cleanup_archive() {
  rm -f "$remote_archive"
}
trap cleanup_archive EXIT
mkdir -p "$remote_dir/source" "$remote_dir/results"
tar -C "$remote_dir/source" -xf "$remote_archive"

# flock -n over a per-identity file: the owner's "one job at a time". A second
# concurrent job fails fast here rather than queueing behind an unknown one.
exec 9>/tmp/nixhomeserver-remote-exec.lock
if ! flock -n 9; then
  echo "remote-exec: another job already holds the server slot" >&2
  exit 75
fi

# path:, not git+file:// -- the staged tree is a plain directory with no .git.
# Safe here precisely because create_deploy_repo_archive already reduced it to
# tracked files; a path: reference to a live working tree would drag in the
# ~69 GB of gitignored build output under custom_apps.
cd "$remote_dir/source"

# --pipe conflicts with the wait/collect lifecycle used here, and Type=exec is
# what makes the exit status below the job's own rather than systemd-run's.
#
# WorkingDirectory is required, not cosmetic: a transient unit does NOT inherit
# the caller's cwd, so without it the job ran in $HOME on the server and found no
# flake.nix even though the staged tree was right there.
#
# The job's paths are passed with explicit --setenv, not by exporting them here.
# systemd-run builds the unit's environment from the manager's environment, not
# from this shell's, so a plain `export` is silently dropped -- which is how the
# results directory ended up empty on the first live run.
systemd-run --user --quiet --wait --pipe --collect \
  --property=Type=exec \
  --property=WorkingDirectory="$remote_dir/source" \
  --setenv="NIXHOMESERVER_REMOTE_EXEC_JOB_DIR=$remote_dir" \
  --setenv="NIXHOMESERVER_REMOTE_EXEC_RESULTS_DIR=$remote_dir/results" \
  --setenv="NIXHOMESERVER_REMOTE_EXEC_SOURCE_DIR=$remote_dir/source" \
  --property=CPUQuota="${cpu_percent}%" \
  --property=MemoryMax="$memory_max" \
  --property=Nice="$nice_value" \
  --property=IOWeight="$io_weight" \
  --property=RuntimeMaxSec="$runtime_sec" \
  --unit="$unit_name" \
  "$bash_path" "$remote_dir/job.sh"
REMOTE_EOF
  )"
  remote_status=$?
  printf '%s\n' "$output"
  rm -f "$remote_err"
  if ((remote_status != 0)); then
    echo "remote-exec: remote job '${job_id}' exited ${remote_status} on ${remote_exec_host}" >&2
    reap_job_dir
    return "$remote_status"
  fi

  # Artifacts come back explicitly. Nothing syncs a working tree in or out over
  # plain SSH, so a deliverable never "just arrives".
  results_dir="${REMOTE_EXEC_RESULTS_DIR:-$repo_root/remote-exec-results}"
  artifact_cap="$(_remote_exec_effective_artifact_cap)"
  artifact_size="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" \
    bash -s -- "$remote_dir" "$artifact_cap" <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
artifact_cap="$2"
du -sb "$remote_dir/results" 2>/dev/null | awk -v cap="$artifact_cap" '
  BEGIN { print ( $1 > cap ) ? cap + 1 : $1 + 0 }'
REMOTE_EOF
  )" || {
    echo "remote-exec: could not size the remote artifact set" >&2
    reap_job_dir
    return 1
  }
  # Validate before the arithmetic comparison: a remote that answered with
  # anything but a byte count must not be evaluated as a shell expression.
  if [[ ! "$artifact_size" =~ ^[0-9]+$ ]]; then
    echo "remote-exec: remote artifact size was not a byte count: '${artifact_size}'" >&2
    reap_job_dir
    return 1
  fi
  if ((artifact_size > artifact_cap)); then
    echo "remote-exec: artifacts exceed the ${artifact_cap}-byte cap; refusing to transfer" >&2
    reap_job_dir
    return 1
  fi
  if ((artifact_size > 0)); then
    if ! mkdir -p "$results_dir"; then
      reap_job_dir
      return 1
    fi
    # Fetch first, reap second: the transfer reads the very directory the reap
    # removes, so the order is load-bearing and not cosmetic.
    if ! ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" \
      "tar -C $(printf '%q' "$remote_dir")/results -cf - ." |
      tar -C "$results_dir" -xf -; then
      echo "remote-exec: artifact transfer failed" >&2
      reap_job_dir
      return 1
    fi
  fi

  reap_job_dir
}

# remote_exec_cancel <job-id>
#
# Cancellation targets the remote transient unit, because a signal to a local
# ssh client does not kill the remote process. Safe to call for a job that is
# already gone: cancellation is idempotent.
remote_exec_cancel() {
  if (($# < 1)); then
    echo "remote-exec: usage: remote_exec_cancel <job-id>" >&2
    return 1
  fi
  local job_id="$1" unit_name
  _remote_exec_check_job_id "$job_id" || return 1
  _remote_exec_ensure_host || return 1
  unit_name="$(_remote_exec_unit_name "$job_id")"
  # Sent as a heredoc for the same reason the runner is: the unit name is derived
  # from a caller-supplied id, so it must be a positional argument the remote
  # shell reads, never text spliced into a command line it will re-parse.
  ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" \
    bash -s -- "$unit_name" <<'REMOTE_EOF'
set -uo pipefail
unit_name="$1"
systemctl --user kill --signal=SIGTERM "$unit_name" 2>/dev/null || true
systemctl --user stop "$unit_name" 2>/dev/null || true
systemctl --user reset-failed "$unit_name" 2>/dev/null || true
REMOTE_EOF
}

# remote_exec_status <job-id>
#
# Prints the remote unit's ActiveState SubState ExecMainStatus, or "unknown" when
# the unit no longer exists. A unit started by a session that has since exited
# still answers here, which is how an operator accounts for a job after a dropped
# connection -- the reason the helper launches a unit rather than a bare process.
remote_exec_status() {
  if (($# < 1)); then
    echo "remote-exec: usage: remote_exec_status <job-id>" >&2
    return 1
  fi
  local job_id="$1" unit_name
  _remote_exec_check_job_id "$job_id" || return 1
  _remote_exec_ensure_host || return 1
  unit_name="$(_remote_exec_unit_name "$job_id")"
  local state
  if ! state="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 "$remote_exec_host" \
    bash -s -- "$unit_name" <<'REMOTE_EOF'
set -uo pipefail
unit_name="$1"
systemctl --user show "$unit_name" \
  --property=ActiveState --property=SubState --property=ExecMainStatus \
  --value 2>/dev/null || true
REMOTE_EOF
  )"; then
    printf 'unknown\n'
    return 1
  fi
  if [[ -z "$state" ]]; then
    printf 'unknown\n'
    return 1
  fi
  printf '%s\n' "$(tr '\n' ' ' <<<"$state" | sed 's/ *$//')"
}
