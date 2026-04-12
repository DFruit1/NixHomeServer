#!/usr/bin/env bash
set -euo pipefail

# Interactive Kanidm person creation helper
# - Bash-specific script
# - Uses Kanidm as source of truth
# - Fetches current groups from Kanidm
# - Prompts for optional validity and reset-token actions

SERVER_URL_DEFAULT="https://id.sydneybasiniot.org"
ADMIN_NAME_DEFAULT="admindsaw"
RFC3339_TIME_DEFAULT="$(date -Is 2>/dev/null || true)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "$prompt [$default]: " value
  value="$(trim "$value")"
  if [[ -z "$value" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$value"
  fi
}

prompt_required() {
  local prompt="$1"
  local value=""
  while [[ -z "$value" ]]; do
    read -r -p "$prompt: " value
    value="$(trim "$value")"
  done
  printf '%s' "$value"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local value
  local suffix="[y/N]"
  [[ "$default" == "y" ]] && suffix="[Y/n]"
  while true; do
    read -r -p "$prompt $suffix: " value
    value="$(trim "$value")"
    if [[ -z "$value" ]]; then
      value="$default"
    fi
    case "${value,,}" in
    y | yes) return 0 ;;
    n | no) return 1 ;;
    *) echo "Please enter y or n." ;;
    esac
  done
}

parse_group_list() {
  # Tries to turn Kanidm group list output into one group name per line.
  # Works best when output begins with the group identifier on each line.
  awk '
    NF == 0 { next }
    {
      # First token on each non-empty line
      name=$1
      # Strip punctuation commonly seen in CLI formatting
      gsub(/[:,]/, "", name)
      # Ignore obvious headers
      low=tolower(name)
      if (low == "name" || low == "group" || low == "groups" || low == "spn" || low == "uuid") next
      print name
    }
  ' | awk '!seen[$0]++'
}

