#!/usr/bin/env bash
# Merge the groundwater server's per-device MQTT accounts into Mosquitto's
# listener files. Runs as the mosquitto user: in the broker's preStart (after
# the NixOS module wrote passwd-N and acl-N.conf) and from
# groundwater-mqtt-auth.service when the server rewrites its files.
#
#   mqtt-auth-merge.sh AUTH_DIR DATA_DIR SHARED_USER INDEX...
#
# AUTH_DIR/devices.passwd  DEVICEID:$7$... lines written by the server
# AUTH_DIR/devices.deny    DeviceIDs whose topics SHARED_USER may not use
#
# The server's input is untrusted here: only 24-hex usernames with a $7$
# hash are accepted, a name that already exists in the static file (for
# example groundwater-app) is never overridden, and a deny line needs an own
# account for that unit, so a unit can never be locked out entirely.
set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: $0 AUTH_DIR DATA_DIR SHARED_USER INDEX..." >&2
  exit 2
fi
auth_dir=$1
data_dir=$2
shared_user=$3
shift 3

marker='# groundwater-mqtt-auth begin'
# A literal regular expression: the dollars are Mosquitto's hash separators.
# shellcheck disable=SC2016
account_re='^[0-9A-F]{24}:\$7\$[0-9]+\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+$'
device_re='^[0-9A-F]{24}$'

read_lines() {
  # Missing input is normal before the server first runs.
  if [ -r "$1" ]; then cat "$1"; fi
}

accounts=$(read_lines "$auth_dir/devices.passwd" | grep -E "$account_re" || true)
denied=$(read_lines "$auth_dir/devices.deny" | grep -E "$device_re" || true)

for index in "$@"; do
  case $index in
    '' | *[!0-9]*) echo "listener index must be a number: $index" >&2; exit 2 ;;
  esac
  base="$data_dir/passwd-$index"
  acl="$data_dir/acl-$index.conf"
  if [ ! -r "$base" ] || [ ! -r "$acl" ]; then
    echo "missing $base or $acl; is listener $index configured?" >&2
    exit 1
  fi

  static_users=$(cut -d: -f1 "$base")
  merged=$(mktemp "$data_dir/.passwd-merged-$index.XXXXXX")
  # awk 1 terminates every line: the module writes files without a final
  # newline, and an appended line must not join the last entry.
  awk 1 "$base" > "$merged"
  own_accounts=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%:*}
    if printf '%s\n' "$static_users" | grep -qxF "$name"; then
      echo "ignoring $name: a static broker account has that name" >&2
      continue
    fi
    if printf '%s\n' "$own_accounts" | grep -qxF "$name"; then
      continue
    fi
    printf '%s\n' "$line" >> "$merged"
    own_accounts=$(printf '%s\n%s' "$own_accounts" "$name")
  done <<< "$accounts"
  chmod 0600 "$merged"
  mv -f "$merged" "$data_dir/passwd-merged-$index"

  # The NixOS file plus a marked tail; a re-run replaces only the tail.
  next=$(mktemp "$data_dir/.acl-$index.XXXXXX")
  sed "/^$marker\$/,\$d" "$acl" | awk 1 > "$next"
  {
    echo "$marker"
    while IFS= read -r device; do
      [ -n "$device" ] || continue
      if printf '%s\n' "$own_accounts" | grep -qxF "$device"; then
        echo "user $shared_user"
        echo "topic deny gwl/v1/$device/#"
      fi
    done <<< "$denied"
  } >> "$next"
  chmod 0700 "$next"
  mv -f "$next" "$acl"
done
