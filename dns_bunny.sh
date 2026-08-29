#!/bin/sh

# Filename: dns_bunny.sh
# Description: Reconcile project-owned Bunny DNS records from a declarative JSON file.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-18 Tue 00:00
# Version: 0.4.1
# Last-Updated: 2026-08-29 Sat 00:00
# Update #: 7

set -u
LC_ALL=C
export LC_ALL

PROGRAM=dns_bunny.sh
VERSION=0.4.1
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

usage() {
  printf '%s %s\n' "$PROGRAM" "$VERSION"
  cat <<'EOF'
Reconcile project-owned records in an existing Bunny DNS zone.

Usage:
  dns_bunny.sh
  dns_bunny.sh help
  dns_bunny.sh version
  dns_bunny.sh init-key KEYFILE
  dns_bunny.sh validate RECORDS.json
  dns_bunny.sh check RECORDS.json
  dns_bunny.sh list RECORDS.json
  dns_bunny.sh plan RECORDS.json
  dns_bunny.sh apply RECORDS.json
  dns_bunny.sh verify RECORDS.json
  dns_bunny.sh prune RECORDS.json

With no command, nothing changes. Mutations require apply, prune, or init-key.
The Bunny API key is read from the protected key_file named in RECORDS.json.
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
      and ((.ttl // 300) | positive_int)
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
  KEY_FILE=$(jq -r '.key_file' "$CONFIG_FILE") || die "cannot read key_file"
  BACKUP_DIR=$(jq -r '.backup_dir' "$CONFIG_FILE") || die "cannot read backup_dir"
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
      Ttl: (.ttl // 300),
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
  db_backup=$BACKUP_DIR/$ZONE-$db_stamp.json
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
  prepare_online "$1"
  jq -r '
    def type_name: {
      "0":"A", "1":"AAAA", "2":"CNAME", "3":"TXT", "4":"MX",
      "8":"SRV", "9":"CAA", "10":"PTR", "12":"NS",
      "13":"SVCB", "14":"HTTPS", "15":"TLSA"
    }[(.Type | tostring)] // ("TYPE" + (.Type | tostring));
    .Records
    | sort_by(.Name // "", .Type, .Value // "")[]
    | "\(type_name) \(if (.Name // "") == "" then "@" else .Name end) "
      + "\(.Value // "") ttl=\(.Ttl // 0) priority=\(.Priority // 0) "
      + "weight=\(.Weight // 0) port=\(.Port // 0) flags=\(.Flags // 0) "
      + "tag=\(.Tag // "") disabled=\(.Disabled // false)"
  ' "$ZONE_FILE"
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
    [ "$#" -eq 1 ] || die 'usage: dns_bunny.sh list RECORDS.json'
    cmd_list "$1"
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
