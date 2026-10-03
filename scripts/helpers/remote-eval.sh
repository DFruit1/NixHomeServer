#!/usr/bin/env bash
# Evaluate NixOS configuration on the NixHomeServer rather than on this
# workstation, and batch several queries into a single evaluation.
#
# Why
# ---
# Nix evaluates inside the local `nix` client. Configuring `builders` moves
# *builds* elsewhere; it does not move `nix eval`. nix-eval-jobs can carry an
# evaluation inside a derivation, but it only enumerates derivations, so plain
# config values -- exactly what scripts/tests/* assert on with jq -- do not
# survive the round trip. So we ship the tracked tree to the server and evaluate
# there: 16 cores and 125 GB instead of 4 and 11.
#
# Batching matters as much as offloading. Nix shares nothing between separate
# `nix eval` processes, so a script asking three thin questions pays three full
# module-system instantiations. remote_eval_batch_json pays one.
#
# Safety
# ------
# This evaluates only. It never builds, never activates, never runs
# switch-to-configuration, and never touches live state. The shipped archive is
# produced by create_deploy_repo_archive, which refuses secrets/unencrypted and
# SensitivePrivateSecrets, so only ciphertext crosses the wire.
#
# The Nix body travels on stdin, never interpolated into the remote command line.
#
# Fails closed. Any staging, transfer, or remote-evaluation failure returns
# non-zero with no output, so a caller cannot read a transport error as an empty
# result. Set REMOTE_EVAL=0 to force local evaluation.

remote_eval_host=""
remote_eval_reason=""

_remote_eval_resolve_host() {
  if [[ -n "${REMOTE_EVAL_HOST:-}" ]]; then
    printf '%s\n' "$REMOTE_EVAL_HOST"
    return 0
  fi
  # Mirror deploy.sh: vars.localAdminUser@vars.serverLanIP. vars, lib and
  # repoPath are already bound by nix_flake_json.
  local config
  config="$(NIXHOMESERVER_REMOTE_EVAL_NEED_TARGET=1 nix_flake_json '{
    localAdminUser = if vars ? localAdminUser then vars.localAdminUser else vars.identity.localAdminUser;
    serverLanIP = vars.serverLanIP;
  }')" || return 1
  jq -er '"\(.localAdminUser)@\(.serverLanIP)"' <<<"$config"
}

# remote_eval_batch_json <name>=<body> [<name>=<body> ...]
#
# Each body is the same text flake_eval_json takes: `f` is the flake and `lib`
# its nixpkgs lib. Prints one JSON object mapping name -> value.
remote_eval_batch_json() {
  local pairs=("$@") spec name body built all
  if ((${#pairs[@]} == 0)); then
    echo "remote-eval: no queries given" >&2
    return 1
  fi

  built=""
  for spec in "${pairs[@]}"; do
    [[ "$spec" == *=* ]] || { echo "remote-eval: bad query '${spec}', want name=body" >&2; return 1; }
    name="${spec%%=*}"
    body="${spec#*=}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      echo "remote-eval: query name '${name}' is not a Nix identifier" >&2
      return 1
    }
    built+="  ${name} = (${body});
"
  done

  all="let
  f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
  lib = f.inputs.nixpkgs.lib;
in {
${built}}"

  if [[ "${REMOTE_EVAL:-1}" != "0" ]]; then
    if _remote_eval_run "$all"; then
      return 0
    fi
    echo "remote-eval: falling back to local evaluation (${remote_eval_reason})" >&2
  fi

  # The local fallback needs the same flake reference the repo's own helpers
  # use, so bind it here too rather than relying on _remote_eval_run having run.
  init_repo_root
  nix eval --json --impure --expr "$all"
}

_remote_eval_run() {
  local expression="$1"
  local repo_root archive remote_archive remote_dir output

  init_repo_root
  repo_root="$(cd "$repo_root" && pwd)"

  if [[ -z "$remote_eval_host" ]]; then
    remote_eval_host="$(_remote_eval_resolve_host)" || {
      remote_eval_reason="could not resolve a target host from vars.nix"
      return 1
    }
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_eval_host" true 2>/dev/null; then
    remote_eval_reason="target ${remote_eval_host} is not reachable with BatchMode"
    return 1
  fi

  archive="$(mktemp /tmp/nixhomeserver-remote-eval.XXXXXX.tar)" || {
    remote_eval_reason="could not create a local archive"
    return 1
  }
  if ! create_deploy_repo_archive "$archive"; then
    rm -f "$archive"
    remote_eval_reason="create_deploy_repo_archive refused this working tree"
    return 1
  fi

  remote_archive="$(stage_archive_on_remote "$archive" "$remote_eval_host" "nixhomeserver-remote-eval")" || {
    rm -f "$archive"
    remote_eval_reason="could not transfer the archive to ${remote_eval_host}"
    return 1
  }
  rm -f "$archive"

  remote_dir="$(ssh -o BatchMode=yes "$remote_eval_host" \
    "mktemp -d /tmp/nixhomeserver-remote-eval.XXXXXX")" || {
    remote_eval_reason="could not create a remote staging directory"
    return 1
  }

  # Stage the expression as its own file first. It cannot travel on the same
  # stdin as the remote script, and it must never be interpolated into the
  # remote command line, where operator-supplied Nix text would be re-parsed by
  # the remote shell.
  remote_expr="${remote_dir}/query.nix"
  if ! printf '%s' "$expression" | ssh -o BatchMode=yes "$remote_eval_host" \
    "cat > $(printf '%q' "$remote_expr")"; then
    ssh -o BatchMode=yes "$remote_eval_host" "rm -rf $(printf '%q' "$remote_dir")" 2>/dev/null || true
    remote_eval_reason="could not transfer the expression to ${remote_eval_host}"
    return 1
  fi

  local remote_err
  remote_err="$(mktemp /tmp/nixhomeserver-remote-eval-err.XXXXXX)" || return 1

  if ! output="$(ssh -o BatchMode=yes "$remote_eval_host" bash -s -- \
    "$remote_dir" "$remote_archive" "$remote_expr" 2>"$remote_err" <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
remote_archive="$2"
remote_expr="$3"
trap 'rm -rf "$remote_dir" "$remote_archive"' EXIT
mkdir -p "$remote_dir"
tar -C "$remote_dir" -xf "$remote_archive"
cd "$remote_dir"
# path:, not git+file:// -- the staged tree is a plain directory with no .git.
# Safe here precisely because create_deploy_repo_archive already reduced it to
# tracked files; a path: reference to the live working tree would drag in the
# ~69 GB of gitignored build output under custom_apps.
NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$remote_dir" \
  nix eval --json --impure --expr "$(cat "$remote_expr")"
REMOTE_EOF
  )"; then
    remote_eval_reason="remote evaluation failed on ${remote_eval_host}: $(tail -n 3 "$remote_err" | tr '\n' ' ')"
    rm -f "$remote_err"
    return 1
  fi
  rm -f "$remote_err"

  printf '%s\n' "$output"
}
