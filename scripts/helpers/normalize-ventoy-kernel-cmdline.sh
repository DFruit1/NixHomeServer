#!/usr/bin/env bash

set -euo pipefail

cmdline="$(cat)"

case " $cmdline " in
  *" init="*)
    ;;
  *" vtinit="*)
    cmdline="$(printf '%s\n' "$cmdline" | sed -E 's/(^|[[:space:]])vtinit=/\1init=/')"
    ;;
esac

printf '%s\n' "$cmdline"
