#!/bin/sh

# Filename: dns_bunny.sh
# Description: Inspect, edit, and reconcile Bunny DNS records.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-18 Tue 00:00
# Version: 0.5.1
# Last-Updated: 2026-08-30 Sun 00:00
# Update #: 9

set -u
LC_ALL=C
export LC_ALL

PROGRAM=dns_bunny.sh
VERSION=0.5.1
API_BASE=https://api.bunny.net
TEMP_ROOT=${TMPDIR:-/tmp}
TEMP_ROOT=${TEMP_ROOT%/}
WORK_DIR=
CURL_CONFIG=
HEADER_FILE=
CONFIG_FILE=
ZONE=
ZONE_ID=
OWNER=
MANAGED_PREFIX=
KEY_FILE=
BACKUP_DIR=
DESIRED_FILE=
DESIRED_LINES=
ZONE_FILE=
PLAN_FILE=
API_KEY_OPTION=
BACKUP_DIR_OPTION=

usage() {
  printf '%s %s\n' "$PROGRAM" "$VERSION"
  cat <<'EOF'
Inspect, edit, or reconcile records in an existing Bunny DNS zone.

Usage:
  dns_bunny.sh
  dns_bunny.sh help
  dns_bunny.sh version
  dns_bunny.sh [--api-key FILE] list ZONE
  dns_bunny.sh [--api-key FILE] [--backup-dir DIR] add ZONE TYPE NAME VALUE [OPTIONS]
  dns_bunny.sh [--api-key FILE] [--backup-dir DIR] update ZONE RECORD_ID OPTIONS
  dns_bunny.sh [--api-key FILE] [--backup-dir DIR] delete ZONE RECORD_ID
  dns_bunny.sh init-key KEYFILE
  dns_bunny.sh validate RECORDS.json
  dns_bunny.sh check RECORDS.json
  dns_bunny.sh list RECORDS.json
  dns_bunny.sh plan RECORDS.json
  dns_bunny.sh apply RECORDS.json
  dns_bunny.sh verify RECORDS.json
  dns_bunny.sh prune RECORDS.json

Global options must precede the command:
  --api-key FILE    Protected key file (default: $HOME/.secrets/bunnynet-api-key)
  --backup-dir DIR  Direct-mutation backups (default: $HOME/.local/state/dns-bunny/backups)

Record OPTIONS are --ttl, --type, --name, --value, --priority, --weight,
--port, --flags, --tag, --disable, and --enable. Add takes TYPE, NAME, and
VALUE positionally; update accepts only the fields that should change. TTL
defaults to 60 seconds when omitted.

List accepts either a zone name or an existing RECORDS.json declaration.
With no command, nothing changes. Mutations require add, update, delete,
apply, prune, or init-key. --api-key names a file; it never accepts the secret.
EOF
}

say() {
  printf '%s\n' "$*"
}

warn() {
  printf '%s: warning: %s\n' "$PROGRAM" "$*" >&2
}

die() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    case "$WORK_DIR" in
      "$TEMP_ROOT"/dns_bunny.*) rm -rf "$WORK_DIR" ;;
      *) warn "refusing to remove unexpected temporary path: $WORK_DIR" ;;
    esac
  fi
}

make_work_dir() {
  [ -n "$WORK_DIR" ] && return 0
  WORK_DIR=$(mktemp -d "$TEMP_ROOT/dns_bunny.XXXXXX") || die "cannot create a temporary directory"
  chmod 700 "$WORK_DIR" || die "cannot protect temporary directory"
  trap 'cleanup' 0
  trap 'cleanup; exit 130' HUP INT TERM
  CURL_CONFIG=$WORK_DIR/curl.conf
  HEADER_FILE=$WORK_DIR/headers
  DESIRED_FILE=$WORK_DIR/desired.json
  DESIRED_LINES=$WORK_DIR/desired.ndjson
  ZONE_FILE=$WORK_DIR/zone.json
  PLAN_FILE=$WORK_DIR/plan.ndjson
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_jq() {
  require_command jq
  # Uppercase IN is the newest jq feature used by the declaration filters.
  jq -n 'IN(1)' >/dev/null 2>&1 || die "jq 1.6 or newer is required"
}

require_file_mode_tool() {
  case $(uname -s) in
    # macOS always provides BSD stat here, even when PATH selects GNU stat.
    Darwin) [ -x /usr/bin/stat ] || die "required command not found: /usr/bin/stat" ;;
    Linux|SunOS) require_command stat ;;
    *) die "cannot inspect key permissions on this operating system" ;;
  esac
}

default_api_key_file() {
  [ -n "${HOME:-}" ] || die 'HOME is not set; provide --api-key FILE'
  printf '%s\n' "$HOME/.secrets/bunnynet-api-key"
}

default_backup_dir() {
  [ -n "${HOME:-}" ] || die 'HOME is not set; provide --backup-dir DIR'
  printf '%s\n' "$HOME/.local/state/dns-bunny/backups"
}

validate_zone_name() {
  db_zone_to_validate=$1
  require_jq
  jq -en --arg zone "$db_zone_to_validate" '
    $zone | type == "string" and test("^[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$")
  ' >/dev/null || die "invalid DNS zone name: $db_zone_to_validate"
}