choose_groups_multi() {
  local -n _groups_ref=$1
  local selected=()

  if [[ "${#_groups_ref[@]}" -eq 0 ]]; then
    echo "No groups were returned by Kanidm."
    CHOSEN_GROUPS=()
    return 0
  fi

  echo
  echo "Available groups:"
  local i=1
  for g in "${_groups_ref[@]}"; do
    printf '  %2d) %s\n' "$i" "$g"
    ((i++))
  done

  echo
  echo "Enter one or more group numbers separated by spaces."
  echo "Press Enter for no group assignments."
  echo "Example: 1 3 5"

  local raw
  read -r -p "Group selection: " raw
  raw="$(trim "$raw")"

  if [[ -z "$raw" ]]; then
    CHOSEN_GROUPS=()
    return 0
  fi

  local idx
  for idx in $raw; do
    if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
      echo "Ignoring invalid selection: $idx" >&2
      continue
    fi
    if ((idx < 1 || idx > ${#_groups_ref[@]})); then
      echo "Ignoring out-of-range selection: $idx" >&2
      continue
    fi
    selected+=("${_groups_ref[$((idx - 1))]}")
  done

  # De-duplicate while preserving order
  local dedup=()
  local seen=" "
  local g
  for g in "${selected[@]}"; do
    if [[ "$seen" != *" $g "* ]]; then
      dedup+=("$g")
      seen+="${g} "
    fi
  done

  CHOSEN_GROUPS=("${dedup[@]}")
}

show_summary() {
  echo
  echo "Summary:"
  echo "  Server URL:      $SERVER_URL"
  echo "  Admin account:   $ADMIN_NAME"
  echo "  Account ID:      $ACCOUNT_ID"
  echo "  Display name:    $DISPLAY_NAME"
  if [[ -n "$PRIMARY_EMAIL" ]]; then
    echo "  Primary email:   $PRIMARY_EMAIL"
  else
    echo "  Primary email:   (none)"
  fi

  if [[ "${#CHOSEN_GROUPS[@]}" -gt 0 ]]; then
    echo "  Groups:"
    local g
    for g in "${CHOSEN_GROUPS[@]}"; do
      echo "    - $g"
    done
  else
    echo "  Groups:          (none)"
  fi

  if [[ "$SET_BEGIN_FROM" == "y" ]]; then
    echo "  Begin-from:      $BEGIN_FROM_TIME"
  else
    echo "  Begin-from:      (not set)"
  fi

  if [[ "$SET_EXPIRE_AT" == "y" ]]; then
    echo "  Expire-at:       $EXPIRE_AT_VALUE"
  else
    echo "  Expire-at:       (not set)"
  fi

  if [[ "$GENERATE_RESET_TOKEN" == "y" ]]; then
    if [[ -n "$RESET_TOKEN_TTL_SECONDS" ]]; then
      echo "  Reset token TTL: $RESET_TOKEN_TTL_SECONDS seconds"
    else
      echo "  Reset token TTL: default"
    fi
  else
    echo "  Reset token:     (not generated)"
  fi
}

require_cmd kanidm

echo "Kanidm interactive user provisioning"
echo

SERVER_URL="$(prompt_default "Kanidm server URL" "$SERVER_URL_DEFAULT")"
ADMIN_NAME="$(prompt_default "Admin account name" "$ADMIN_NAME_DEFAULT")"
RFC3339_TIME="$(prompt_default "Default RFC3339 timestamp" "$RFC3339_TIME_DEFAULT")"

echo
echo "Logging in as $ADMIN_NAME ..."
kanidm login --url "$SERVER_URL" --name "$ADMIN_NAME"

echo
echo "Reauthenticating for privileged operations ..."
kanidm reauth --url "$SERVER_URL" --name "$ADMIN_NAME"

echo
echo "Fetching current groups from Kanidm ..."
GROUP_LIST_RAW="$(kanidm group list --url "$SERVER_URL" --name "$ADMIN_NAME" 2>/dev/null || true)"
mapfile -t ALL_GROUPS < <(printf '%s\n' "$GROUP_LIST_RAW" | parse_group_list)

ACCOUNT_ID="$(prompt_required "New account ID / username")"
DISPLAY_NAME="$(prompt_required "Display name")"

read -r -p "Primary email (leave blank to skip): " PRIMARY_EMAIL
PRIMARY_EMAIL="$(trim "$PRIMARY_EMAIL")"

choose_groups_multi ALL_GROUPS

SET_BEGIN_FROM="n"
BEGIN_FROM_TIME=""
if prompt_yes_no "Set a future begin-from validity time?" "n"; then
  SET_BEGIN_FROM="y"
  BEGIN_FROM_TIME="$(prompt_default "Begin-from RFC3339 time" "$RFC3339_TIME")"
fi

SET_EXPIRE_AT="n"
EXPIRE_AT_VALUE=""
if prompt_yes_no "Set an expiry time now?" "n"; then
  SET_EXPIRE_AT="y"
  EXPIRE_AT_VALUE="$(prompt_default "Expire-at value (RFC3339 or now)" "now")"
fi

GENERATE_RESET_TOKEN="n"
RESET_TOKEN_TTL_SECONDS=""
if prompt_yes_no "Generate a password reset token after creation?" "y"; then
  GENERATE_RESET_TOKEN="y"
  read -r -p "Reset token TTL seconds (blank = Kanidm default): " RESET_TOKEN_TTL_SECONDS
  RESET_TOKEN_TTL_SECONDS="$(trim "$RESET_TOKEN_TTL_SECONDS")"
  if [[ -n "$RESET_TOKEN_TTL_SECONDS" && ! "$RESET_TOKEN_TTL_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Reset token TTL must be blank or an integer number of seconds." >&2
    exit 1
  fi
fi

show_summary

echo
if ! prompt_yes_no "Proceed with creation?" "n"; then
  echo "Aborted."
  exit 0
fi

echo
echo "Creating person ..."
kanidm person create "$ACCOUNT_ID" "$DISPLAY_NAME" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"

if [[ -n "$PRIMARY_EMAIL" ]]; then
  echo "Setting primary email ..."
  kanidm person update "$ACCOUNT_ID" \
    --mail "$PRIMARY_EMAIL" \
    --url "$SERVER_URL" \
    --name "$ADMIN_NAME"
fi

if [[ "${#CHOSEN_GROUPS[@]}" -gt 0 ]]; then
  echo "Adding group memberships ..."
  for GROUP_NAME in "${CHOSEN_GROUPS[@]}"; do
    echo "  -> $GROUP_NAME"
    kanidm group add-members "$GROUP_NAME" "$ACCOUNT_ID" \
      --url "$SERVER_URL" \
      --name "$ADMIN_NAME"
  done
fi

if [[ "$SET_BEGIN_FROM" == "y" ]]; then
  echo "Applying begin-from validity ..."
  kanidm person validity begin-from "$ACCOUNT_ID" "$BEGIN_FROM_TIME" \
    --url "$SERVER_URL" \
    --name "$ADMIN_NAME"
fi

if [[ "$SET_EXPIRE_AT" == "y" ]]; then
  echo "Applying expiry ..."
  kanidm person validity expire-at "$ACCOUNT_ID" "$EXPIRE_AT_VALUE" \
    --url "$SERVER_URL" \
    --name "$ADMIN_NAME"
fi

if [[ "$GENERATE_RESET_TOKEN" == "y" ]]; then
  echo "Generating reset token ..."
  if [[ -n "$RESET_TOKEN_TTL_SECONDS" ]]; then
    kanidm person credential create-reset-token "$ACCOUNT_ID" "$RESET_TOKEN_TTL_SECONDS" \
      --url "$SERVER_URL" \
      --name "$ADMIN_NAME"
  else
    kanidm person credential create-reset-token "$ACCOUNT_ID" \
      --url "$SERVER_URL" \
      --name "$ADMIN_NAME"
  fi
fi

echo
echo "Final person record:"
kanidm person get "$ACCOUNT_ID" --url "$SERVER_URL" --name "$ADMIN_NAME"

echo
echo "Done."
