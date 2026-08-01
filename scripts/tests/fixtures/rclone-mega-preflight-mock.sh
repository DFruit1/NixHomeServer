#!/usr/bin/env bash

set -euo pipefail

fixture="${RCLONE_MOCK_FIXTURE:?RCLONE_MOCK_FIXTURE is required}"
command="${1:?rclone command is required}"
shift

last_argument="${!#:-}"
argument_value() {
  local wanted="$1"
  shift
  while (( $# > 0 )); do
    if [[ "$1" == "$wanted" ]]; then
      printf '%s\n' "${2:?missing mocked value for $wanted}"
      return 0
    fi
    shift
  done
  return 1
}

case "$command" in
  about)
    cat "$fixture/quota.json"
    ;;
  cat)
    if [[ "$last_argument" == */.nixhomeserver-rclone-owner.json ]]; then
      [[ ! -f "$fixture/marker-error" ]] || exit 1
      cat "$fixture/marker.json"
    elif [[ "$last_argument" == */kopia.repository.f ]]; then
      [[ ! -f "$fixture/identity-error" ]] || exit "$(cat "$fixture/identity-error")"
      cat "$fixture/kopia.repository.f"
    else
      exit 2
    fi
    ;;
  copyto)
    source_argument="${@: -2:1}"
    cp "$source_argument" "$fixture/copied-marker.json"
    ;;
  lsf)
    if [[ -f "$fixture/list-error" ]]; then
      exit "$(cat "$fixture/list-error")"
    fi
    cat "$fixture/listing.txt"
    ;;
  mkdir)
    : > "$fixture/mkdir-called"
    ;;
  size)
    if files_from="$(argument_value --files-from "$@")"; then
      case "$files_from" in
        */always-transfer.txt) cat "$fixture/control-size.json" ;;
        */missing-on-destination.txt|*/different.txt) cat "$fixture/transfer-size.json" ;;
        */missing-on-source.txt) cat "$fixture/delete-size.json" ;;
        *) echo "Unexpected mocked --files-from path: $files_from" >&2; exit 2 ;;
      esac
    else
      cat "$fixture/size.json"
    fi
    ;;
  sync)
    if [[ -f "$fixture/plan-error" ]]; then
      exit "$(cat "$fixture/plan-error")"
    fi
    missing_destination="$(argument_value --missing-on-dst "$@")"
    different="$(argument_value --differ "$@")"
    missing_source="$(argument_value --missing-on-src "$@")"
    errors="$(argument_value --error "$@")"
    cp "$fixture/missing-on-destination.txt" "$missing_destination"
    cp "$fixture/different.txt" "$different"
    cp "$fixture/missing-on-source.txt" "$missing_source"
    cp "$fixture/errors.txt" "$errors"
    ;;
  *)
    echo "Unexpected mocked rclone command: $command" >&2
    exit 2
    ;;
esac