validate_config() {
  CONFIG_FILE=$1
  [ -f "$CONFIG_FILE" ] || die "record file not found: $CONFIG_FILE"
  require_jq

  jq -e '
    def valid_type:
      IN("A", "AAAA", "CNAME", "TXT", "MX", "SRV", "CAA", "PTR", "NS", "SVCB", "HTTPS", "TLSA");
    def positive_int: type == "number" and floor == . and . > 0 and . <= 2147483647;
    def nonnegative_int: type == "number" and floor == . and . >= 0 and . <= 2147483647;
    type == "object"
    and (.owner | type == "string" and length <= 64 and test("^[a-z0-9][a-z0-9._-]*$"))
    and (.zone | type == "string" and test("^[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"))
    and (.key_file | type == "string" and startswith("/"))
    and (.backup_dir | type == "string" and startswith("/"))
    and (.records | type == "array" and length > 0)
    and (all(.records[];
      (.key | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
      and (.type | type == "string" and valid_type)
      and (.name | type == "string" and (. == "" or . == "@" or test("^[A-Za-z0-9_.*-]+$")))
      and (.value | type == "string" and length > 0)
      and ((.ttl // 60) | positive_int)
      and ((.priority // 0) | nonnegative_int)
      and ((.weight // 0) | nonnegative_int)
      and ((.port // 0) | nonnegative_int)
      and ((.flags // 0) | nonnegative_int and . <= 255)
      and ((.tag // "") | type == "string")
      and ((.disabled // false) | type == "boolean")
      and ((.allow_multiple // false) | type == "boolean")
    ))
    and (([.records[].key] | length) == ([.records[].key] | unique | length))
  ' "$CONFIG_FILE" >/dev/null || die "invalid record file: $CONFIG_FILE"
}

load_settings() {
  OWNER=$(jq -r '.owner' "$CONFIG_FILE") || die "cannot read owner"
  ZONE=$(jq -r '.zone | ascii_downcase' "$CONFIG_FILE") || die "cannot read zone"
  if [ -n "$API_KEY_OPTION" ]; then
    KEY_FILE=$API_KEY_OPTION
  else
    KEY_FILE=$(jq -r '.key_file' "$CONFIG_FILE") || die "cannot read key_file"
  fi
  if [ -n "$BACKUP_DIR_OPTION" ]; then
    BACKUP_DIR=$BACKUP_DIR_OPTION
  else
    BACKUP_DIR=$(jq -r '.backup_dir' "$CONFIG_FILE") || die "cannot read backup_dir"
  fi
  MANAGED_PREFIX="managed-by:$OWNER; key="
}

normalize_config() {
  jq --arg prefix "$MANAGED_PREFIX" '
    def type_id:
      {
        "A": 0, "AAAA": 1, "CNAME": 2, "TXT": 3, "MX": 4,
        "SRV": 8, "CAA": 9, "PTR": 10, "NS": 12,
        "SVCB": 13, "HTTPS": 14, "TLSA": 15
      }[.];
    .records | map({
      Key: .key,
      TypeName: .type,
      Type: (.type | type_id),
      Ttl: (.ttl // 60),
      Value: .value,
      Name: (if .name == "@" then "" else .name end),
      Weight: (.weight // 0),
      Priority: (.priority // 0),
      Flags: (.flags // 0),
      Tag: (.tag // ""),
      Port: (.port // 0),
      Disabled: (.disabled // false),
      AllowMultiple: (.allow_multiple // false),
      Comment: ($prefix + .key)
    })
  ' "$CONFIG_FILE" >"$DESIRED_FILE" || die "cannot normalize record file"
}

file_mode() {
  case $(uname -s) in
    Darwin) /usr/bin/stat -f '%Lp' "$1" ;;
    Linux|SunOS) stat -c '%a' "$1" ;;
    *) die "cannot inspect key permissions on this operating system" ;;
  esac
}

validate_api_key() {
  db_key_to_validate=$1
  [ -n "$db_key_to_validate" ] || die "Bunny API key is empty"
  case "$db_key_to_validate" in
    *[!\ -~]*) die "Bunny API key must contain printable ASCII characters only" ;;
    ' '*|*' ') die "Bunny API key must not start or end with a space" ;;
  esac
  db_key_to_validate=
  unset db_key_to_validate
}

load_api_key() {
  case "$KEY_FILE" in
    /*) ;;
    *) die "Bunny API key file path must be absolute: $KEY_FILE" ;;
  esac
  [ -f "$KEY_FILE" ] || die "Bunny API key file not found: $KEY_FILE"
  [ ! -L "$KEY_FILE" ] || die "Bunny API key file must not be a symbolic link"

  db_mode=$(file_mode "$KEY_FILE") || die "cannot inspect Bunny API key file"
  case "$db_mode" in
    400|600) ;;
    *) die "Bunny API key file must have mode 0400 or 0600, not $db_mode" ;;
  esac

  API_KEY=
  API_KEY_EXTRA=
  {
    IFS= read -r API_KEY || [ -n "$API_KEY" ]
    if IFS= read -r API_KEY_EXTRA; then
      : "$API_KEY_EXTRA"
      die "Bunny API key file must contain exactly one line"
    fi
  } <"$KEY_FILE"

  validate_api_key "$API_KEY"

  umask 077
  {
    printf '%s\n' 'silent'
    printf '%s\n' 'show-error'
    printf '%s\n' 'connect-timeout = 10'
    printf '%s\n' 'max-time = 60'
    printf '%s\n' 'header = "Accept: application/json"'
    printf '%s\n' 'header = "Content-Type: application/json"'
  } >"$CURL_CONFIG" || die "cannot prepare protected API request configuration"
  chmod 600 "$CURL_CONFIG" || die "cannot protect API request configuration"
  printf 'AccessKey: %s\n' "$API_KEY" >"$HEADER_FILE" || die "cannot prepare protected API request header"
  chmod 600 "$HEADER_FILE" || die "cannot protect API request header"
  API_KEY=
  API_KEY_EXTRA=
  unset API_KEY API_KEY_EXTRA
}

api_request() {
  db_method=$1
  db_url=$2
  db_body_file=$3
  db_output_file=$4

  if [ -n "$db_body_file" ]; then
    db_http_code=$(curl --config "$CURL_CONFIG" --header "@$HEADER_FILE" --request "$db_method" --url "$db_url" \
      --data-binary "@$db_body_file" --output "$db_output_file" --write-out '%{http_code}')
  else
    db_http_code=$(curl --config "$CURL_CONFIG" --header "@$HEADER_FILE" --request "$db_method" --url "$db_url" \
      --output "$db_output_file" --write-out '%{http_code}')
  fi
  db_curl_status=$?

  [ "$db_curl_status" -eq 0 ] || die "Bunny API request failed before receiving an HTTP response"
  case "$db_http_code" in
    2??) return 0 ;;
  esac

  db_message=$(jq -r '.Message // .ErrorKey // empty' "$db_output_file" 2>/dev/null || :)
  [ -n "$db_message" ] || db_message='Bunny API returned an error'
  die "$db_message (HTTP $db_http_code)"
}

find_zone() {
  db_zone_list=$WORK_DIR/zones.json
  api_request GET "$API_BASE/dnszone?page=1&perPage=1000&search=$ZONE" '' "$db_zone_list"
  db_zone_count=$(jq --arg zone "$ZONE" '[.Items[]? | select((.Domain | ascii_downcase) == $zone)] | length' "$db_zone_list")
  [ "$db_zone_count" -eq 1 ] || die "expected one Bunny DNS zone named $ZONE, found $db_zone_count"
  ZONE_ID=$(jq -r --arg zone "$ZONE" '.Items[] | select((.Domain | ascii_downcase) == $zone) | .Id' "$db_zone_list")
  case "$ZONE_ID" in
    ''|*[!0-9]*) die "Bunny returned an invalid zone ID for $ZONE" ;;
  esac
}

fetch_zone() {
  api_request GET "$API_BASE/dnszone/$ZONE_ID" '' "$ZONE_FILE"
  jq -e --arg zone "$ZONE" '(.Domain | ascii_downcase) == $zone and (.Records | type == "array")' \
    "$ZONE_FILE" >/dev/null || die "Bunny returned an invalid zone document"
}

prepare_online() {
  validate_config "$1"
  require_command curl
  require_file_mode_tool
  make_work_dir
  load_settings
  normalize_config
  load_api_key
  find_zone
  fetch_zone
}

prepare_direct() {
  validate_zone_name "$1"
  require_command curl
  require_file_mode_tool
  make_work_dir
  ZONE=$(printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]')
  if [ -n "$API_KEY_OPTION" ]; then
    KEY_FILE=$API_KEY_OPTION
  else
    KEY_FILE=$(default_api_key_file)
  fi
  if [ -n "$BACKUP_DIR_OPTION" ]; then
    BACKUP_DIR=$BACKUP_DIR_OPTION
  else
    BACKUP_DIR=$(default_backup_dir)
  fi
  load_api_key
  find_zone
  fetch_zone
}

append_action() {
  db_action=$1
  db_record_id=$2
  db_desired=$3
  db_reason=$4
  jq -cn --arg action "$db_action" --arg id "$db_record_id" \
    --arg reason "$db_reason" --argjson desired "$db_desired" '
      {
        action: $action,
        record_id: (if $id == "" then null else ($id | tonumber) end),
        reason: $reason,
        desired: $desired
      }
    ' >>"$PLAN_FILE" || die "cannot write DNS plan"
}

canonical_current() {
  db_current_id=$1
  jq -c --argjson id "$db_current_id" '
    def canonical:
      . as $r | {
        Type: $r.Type,
        Ttl: ($r.Ttl // 0),
        Value: ($r.Value // ""),
        Name: ($r.Name // ""),
        Weight: (if $r.Type == 8 then ($r.Weight // 0) else 0 end),
        Priority: (if ($r.Type == 4 or $r.Type == 8 or $r.Type == 13 or $r.Type == 14)
          then ($r.Priority // 0) else 0 end),
        Flags: (if $r.Type == 9 then ($r.Flags // 0) else 0 end),
        Tag: (if $r.Type == 9 then ($r.Tag // "") else "" end),
        Port: (if $r.Type == 8 then ($r.Port // 0) else 0 end),
        Disabled: ($r.Disabled // false),
        Comment: ($r.Comment // "")
      };
    .Records[] | select(.Id == $id) | canonical
  ' "$ZONE_FILE"
}

canonical_desired() {
  printf '%s\n' "$1" | jq -c '
    . as $r | {
      Type: $r.Type,
      Ttl: ($r.Ttl // 0),
      Value: ($r.Value // ""),
      Name: ($r.Name // ""),
      Weight: (if $r.Type == 8 then ($r.Weight // 0) else 0 end),
      Priority: (if ($r.Type == 4 or $r.Type == 8 or $r.Type == 13 or $r.Type == 14)
        then ($r.Priority // 0) else 0 end),
      Flags: (if $r.Type == 9 then ($r.Flags // 0) else 0 end),
      Tag: (if $r.Type == 9 then ($r.Tag // "") else "" end),
      Port: (if $r.Type == 8 then ($r.Port // 0) else 0 end),
      Disabled: ($r.Disabled // false),
      Comment: ($r.Comment // "")
    }
  '
}

build_plan() {
  : >"$PLAN_FILE" || die "cannot initialize DNS plan"

  # Redirection keeps the loop in this shell, so die cannot be lost in a pipeline subshell.
  jq -c '.[]' "$DESIRED_FILE" >"$DESIRED_LINES" || die "cannot prepare desired records"
  while IFS= read -r db_desired; do
    db_comment=$(printf '%s\n' "$db_desired" | jq -r '.Comment') \
      || die "cannot read desired record ownership"
    db_type=$(printf '%s\n' "$db_desired" | jq -r '.Type') \
      || die "cannot read desired record type"
    db_name=$(printf '%s\n' "$db_desired" | jq -r '.Name') \
      || die "cannot read desired record name"
    db_value=$(printf '%s\n' "$db_desired" | jq -r '.Value') \
      || die "cannot read desired record value"
    db_allow_multiple=$(printf '%s\n' "$db_desired" | jq -r '.AllowMultiple') \
      || die "cannot read desired record multiplicity policy"

    db_owned_count=$(jq --arg comment "$db_comment" \
      '[.Records[]? | select((.Comment // "") == $comment)] | length' "$ZONE_FILE") \
      || die "cannot count owned Bunny records"

    if [ "$db_owned_count" -gt 1 ]; then
      append_action conflict '' "$db_desired" 'multiple Bunny records carry this project ownership key'
      continue
    fi

    if [ "$db_owned_count" -eq 1 ]; then
      db_record_id=$(jq -r --arg comment "$db_comment" \
        '.Records[] | select((.Comment // "") == $comment) | .Id' "$ZONE_FILE") \
        || die "cannot read the owned Bunny record identifier"
      db_current_identity=$(jq -c --argjson id "$db_record_id" \
        '.Records[] | select(.Id == $id) | {Type, Name: (.Name // "")}' "$ZONE_FILE") \
        || die "cannot read the owned Bunny record identity"
      db_wanted_identity=$(printf '%s\n' "$db_desired" | jq -c '{Type, Name}') \
        || die "cannot read the desired Bunny record identity"
      if [ "$db_current_identity" != "$db_wanted_identity" ]; then
        append_action replace "$db_record_id" "$db_desired" 'managed record name or type differs'
        continue
      fi
      db_current=$(canonical_current "$db_record_id") \
        || die "cannot normalize the current Bunny record"
      db_wanted=$(canonical_desired "$db_desired") \
        || die "cannot normalize the desired Bunny record"
      if [ "$db_current" = "$db_wanted" ]; then
        append_action ok "$db_record_id" "$db_desired" 'managed record already matches'
      else
        append_action update "$db_record_id" "$db_desired" 'managed record differs'
      fi
      continue
    fi

    db_semantic_count=$(jq --argjson desired "$db_desired" '
      def semantic:
        . as $r | {
          Type: $r.Type,
          Value: ($r.Value // ""),
          Name: ($r.Name // ""),
          Weight: (if $r.Type == 8 then ($r.Weight // 0) else 0 end),
          Priority: (if ($r.Type == 4 or $r.Type == 8 or $r.Type == 13 or $r.Type == 14)
            then ($r.Priority // 0) else 0 end),
          Flags: (if $r.Type == 9 then ($r.Flags // 0) else 0 end),
          Tag: (if $r.Type == 9 then ($r.Tag // "") else "" end),
          Port: (if $r.Type == 8 then ($r.Port // 0) else 0 end),
          Disabled: ($r.Disabled // false)
        };
      ($desired | semantic) as $wanted
      | [.Records[]? | select((. | semantic) == $wanted)] | length
    ' "$ZONE_FILE") || die "cannot count matching unmanaged Bunny records"

    if [ "$db_semantic_count" -eq 1 ]; then
      db_record_id=$(jq -r --argjson desired "$db_desired" '
        def semantic:
          . as $r | {
            Type: $r.Type,
            Value: ($r.Value // ""),
            Name: ($r.Name // ""),
            Weight: (if $r.Type == 8 then ($r.Weight // 0) else 0 end),
            Priority: (if ($r.Type == 4 or $r.Type == 8 or $r.Type == 13 or $r.Type == 14)
              then ($r.Priority // 0) else 0 end),
            Flags: (if $r.Type == 9 then ($r.Flags // 0) else 0 end),
            Tag: (if $r.Type == 9 then ($r.Tag // "") else "" end),
            Port: (if $r.Type == 8 then ($r.Port // 0) else 0 end),
            Disabled: ($r.Disabled // false)
          };
        ($desired | semantic) as $wanted
        | .Records[] | select((. | semantic) == $wanted) | .Id
      ' "$ZONE_FILE") || die "cannot read the matching unmanaged Bunny record identifier"
      append_action update "$db_record_id" "$db_desired" 'adopt exact existing record and apply project metadata'
      continue
    fi

    if [ "$db_semantic_count" -gt 1 ]; then
      append_action conflict '' "$db_desired" 'multiple indistinguishable unmanaged records already exist'
      continue
    fi

    db_cname_conflict=$(jq --argjson type "$db_type" --arg name "$db_name" '[
      .Records[]? | select((.Name // "") == $name and (.Type == 2 or $type == 2))
    ] | length' "$ZONE_FILE") || die "cannot inspect CNAME exclusivity"
    if [ "$db_cname_conflict" -gt 0 ]; then
      append_action conflict '' "$db_desired" 'CNAME exclusivity would be violated'
      continue
    fi

    db_same_set=$(jq --argjson type "$db_type" --arg name "$db_name" '[
      .Records[]? | select(.Type == $type and (.Name // "") == $name)
    ] | length' "$ZONE_FILE") || die "cannot inspect the unmanaged Bunny record set"
    if [ "$db_same_set" -gt 0 ] && [ "$db_allow_multiple" != true ]; then
      append_action conflict '' "$db_desired" "an unmanaged record set already exists for type $db_type name $db_name"
      continue
    fi

    append_action create '' "$db_desired" "record is absent ($db_value)"
  done <"$DESIRED_LINES"
}

print_plan() {
  jq -r '
    (.action | ascii_upcase) as $action
    | (.desired.Name | if . == "" then "@" else . end) as $name
    | "\($action) \(.desired.Key): \(.desired.TypeName) \($name) \(.desired.Value) -- \(.reason)"
  ' "$PLAN_FILE"
}

count_actions() {
  db_count_action=$1
  jq -s --arg action "$db_count_action" '[.[] | select(.action == $action)] | length' "$PLAN_FILE"
}

backup_zone() {
  case "$BACKUP_DIR" in
    /*) ;;
    *) die "backup_dir must be absolute" ;;
  esac
  mkdir -p "$BACKUP_DIR" || die "cannot create DNS backup directory: $BACKUP_DIR"
  chmod 700 "$BACKUP_DIR" || die "cannot protect DNS backup directory"
  db_stamp=$(date -u '+%Y%m%dT%H%M%SZ') || die "cannot create backup timestamp"
  db_backup=$BACKUP_DIR/$ZONE-$db_stamp-$$.json
  [ ! -e "$db_backup" ] || die "refusing to overwrite existing zone backup: $db_backup"
  umask 077
  cp "$ZONE_FILE" "$db_backup" || die "cannot back up the Bunny zone"
  chmod 600 "$db_backup" || die "cannot protect Bunny zone backup"
  say "Backup: $db_backup"
}

record_body() {
  db_action_json=$1
  db_body_path=$2
  printf '%s\n' "$db_action_json" | jq '.desired | {
    Type, Ttl, Value, Name, Weight, Priority, Flags, Tag, Port, Disabled, Comment
  }' >"$db_body_path" || die "cannot construct Bunny record request"
}

apply_actions() {
  while IFS= read -r db_action_json; do
    db_action=$(printf '%s\n' "$db_action_json" | jq -r '.action')
    case "$db_action" in
      create)
        record_body "$db_action_json" "$WORK_DIR/record-body.json"
        api_request PUT "$API_BASE/dnszone/$ZONE_ID/records" "$WORK_DIR/record-body.json" "$WORK_DIR/record-response.json"
        ;;
      update)
        db_record_id=$(printf '%s\n' "$db_action_json" | jq -r '.record_id')
        record_body "$db_action_json" "$WORK_DIR/record-body.json"
        api_request POST "$API_BASE/dnszone/$ZONE_ID/records/$db_record_id" "$WORK_DIR/record-body.json" "$WORK_DIR/record-response.json"
        ;;
      replace)
        db_record_id=$(printf '%s\n' "$db_action_json" | jq -r '.record_id')
        api_request DELETE "$API_BASE/dnszone/$ZONE_ID/records/$db_record_id" '' "$WORK_DIR/delete-response.json"
        record_body "$db_action_json" "$WORK_DIR/record-body.json"
        api_request PUT "$API_BASE/dnszone/$ZONE_ID/records" "$WORK_DIR/record-body.json" "$WORK_DIR/record-response.json"
        ;;
      ok) ;;
      *) die "refusing to apply unresolved DNS action: $db_action" ;;
    esac
  done <"$PLAN_FILE"
}

verify_plan_is_clean() {
  db_conflicts=$(jq -s '[.[] | select(.action == "conflict")] | length' "$PLAN_FILE") \
    || die "cannot inspect DNS plan conflicts"
  db_not_ok=$(jq -s '[.[] | select(.action != "ok")] | length' "$PLAN_FILE") \
    || die "cannot inspect DNS plan results"
  [ "$db_conflicts" -eq 0 ] || die "$db_conflicts DNS conflict(s) prevent a clean declared state"
  [ "$db_not_ok" -eq 0 ] || die "$db_not_ok DNS record(s) do not match the declared state"
}

record_type_id() {
  db_type_name=$(printf '%s\n' "$1" | tr '[:lower:]' '[:upper:]')
  case "$db_type_name" in
    A) printf '%s\n' 0 ;;
    AAAA) printf '%s\n' 1 ;;
    CNAME) printf '%s\n' 2 ;;
    TXT) printf '%s\n' 3 ;;
    MX) printf '%s\n' 4 ;;
    SRV) printf '%s\n' 8 ;;
    CAA) printf '%s\n' 9 ;;
    PTR) printf '%s\n' 10 ;;
    NS) printf '%s\n' 12 ;;
    SVCB) printf '%s\n' 13 ;;
    HTTPS) printf '%s\n' 14 ;;
    TLSA) printf '%s\n' 15 ;;
    *) die "unsupported DNS record type: $1" ;;
  esac
}

record_type_name() {
  case "$1" in
    0) printf '%s\n' A ;;
    1) printf '%s\n' AAAA ;;
    2) printf '%s\n' CNAME ;;
    3) printf '%s\n' TXT ;;
    4) printf '%s\n' MX ;;
    8) printf '%s\n' SRV ;;
    9) printf '%s\n' CAA ;;
    10) printf '%s\n' PTR ;;
    12) printf '%s\n' NS ;;
    13) printf '%s\n' SVCB ;;
    14) printf '%s\n' HTTPS ;;
    15) printf '%s\n' TLSA ;;
    *) die "unsupported Bunny DNS record type ID: $1" ;;
  esac
}

validate_record_id() {
  case "$1" in
    ''|*[!0-9]*|0) die "RECORD_ID must be a positive integer: $1" ;;
  esac
}

validate_nonnegative_integer() {
  db_field=$1
  db_value=$2
  db_max=$3
  case "$db_value" in
    ''|*[!0-9]*) die "$db_field must be a non-negative integer: $db_value" ;;
  esac
  [ "$db_value" -le "$db_max" ] || die "$db_field must not exceed $db_max"
}

validate_positive_integer() {
  validate_nonnegative_integer "$1" "$2" "$3"
  [ "$2" -gt 0 ] || die "$1 must be greater than zero"
}

validate_record_name() {
  db_name_to_validate=$1
  jq -en --arg name "$db_name_to_validate" '
    $name == "" or $name == "@" or ($name | test("^[A-Za-z0-9_.*-]+$"))
  ' >/dev/null || die "invalid zone-relative DNS record name: $db_name_to_validate"
}

reset_record_options() {
  CLI_TYPE_SET=false
  CLI_TYPE=0
  CLI_NAME_SET=false
  CLI_NAME=
  CLI_VALUE_SET=false
  CLI_VALUE=
  CLI_TTL_SET=false
  CLI_TTL=60
  CLI_PRIORITY_SET=false
  CLI_PRIORITY=0
  CLI_WEIGHT_SET=false
  CLI_WEIGHT=0
  CLI_PORT_SET=false
  CLI_PORT=0
  CLI_FLAGS_SET=false
  CLI_FLAGS=0
  CLI_TAG_SET=false
  CLI_TAG=
  CLI_DISABLED_SET=false
  CLI_DISABLED=false
  CLI_CHANGE_COUNT=0
}

parse_record_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --type)
        [ "$#" -ge 2 ] || die '--type requires TYPE'
        CLI_TYPE=$(record_type_id "$2")
        CLI_TYPE_SET=true
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift 2
        ;;
      --name)
        [ "$#" -ge 2 ] || die '--name requires NAME'
        validate_record_name "$2"
        CLI_NAME=$2
        [ "$CLI_NAME" = @ ] && CLI_NAME=
        CLI_NAME_SET=true
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift 2
        ;;
      --value)
        [ "$#" -ge 2 ] || die '--value requires VALUE'
        [ -n "$2" ] || die '--value must not be empty'
        CLI_VALUE=$2
        CLI_VALUE_SET=true
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift 2
        ;;
      --ttl)
        [ "$#" -ge 2 ] || die '--ttl requires SECONDS'
        validate_positive_integer ttl "$2" 2147483647
        CLI_TTL=$2
        CLI_TTL_SET=true
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift 2
        ;;
      --priority|--weight|--port)
        [ "$#" -ge 2 ] || die "$1 requires an integer"
        db_option_name=${1#--}
        validate_nonnegative_integer "$db_option_name" "$2" 2147483647
        case "$1" in
          --priority) CLI_PRIORITY=$2; CLI_PRIORITY_SET=true ;;
          --weight) CLI_WEIGHT=$2; CLI_WEIGHT_SET=true ;;
          --port) CLI_PORT=$2; CLI_PORT_SET=true ;;
        esac
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift 2
        ;;
      --flags)
        [ "$#" -ge 2 ] || die '--flags requires an integer'
        validate_nonnegative_integer flags "$2" 255
        CLI_FLAGS=$2
        CLI_FLAGS_SET=true
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift 2
        ;;
      --tag)
        [ "$#" -ge 2 ] || die '--tag requires TAG'
        CLI_TAG=$2
        CLI_TAG_SET=true
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift 2
        ;;
      --disable)
        CLI_DISABLED=true
        CLI_DISABLED_SET=true
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift
        ;;
      --enable)
        CLI_DISABLED=false
        CLI_DISABLED_SET=true
        CLI_CHANGE_COUNT=$((CLI_CHANGE_COUNT + 1))
        shift
        ;;
      *) die "unknown record option: $1" ;;
    esac
  done
}

write_add_body() {
  db_body_path=$1
  jq -n --argjson type "$CLI_TYPE" --argjson ttl "$CLI_TTL" \
    --arg value "$CLI_VALUE" --arg name "$CLI_NAME" \
    --argjson weight "$CLI_WEIGHT" --argjson priority "$CLI_PRIORITY" \
    --argjson flags "$CLI_FLAGS" --arg tag "$CLI_TAG" \
    --argjson port "$CLI_PORT" --argjson disabled "$CLI_DISABLED" '
      {
        Type: $type, Ttl: $ttl, Value: $value, Name: $name,
        Weight: $weight, Priority: $priority, Flags: $flags,
        Tag: $tag, Port: $port, Disabled: $disabled, Comment: ""
      }
    ' >"$db_body_path" || die 'cannot construct direct DNS record request'
}

write_update_body() {
  db_record_id=$1
  db_body_path=$2
  jq --argjson id "$db_record_id" \
    --arg type_set "$CLI_TYPE_SET" --argjson type "$CLI_TYPE" \
    --arg ttl_set "$CLI_TTL_SET" --argjson ttl "$CLI_TTL" \
    --arg name_set "$CLI_NAME_SET" --arg name "$CLI_NAME" \
    --arg value_set "$CLI_VALUE_SET" --arg value "$CLI_VALUE" \
    --arg weight_set "$CLI_WEIGHT_SET" --argjson weight "$CLI_WEIGHT" \
    --arg priority_set "$CLI_PRIORITY_SET" --argjson priority "$CLI_PRIORITY" \
    --arg flags_set "$CLI_FLAGS_SET" --argjson flags "$CLI_FLAGS" \
    --arg tag_set "$CLI_TAG_SET" --arg tag "$CLI_TAG" \
    --arg port_set "$CLI_PORT_SET" --argjson port "$CLI_PORT" \
    --arg disabled_set "$CLI_DISABLED_SET" --argjson disabled "$CLI_DISABLED" '
      .Records[] | select(.Id == $id) | {
        Type: (if $type_set == "true" then $type else .Type end),
        Ttl: (if $ttl_set == "true" then $ttl else (.Ttl // 60) end),
        Value: (if $value_set == "true" then $value else (.Value // "") end),
        Name: (if $name_set == "true" then $name else (.Name // "") end),
        Weight: (if $weight_set == "true" then $weight else (.Weight // 0) end),
        Priority: (if $priority_set == "true" then $priority else (.Priority // 0) end),
        Flags: (if $flags_set == "true" then $flags else (.Flags // 0) end),
        Tag: (if $tag_set == "true" then $tag else (.Tag // "") end),
        Port: (if $port_set == "true" then $port else (.Port // 0) end),
        Disabled: (if $disabled_set == "true" then $disabled else (.Disabled // false) end),
        Comment: (.Comment // "")
      }
    ' "$ZONE_FILE" >"$db_body_path" || die 'cannot construct direct DNS record update'
}

validate_direct_record_conflicts() {
  db_body_path=$1
  db_excluded_id=$2
  db_type=$(jq '.Type' "$db_body_path") || die 'cannot read direct DNS record type'
  db_name=$(jq -r '.Name' "$db_body_path") || die 'cannot read direct DNS record name'

  db_cname_count=$(jq --argjson type "$db_type" --arg name "$db_name" \
    --argjson excluded "$db_excluded_id" '[
      .Records[]?
      | select(.Id != $excluded)
      | select((.Name // "") == $name and (.Type == 2 or $type == 2))
    ] | length' "$ZONE_FILE") || die 'cannot inspect CNAME exclusivity'
  [ "$db_cname_count" -eq 0 ] || die 'CNAME exclusivity would be violated'

  db_duplicate_count=$(jq --slurpfile wanted "$db_body_path" --argjson excluded "$db_excluded_id" '
    def semantic: {
      Type, Ttl: (.Ttl // 0), Value: (.Value // ""), Name: (.Name // ""),
      Weight: (.Weight // 0), Priority: (.Priority // 0), Flags: (.Flags // 0),
      Tag: (.Tag // ""), Port: (.Port // 0), Disabled: (.Disabled // false)
    };
    ($wanted[0] | semantic) as $desired
    | [.Records[]? | select(.Id != $excluded) | select((. | semantic) == $desired)]
    | length
  ' "$ZONE_FILE") || die 'cannot inspect duplicate DNS records'
  [ "$db_duplicate_count" -eq 0 ] || die 'an identical DNS record already exists'
}

print_zone_records() {
  jq -r '
    def type_name: {
      "0":"A", "1":"AAAA", "2":"CNAME", "3":"TXT", "4":"MX",
      "8":"SRV", "9":"CAA", "10":"PTR", "12":"NS",
      "13":"SVCB", "14":"HTTPS", "15":"TLSA"
    }[(.Type | tostring)] // ("TYPE" + (.Type | tostring));
    .Records
    | sort_by(.Name // "", .Type, .Value // "")[]
    | "id=\(.Id) \(type_name) \(if (.Name // "") == "" then "@" else .Name end) "
      + "\(.Value // "") ttl=\(.Ttl // 0) priority=\(.Priority // 0) "
      + "weight=\(.Weight // 0) port=\(.Port // 0) flags=\(.Flags // 0) "
      + "tag=\(.Tag // "") disabled=\(.Disabled // false)"
  ' "$ZONE_FILE"
}

validate_direct_body() {
  jq -e '
    (.Type | IN(0, 1, 2, 3, 4, 8, 9, 10, 12, 13, 14, 15))
    and (.Ttl | type == "number" and floor == . and . > 0 and . <= 2147483647)
    and (.Value | type == "string" and length > 0)
    and (.Name | type == "string" and (. == "" or test("^[A-Za-z0-9_.*-]+$")))
    and (.Weight | type == "number" and floor == . and . >= 0 and . <= 2147483647)
    and (.Priority | type == "number" and floor == . and . >= 0 and . <= 2147483647)
    and (.Flags | type == "number" and floor == . and . >= 0 and . <= 255)
    and (.Tag | type == "string")
    and (.Port | type == "number" and floor == . and . >= 0 and . <= 2147483647)
    and (.Disabled | type == "boolean")
    and (.Comment | type == "string")
  ' "$1" >/dev/null || die 'direct DNS record fields are invalid'
}

canonical_direct_body() {
  jq -Sc '
    {
      Type, Ttl: (.Ttl // 0), Value: (.Value // ""), Name: (.Name // ""),
      Weight: (.Weight // 0), Priority: (.Priority // 0), Flags: (.Flags // 0),
      Tag: (.Tag // ""), Port: (.Port // 0), Disabled: (.Disabled // false),
      Comment: (.Comment // "")
    }
  ' "$1"
}

canonical_zone_record() {
  db_record_id=$1
  jq -Sc --argjson id "$db_record_id" '
    .Records[] | select(.Id == $id)
    | {
        Type, Ttl: (.Ttl // 0), Value: (.Value // ""), Name: (.Name // ""),
        Weight: (.Weight // 0), Priority: (.Priority // 0), Flags: (.Flags // 0),
        Tag: (.Tag // ""), Port: (.Port // 0), Disabled: (.Disabled // false),
        Comment: (.Comment // "")
      }
  ' "$ZONE_FILE"
}

verify_direct_record() {
  db_record_id=$1
  db_body_path=$2
  db_actual=$(canonical_zone_record "$db_record_id") || die 'cannot verify direct DNS record'
  db_wanted=$(canonical_direct_body "$db_body_path") || die 'cannot normalize direct DNS record request'
  [ -n "$db_actual" ] && [ "$db_actual" = "$db_wanted" ] \
    || die "Bunny DNS record $db_record_id did not verify after the mutation"
}

cmd_validate() {
  validate_config "$1"
  say "Valid record file: $1"
}

cmd_check() {
  prepare_online "$1"
  db_record_count=$(jq '.Records | length' "$ZONE_FILE")
  say "Bunny API access is valid."
  say "Zone: $ZONE (ID $ZONE_ID, $db_record_count current records)"
  say "Owner: $OWNER"
  say "Key file permissions: $(file_mode "$KEY_FILE")"
}

cmd_list() {
  case "$1" in
    *.json)
      prepare_online "$1"
      ;;
    *)
      if [ -f "$1" ]; then
        prepare_online "$1"
      else
        prepare_direct "$1"
      fi
      ;;
  esac
  print_zone_records
}

cmd_add() {
  [ "$#" -ge 4 ] || die 'usage: dns_bunny.sh add ZONE TYPE NAME VALUE [OPTIONS]'
  db_direct_zone=$1
  reset_record_options
  CLI_TYPE=$(record_type_id "$2")
  CLI_TYPE_SET=true
  validate_record_name "$3"
  CLI_NAME=$3
  [ "$CLI_NAME" = @ ] && CLI_NAME=
  CLI_NAME_SET=true
  [ -n "$4" ] || die 'VALUE must not be empty'
  CLI_VALUE=$4
  CLI_VALUE_SET=true
  shift 4
  parse_record_options "$@"

  prepare_direct "$db_direct_zone"
  db_body_path=$WORK_DIR/direct-record.json
  write_add_body "$db_body_path"
  validate_direct_body "$db_body_path"
  validate_direct_record_conflicts "$db_body_path" 0
  backup_zone
  api_request PUT "$API_BASE/dnszone/$ZONE_ID/records" "$db_body_path" "$WORK_DIR/direct-response.json"
  db_record_id=$(jq -r '.Id // empty' "$WORK_DIR/direct-response.json") \
    || die 'cannot read the new Bunny DNS record identifier'
  validate_record_id "$db_record_id"
  fetch_zone
  verify_direct_record "$db_record_id" "$db_body_path"
  db_type_name=$(record_type_name "$(jq '.Type' "$db_body_path")")
  db_name=$(jq -r 'if .Name == "" then "@" else .Name end' "$db_body_path")
  say "Added DNS record id=$db_record_id: $db_type_name $db_name $CLI_VALUE"
}

cmd_update() {
  [ "$#" -ge 3 ] || die 'usage: dns_bunny.sh update ZONE RECORD_ID OPTIONS'
  db_direct_zone=$1
  db_record_id=$2
  validate_record_id "$db_record_id"
  shift 2
  reset_record_options
  parse_record_options "$@"
  [ "$CLI_CHANGE_COUNT" -gt 0 ] || die 'update requires at least one record option'

  prepare_direct "$db_direct_zone"
  db_record_count=$(jq --argjson id "$db_record_id" '[.Records[] | select(.Id == $id)] | length' "$ZONE_FILE") \
    || die 'cannot locate the Bunny DNS record'
  [ "$db_record_count" -eq 1 ] || die "Bunny DNS record ID $db_record_id does not exist in $ZONE"
  db_current_type=$(jq --argjson id "$db_record_id" '.Records[] | select(.Id == $id) | .Type' "$ZONE_FILE") \
    || die 'cannot read the current Bunny DNS record type'
  record_type_name "$db_current_type" >/dev/null

  db_body_path=$WORK_DIR/direct-record.json
  write_update_body "$db_record_id" "$db_body_path"
  validate_direct_body "$db_body_path"
  validate_direct_record_conflicts "$db_body_path" "$db_record_id"
  db_actual=$(canonical_zone_record "$db_record_id") || die 'cannot normalize current Bunny DNS record'
  db_wanted=$(canonical_direct_body "$db_body_path") || die 'cannot normalize requested Bunny DNS record'
  if [ "$db_actual" = "$db_wanted" ]; then
    say "DNS record id=$db_record_id already has the requested values."
    return 0
  fi

  db_current_identity=$(jq --argjson id "$db_record_id" -c \
    '.Records[] | select(.Id == $id) | {Type, Name: (.Name // "")}' "$ZONE_FILE") \
    || die 'cannot read current DNS record identity'
  db_wanted_identity=$(jq -c '{Type, Name}' "$db_body_path") \
    || die 'cannot read requested DNS record identity'
  backup_zone
  if [ "$db_current_identity" = "$db_wanted_identity" ]; then
    api_request POST "$API_BASE/dnszone/$ZONE_ID/records/$db_record_id" \
      "$db_body_path" "$WORK_DIR/direct-response.json"
    db_new_record_id=$db_record_id
    db_action=Updated
  else
    api_request DELETE "$API_BASE/dnszone/$ZONE_ID/records/$db_record_id" '' "$WORK_DIR/delete-response.json"
    api_request PUT "$API_BASE/dnszone/$ZONE_ID/records" "$db_body_path" "$WORK_DIR/direct-response.json"
    db_new_record_id=$(jq -r '.Id // empty' "$WORK_DIR/direct-response.json") \
      || die 'cannot read replacement Bunny DNS record identifier'
    validate_record_id "$db_new_record_id"
    db_action=Replaced
  fi
  fetch_zone
  verify_direct_record "$db_new_record_id" "$db_body_path"
  if [ "$db_action" = Replaced ]; then
    say "Replaced DNS record id=$db_record_id with id=$db_new_record_id."
  else
    say "Updated DNS record id=$db_record_id."
  fi
}

cmd_delete() {
  [ "$#" -eq 2 ] || die 'usage: dns_bunny.sh delete ZONE RECORD_ID'
  db_direct_zone=$1
  db_record_id=$2
  validate_record_id "$db_record_id"
  prepare_direct "$db_direct_zone"
  db_record_count=$(jq --argjson id "$db_record_id" '[.Records[] | select(.Id == $id)] | length' "$ZONE_FILE") \
    || die 'cannot locate the Bunny DNS record'
  [ "$db_record_count" -eq 1 ] || die "Bunny DNS record ID $db_record_id does not exist in $ZONE"
  backup_zone
  api_request DELETE "$API_BASE/dnszone/$ZONE_ID/records/$db_record_id" '' "$WORK_DIR/delete-response.json"
  fetch_zone
  db_record_count=$(jq --argjson id "$db_record_id" '[.Records[] | select(.Id == $id)] | length' "$ZONE_FILE") \
    || die 'cannot verify the DNS record deletion'
  [ "$db_record_count" -eq 0 ] || die "Bunny DNS record $db_record_id still exists after deletion"
  say "Deleted DNS record id=$db_record_id from $ZONE."
}

cmd_plan() {
  prepare_online "$1"
  build_plan
  print_plan || die "cannot print DNS plan"
  db_conflicts=$(count_actions conflict) || die "cannot count DNS plan conflicts"
  [ "$db_conflicts" -eq 0 ] || die "$db_conflicts DNS conflict(s) require review"
}

cmd_apply() {
  prepare_online "$1"
  build_plan
  print_plan || die "cannot print DNS plan"
  db_conflicts=$(count_actions conflict) || die "cannot count DNS plan conflicts"
  [ "$db_conflicts" -eq 0 ] || die "$db_conflicts DNS conflict(s) require review"
  db_creates=$(count_actions create) || die "cannot count DNS record creations"
  db_updates=$(count_actions update) || die "cannot count DNS record updates"
  db_replaces=$(count_actions replace) || die "cannot count DNS record replacements"
  db_mutations=$((db_creates + db_updates + db_replaces))

  if [ "$db_mutations" -eq 0 ]; then
    say 'No DNS changes are required.'
    return 0
  fi

  backup_zone
  apply_actions
  fetch_zone
  build_plan
  print_plan || die "cannot print verified DNS plan"
  verify_plan_is_clean
  say "Applied and verified $db_mutations DNS change(s)."
}

cmd_verify() {
  prepare_online "$1"
  build_plan
  print_plan || die "cannot print DNS plan"
  verify_plan_is_clean
  say 'All declared DNS records match Bunny.'
}

cmd_prune() {
  prepare_online "$1"
  build_plan
  verify_plan_is_clean

  db_desired_comments=$WORK_DIR/desired-comments.json
  jq '[.[].Comment]' "$DESIRED_FILE" >"$db_desired_comments" || die "cannot prepare managed DNS key list"
  db_prune_file=$WORK_DIR/prune.ndjson
  jq -c --arg prefix "$MANAGED_PREFIX" --slurpfile wanted "$db_desired_comments" '
    .Records[]?
    | select((.Comment // "") | startswith($prefix))
    | select(([($wanted[0][] == (.Comment // ""))] | any) | not)
    | {Id, Type, Name, Value, Comment}
  ' "$ZONE_FILE" >"$db_prune_file" || die "cannot prepare DNS prune plan"

  db_prune_count=$(wc -l <"$db_prune_file" | tr -d ' ')
  if [ "$db_prune_count" -eq 0 ]; then
    say 'No obsolete project-owned DNS records exist.'
    return 0
  fi

  jq -r '"DELETE id=\(.Id) type=\(.Type) name=\(.Name // "@") value=\(.Value // "") -- \(.Comment)"' "$db_prune_file"
  backup_zone
  while IFS= read -r db_prune_json; do
    db_record_id=$(printf '%s\n' "$db_prune_json" | jq -r '.Id')
    api_request DELETE "$API_BASE/dnszone/$ZONE_ID/records/$db_record_id" '' "$WORK_DIR/delete-response.json"
  done <"$db_prune_file"
  say "Deleted $db_prune_count obsolete project-owned DNS record(s)."
}

cmd_init_key() {
  db_key_path=$1
  case "$db_key_path" in
    /*) ;;
    *) die "KEYFILE must be an absolute path" ;;
  esac
  [ ! -e "$db_key_path" ] || die "refusing to overwrite existing key file: $db_key_path"
  [ -r /dev/tty ] && [ -w /dev/tty ] || die "init-key requires an interactive terminal"

  db_key_dir=$(dirname "$db_key_path")
  case "$db_key_dir" in
    /|'') die "refusing unsafe key directory: $db_key_dir" ;;
  esac
  if [ -n "${HOME:-}" ] && [ "$db_key_dir" = "$HOME" ]; then
    die "refusing to change permissions on the home directory"
  fi

  mkdir -p "$db_key_dir" || die "cannot create key directory"
  chmod 700 "$db_key_dir" || die "cannot protect key directory"
  db_tty_state=$(stty -g </dev/tty) || die "cannot inspect terminal state"
  printf 'Bunny API key: ' >/dev/tty
  stty -echo </dev/tty || die "cannot disable terminal echo"
  trap 'stty "$db_tty_state" </dev/tty 2>/dev/null || :; printf "\n" >/dev/tty; exit 130' HUP INT TERM
  db_key_value=
  IFS= read -r db_key_value </dev/tty
  db_read_status=$?
  stty "$db_tty_state" </dev/tty || die "cannot restore terminal state"
  trap 'cleanup; exit 130' HUP INT TERM
  printf '\n' >/dev/tty
  [ "$db_read_status" -eq 0 ] || die "could not read the Bunny API key"
  validate_api_key "$db_key_value"

  umask 077
  (set -C; printf '%s\n' "$db_key_value" >"$db_key_path") || die "cannot create key file"
  db_key_value=
  unset db_key_value
  chmod 600 "$db_key_path" || die "cannot protect key file"
  say "Stored Bunny API key in $db_key_path with mode 0600."
}

if [ "$#" -eq 0 ]; then
  usage
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --api-key)
      [ "$#" -ge 2 ] || die '--api-key requires FILE'
      API_KEY_OPTION=$2
      shift 2
      ;;
    --api-key=*)
      API_KEY_OPTION=${1#--api-key=}
      [ -n "$API_KEY_OPTION" ] || die '--api-key requires FILE'
      shift
      ;;
    --backup-dir)
      [ "$#" -ge 2 ] || die '--backup-dir requires DIR'
      BACKUP_DIR_OPTION=$2
      shift 2
      ;;
    --backup-dir=*)
      BACKUP_DIR_OPTION=${1#--backup-dir=}
      [ -n "$BACKUP_DIR_OPTION" ] || die '--backup-dir requires DIR'
      shift
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

[ "$#" -gt 0 ] || die 'a command is required after global options'

command_name=$1
shift

case "$command_name" in
  help|-h|--help)
    [ "$#" -eq 0 ] || die 'help takes no arguments'
    usage
    ;;
  version|-V|--version)
    [ "$#" -eq 0 ] || die 'version takes no arguments'
    say "$PROGRAM $VERSION"
    ;;
  init-key)
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh init-key KEYFILE'
    cmd_init_key "$1"
    ;;
  validate)
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh validate RECORDS.json'
    cmd_validate "$1"
    ;;
  check)
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh check RECORDS.json'
    cmd_check "$1"
    ;;
  list)
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh list ZONE|RECORDS.json'
    cmd_list "$1"
    ;;
  add)
    cmd_add "$@"
    ;;
  update)
    cmd_update "$@"
    ;;
  delete)
    cmd_delete "$@"
    ;;
  plan)
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh plan RECORDS.json'
    cmd_plan "$1"
    ;;
  apply)
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh apply RECORDS.json'
    cmd_apply "$1"
    ;;
  verify)
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh verify RECORDS.json'
    cmd_verify "$1"
    ;;
  prune)
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh prune RECORDS.json'
    cmd_prune "$1"
    ;;
  *)
    die "unknown command: $command_name"
    ;;
esac
