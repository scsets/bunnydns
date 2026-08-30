#!/bin/sh

# Filename: test_dns_bunny.sh
# Description: Offline behavior and portability tests for dns_bunny.sh.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.5.4
# Last-Updated: 2026-08-30
# Update #: 6

set -u
LC_ALL=C
export LC_ALL

db_script_dir=$(unset CDPATH; cd "$(dirname "$0")" && pwd) || exit 1
db_project_dir=$(unset CDPATH; cd "$db_script_dir/.." && pwd) || exit 1
db_program=$db_project_dir/dns_bunny.sh
db_test_root=$(mktemp -d "${TMPDIR:-/tmp}/dns_bunny_tests.XXXXXX") || exit 1
db_failures=0
db_checks=0
db_command_output=
db_command_status=0

cleanup() {
  case "$db_test_root" in
    "${TMPDIR:-/tmp}"/dns_bunny_tests.*) rm -rf "$db_test_root" ;;
    *) printf 'Refusing to remove unexpected test path: %s\n' "$db_test_root" >&2 ;;
  esac
}
trap 'cleanup' 0 HUP INT TERM

record_failure() {
  db_failures=$((db_failures + 1))
  printf 'not ok - %s\n' "$1" >&2
}

record_success() {
  printf 'ok - %s\n' "$1"
}

run_command() {
  db_command_output=$("$@" 2>&1)
  db_command_status=$?
}

expect_status() {
  db_expected_status=$1
  db_label=$2
  shift 2
  db_checks=$((db_checks + 1))
  run_command "$@"
  if [ "$db_command_status" -eq "$db_expected_status" ]; then
    record_success "$db_label"
  else
    record_failure "$db_label (status $db_command_status, expected $db_expected_status)"
    printf '%s\n' "$db_command_output" >&2
  fi
}

expect_output() {
  db_needle=$1
  db_label=$2
  db_checks=$((db_checks + 1))
  case "$db_command_output" in
    *"$db_needle"*) record_success "$db_label" ;;
    *)
      record_failure "$db_label (missing: $db_needle)"
      printf '%s\n' "$db_command_output" >&2
      ;;
  esac
}

expect_jq() {
  db_expression=$1
  db_file=$2
  db_label=$3
  db_checks=$((db_checks + 1))
  if jq -e "$db_expression" "$db_file" >/dev/null 2>&1; then
    record_success "$db_label"
  else
    record_failure "$db_label"
    jq '.' "$db_file" >&2
  fi
}

file_mode() {
  case $(uname -s) in
    Darwin) /usr/bin/stat -f '%Lp' "$1" ;;
    Linux|SunOS) stat -c '%a' "$1" ;;
    *) return 1 ;;
  esac
}

db_state_dir=$db_test_root/state
db_mock_bin=$db_test_root/mock-bin
db_mock_os_bin=$db_test_root/mock-os-bin
db_mock_jq_bin=$db_test_root/mock-jq-bin
db_bad_stat_bin=$db_test_root/bad-stat-bin
db_key_file=$db_test_root/secrets/api-key
db_backup_dir=$db_test_root/backups
db_replace_backup_dir=$db_test_root/replace-backups
db_prune_backup_dir=$db_test_root/prune-backups
db_direct_backup_dir=$db_test_root/direct-backups
db_config_file=$db_test_root/records.json
db_real_jq=$(command -v jq) || exit 1

mkdir -p "$db_state_dir" "$db_mock_bin" "$db_mock_os_bin" "$db_mock_jq_bin" \
  "$db_bad_stat_bin" "$(dirname "$db_key_file")" || exit 1
ln -s "$db_script_dir/mock_curl.sh" "$db_mock_bin/curl" || exit 1
ln -s "$db_script_dir/mock_curl.sh" "$db_mock_os_bin/curl" || exit 1
ln -s "$db_script_dir/mock_uname.sh" "$db_mock_os_bin/uname" || exit 1
ln -s "$db_script_dir/mock_stat.sh" "$db_mock_os_bin/stat" || exit 1
ln -s "$db_script_dir/mock_jq.sh" "$db_mock_jq_bin/jq" || exit 1
ln -s "$db_script_dir/mock_bad_stat.sh" "$db_bad_stat_bin/stat" || exit 1
printf '%s\n' 'test-bunny-api-key' >"$db_key_file" || exit 1
chmod 600 "$db_key_file" || exit 1

cat >"$db_state_dir/zone.json" <<'EOF'
{
  "Id": 42,
  "Domain": "example.test",
  "Records": [
    {
      "Id": 101,
      "Type": 0,
      "Ttl": 300,
      "Value": "192.0.2.10",
      "Name": "www",
      "Weight": 0,
      "Priority": 0,
      "Flags": 0,
      "Tag": "",
      "Port": 0,
      "Disabled": false,
      "Comment": ""
    },
    {
      "Id": 102,
      "Type": 3,
      "Ttl": 300,
      "Value": "service-verification=ready",
      "Name": "",
      "Weight": 0,
      "Priority": 0,
      "Flags": 0,
      "Tag": "",
      "Port": 0,
      "Disabled": false,
      "Comment": "managed-by:project-one; key=site-verification"
    },
    {
      "Id": 103,
      "Type": 0,
      "Ttl": 300,
      "Value": "198.51.100.20",
      "Name": "other",
      "Weight": 0,
      "Priority": 0,
      "Flags": 0,
      "Tag": "",
      "Port": 0,
      "Disabled": false,
      "Comment": "managed-by:other-project; key=other-origin"
    }
  ]
}
EOF

cat >"$db_config_file" <<EOF
{
  "owner": "project-one",
  "zone": "example.test",
  "key_file": "$db_key_file",
  "backup_dir": "$db_backup_dir",
  "records": [
    {"key": "web-origin", "type": "A", "name": "www", "value": "192.0.2.10", "ttl": 300},
    {"key": "site-verification", "type": "TXT", "name": "@", "value": "service-verification=ready", "ttl": 300},
    {"key": "api-origin", "type": "A", "name": "api", "value": "192.0.2.11"}
  ]
}
EOF

expect_status 0 'no-argument usage is successful and non-mutating' "$db_program"
expect_output 'dns_bunny.sh 0.5.4' 'usage reports the program version'

expect_status 0 'version command succeeds' "$db_program" version
expect_output 'dns_bunny.sh 0.5.4' 'version command is exact'

expect_status 0 'valid declaration passes offline validation' "$db_program" validate "$db_config_file"
expect_output 'Valid record file:' 'validation identifies the checked file'

expect_status 1 'jq without IN support is rejected with the documented version floor' env \
  MOCK_JQ_REAL="$db_real_jq" MOCK_JQ_NO_IN=1 PATH="$db_mock_jq_bin:$PATH" \
  "$db_program" validate "$db_config_file"
expect_output 'jq 1.6 or newer is required' 'old jq failure explains the required release'

db_missing_owner=$db_test_root/missing-owner.json
jq 'del(.owner)' "$db_config_file" >"$db_missing_owner" || exit 1
expect_status 1 'a missing project owner is rejected' "$db_program" validate "$db_missing_owner"
expect_output 'invalid record file' 'missing owner reports a validation error'

db_duplicate_keys=$db_test_root/duplicate-keys.json
jq '.records[1].key = .records[0].key' "$db_config_file" >"$db_duplicate_keys" || exit 1
expect_status 1 'duplicate durable record keys are rejected' "$db_program" validate "$db_duplicate_keys"

chmod 644 "$db_key_file" || exit 1
expect_status 1 'an over-permissive API key is rejected' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" check "$db_config_file"
expect_output 'must have mode 0400 or 0600' 'key-mode failure explains the accepted modes'
chmod 600 "$db_key_file" || exit 1

if [ "$(uname -s)" = Darwin ]; then
  expect_status 0 'Darwin ignores an incompatible stat placed first on PATH' env \
    MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_bad_stat_bin:$db_mock_bin:$PATH" \
    "$db_program" check "$db_config_file"
  expect_output 'Key file permissions: 600' 'Darwin mode inspection uses BSD stat'
fi

expect_status 0 'plan succeeds against the offline Bunny API' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" plan "$db_config_file"
expect_output 'UPDATE web-origin:' 'plan adopts an exact unmanaged record'
expect_output 'OK site-verification:' 'plan recognizes a matching owned record'
expect_output 'CREATE api-origin:' 'plan creates an absent record'

db_jq_failure_state=$db_test_root/jq-action-count
expect_status 1 'a mid-plan jq failure aborts the parent command' env \
  MOCK_BUNNY_STATE="$db_state_dir" MOCK_JQ_REAL="$db_real_jq" \
  MOCK_JQ_FAIL_ACTION_AT=2 MOCK_JQ_STATE="$db_jq_failure_state" \
  PATH="$db_mock_jq_bin:$db_mock_bin:$PATH" \
  "$db_program" plan "$db_config_file"
expect_output 'cannot write DNS plan' 'mid-plan failure is reported instead of accepting a partial plan'

expect_status 0 'apply performs and verifies the planned changes' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" apply "$db_config_file"
expect_output 'Applied and verified 2 DNS change(s).' 'apply reports the mutation count'
expect_jq '[.Records[] | select(.Comment == "managed-by:project-one; key=web-origin")] | length == 1' \
  "$db_state_dir/zone.json" 'apply records ownership when adopting'
expect_jq '[.Records[] | select(.Comment == "managed-by:project-one; key=api-origin" and .Ttl == 60)] | length == 1' \
  "$db_state_dir/zone.json" 'apply creates an omitted-TTL record with the 60-second default'
expect_jq '[.Records[] | select(.Comment == "managed-by:other-project; key=other-origin")] | length == 1' \
  "$db_state_dir/zone.json" 'apply preserves another project owner'

db_backup_count=$(find "$db_backup_dir" -type f | wc -l | tr -d ' ')
db_checks=$((db_checks + 1))
if [ "$db_backup_count" -eq 1 ]; then
  record_success 'apply writes exactly one pre-change backup'
else
  record_failure "apply backup count is $db_backup_count, expected 1"
fi
db_backup_file=$(find "$db_backup_dir" -type f | sed -n '1p')
db_checks=$((db_checks + 1))
if [ "$(file_mode "$db_backup_file")" = 600 ] && [ "$(file_mode "$db_backup_dir")" = 700 ]; then
  record_success 'backup file and directory modes are protected'
else
  record_failure 'backup file or directory mode is not protected'
fi

expect_status 0 'verify accepts the converged declaration' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" verify "$db_config_file"
expect_output 'All declared DNS records match Bunny.' 'verify reports a clean declaration'

expect_status 0 'records-file listing succeeds against the offline API' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" list --records-file "$db_config_file"
expect_output 'A api 192.0.2.11' 'list shows public record data'
expect_output 'id=104' 'list exposes stable record IDs for direct editing'
db_checks=$((db_checks + 1))
case "$db_command_output" in
  *managed-by:*|*test-bunny-api-key*) record_failure 'list exposed ownership or credential data' ;;
  *) record_success 'list omits ownership and credential data' ;;
esac

expect_status 1 'the former declaration flag is rejected' \
  "$db_program" list --declaration "$db_config_file"
expect_output 'list ZONE|--records-file RECORDS.json' \
  'the rejection points to the renamed records-file flag'

db_direct_home=$db_test_root/direct-home
mkdir -p "$db_direct_home/.secrets" || exit 1
cp "$db_key_file" "$db_direct_home/.secrets/bunnynet-api-key" || exit 1
chmod 600 "$db_direct_home/.secrets/bunnynet-api-key" || exit 1
: >"$db_direct_home/example.test" || exit 1
db_original_dir=$(pwd)
cd "$db_direct_home" || exit 1
expect_status 0 'a same-named local file does not shadow a zone listing' env \
  HOME="$db_direct_home" MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" list example.test
cd "$db_original_dir" || exit 1
expect_output 'id=104 A api 192.0.2.11' 'direct list uses the default protected key path'

expect_status 0 'read-only listing needs no HOME-backed backup directory' env \
  HOME= MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" --api-key "$db_key_file" list example.test
expect_output 'id=104 A api 192.0.2.11' 'explicit key path is sufficient for read-only listing'

expect_status 0 'direct add accepts record fields from CLI arguments' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" --api-key "$db_key_file" --backup-dir "$db_direct_backup_dir" \
  add example.test A cli 192.0.2.55
expect_output 'Added DNS record id=105: A cli 192.0.2.55' 'direct add reports the new record ID'
expect_jq '[.Records[] | select(.Id == 105 and .Name == "cli" and .Value == "192.0.2.55" and .Ttl == 60)] | length == 1' \
  "$db_state_dir/zone.json" 'direct add uses the 60-second TTL default'

db_advanced_zone=$db_test_root/direct-advanced-zone.json
jq '.Records |= map(if .Id == 105 then . + {
  Accelerated: true,
  AcceleratedPullZoneId: 777,
  MonitorType: 2,
  GeolocationLatitude: 41.9028,
  GeolocationLongitude: 12.4964,
  LatencyZone: "EU",
  SmartRoutingType: 1,
  EnviromentalVariables: [{Name: "REGION", Value: "eu"}],
  AutoSslIssuance: true
} else . end)' "$db_state_dir/zone.json" >"$db_advanced_zone" || exit 1
mv "$db_advanced_zone" "$db_state_dir/zone.json" || exit 1

expect_status 0 'direct update changes only named fields' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" --api-key "$db_key_file" --backup-dir "$db_direct_backup_dir" \
  update example.test 105 --value 192.0.2.56 --disable
expect_output 'Updated DNS record id=105.' 'direct update reports the stable record ID'
expect_jq '[.Records[] | select(.Id == 105 and .Name == "cli" and .Value == "192.0.2.56" and .Ttl == 60 and .Disabled)] | length == 1' \
  "$db_state_dir/zone.json" 'direct update preserves fields that were not named'
expect_jq '[.Records[] | select(.Id == 105 and .Accelerated and .PullZoneId == 777 and
  .MonitorType == 2 and .SmartRoutingType == 1 and .AutoSslIssuance and
  .EnviromentalVariables == [{"Name":"REGION","Value":"eu"}])] | length == 1' \
  "$db_state_dir/zone.json" 'direct update preserves advanced Bunny record fields'

expect_status 0 'direct identity changes replace the Bunny record safely' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" --api-key "$db_key_file" --backup-dir "$db_direct_backup_dir" \
  update example.test 105 --name cli-renamed
expect_output 'Replaced DNS record id=105 with id=105.' 'direct replacement reports old and new IDs'
expect_jq '[.Records[] | select(.Id == 105 and .Name == "cli-renamed" and .Value == "192.0.2.56")] | length == 1' \
  "$db_state_dir/zone.json" 'direct replacement preserves the record value'
expect_jq '[.Records[] | select(.Id == 105 and .Accelerated and .PullZoneId == 777 and
  .MonitorType == 2 and .SmartRoutingType == 1 and .AutoSslIssuance and
  .EnviromentalVariables == [{"Name":"REGION","Value":"eu"}])] | length == 1' \
  "$db_state_dir/zone.json" 'direct replacement preserves advanced Bunny record fields'

expect_status 0 'direct delete removes the exact numeric record ID' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" --api-key "$db_key_file" --backup-dir "$db_direct_backup_dir" \
  delete example.test 105
expect_output 'Deleted DNS record id=105 from example.test.' 'direct delete reports its target'
expect_jq '[.Records[] | select(.Id == 105)] | length == 0' \
  "$db_state_dir/zone.json" 'direct delete removes only the selected record'

db_direct_backup_count=$(find "$db_direct_backup_dir" -type f | wc -l | tr -d ' ')
db_checks=$((db_checks + 1))
if [ "$db_direct_backup_count" -eq 4 ]; then
  record_success 'every direct mutation writes a protected pre-change backup'
else
  record_failure "direct backup count is $db_direct_backup_count, expected 4"
fi

expect_status 1 'direct add validates record options before contacting Bunny' \
  "$db_program" --api-key "$db_key_file" add example.test A bad 192.0.2.99 --ttl 0
expect_output 'ttl must be greater than zero' 'invalid direct TTL explains the accepted range'

db_request_count_before=$(wc -l <"$db_state_dir/requests.log" | tr -d ' ')
expect_status 1 'an invalid positional type stops before Bunny access' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" --api-key "$db_key_file" add example.test NOT_A_TYPE bad 192.0.2.99
expect_output 'unsupported DNS record type: NOT_A_TYPE' 'invalid positional type is reported directly'
expect_status 1 'an invalid update type stops before Bunny access' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" --api-key "$db_key_file" update example.test 104 --type NOT_A_TYPE
expect_output 'unsupported DNS record type: NOT_A_TYPE' 'invalid update type is reported directly'
db_request_count_after=$(wc -l <"$db_state_dir/requests.log" | tr -d ' ')
db_checks=$((db_checks + 1))
if [ "$db_request_count_before" -eq "$db_request_count_after" ]; then
  record_success 'invalid direct types perform no Bunny API request'
else
  record_failure 'invalid direct types contacted the Bunny API'
fi

db_replace_config=$db_test_root/replace-records.json
jq --arg backup_dir "$db_replace_backup_dir" \
  '.backup_dir = $backup_dir | .records[0].name = "web"' \
  "$db_config_file" >"$db_replace_config" || exit 1
expect_status 0 'plan identifies an owned record identity change' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" plan "$db_replace_config"
expect_output 'REPLACE web-origin:' 'identity change is planned as a replacement'
expect_status 0 'apply performs and verifies the replacement' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" apply "$db_replace_config"
expect_output 'Applied and verified 1 DNS change(s).' 'replacement reports one mutation'
expect_jq '[.Records[] | select(.Comment == "managed-by:project-one; key=web-origin" and .Name == "web")] | length == 1' \
  "$db_state_dir/zone.json" 'replacement creates the new record identity'
expect_jq '[.Records[] | select(.Id == 101)] | length == 0' \
  "$db_state_dir/zone.json" 'replacement removes the old record identity'

db_prune_config=$db_test_root/prune-records.json
jq --arg backup_dir "$db_prune_backup_dir" \
  '.backup_dir = $backup_dir | .records = .records[0:2]' \
  "$db_replace_config" >"$db_prune_config" || exit 1
expect_status 0 'prune deletes only obsolete records for this owner' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" prune "$db_prune_config"
expect_output 'Deleted 1 obsolete project-owned DNS record(s).' 'prune reports its deletion count'
expect_jq '[.Records[] | select(.Comment == "managed-by:project-one; key=api-origin")] | length == 0' \
  "$db_state_dir/zone.json" 'prune removes the obsolete record'
expect_jq '[.Records[] | select(.Comment == "managed-by:other-project; key=other-origin")] | length == 1' \
  "$db_state_dir/zone.json" 'prune preserves another project owner'

expect_status 0 'Linux key-mode branch accepts mode 0600' env \
  MOCK_BUNNY_STATE="$db_state_dir" MOCK_UNAME=Linux MOCK_FILE_MODE=600 \
  PATH="$db_mock_os_bin:$PATH" "$db_program" check "$db_config_file"
expect_status 0 'SmartOS key-mode branch accepts mode 0600' env \
  MOCK_BUNNY_STATE="$db_state_dir" MOCK_UNAME=SunOS MOCK_FILE_MODE=600 \
  PATH="$db_mock_os_bin:$PATH" "$db_program" check "$db_config_file"

db_conflict_zone=$db_test_root/conflict-zone.json
jq '.Records += [{
  "Id": 200, "Type": 0, "Ttl": 300, "Value": "192.0.2.99", "Name": "clash",
  "Weight": 0, "Priority": 0, "Flags": 0, "Tag": "", "Port": 0,
  "Disabled": false, "Comment": ""
}]' "$db_state_dir/zone.json" >"$db_conflict_zone" || exit 1
mv "$db_conflict_zone" "$db_state_dir/zone.json"
db_conflict_config=$db_test_root/conflict-records.json
jq '.owner = "conflict-project" | .records = [{
  "key": "clashing-name", "type": "CNAME", "name": "clash",
  "value": "target.example.test", "ttl": 300
}]' "$db_config_file" >"$db_conflict_config" || exit 1
expect_status 1 'CNAME exclusivity conflict stops the plan' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" plan "$db_conflict_config"
expect_output 'CONFLICT clashing-name:' 'conflict is visible in the plan'
expect_output 'DNS conflict(s) require review' 'conflict failure requests review'
expect_status 1 'verify distinguishes a conflict from an ordinary mismatch' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" verify "$db_conflict_config"
expect_output 'DNS conflict(s) prevent a clean declared state' 'clean-plan failure identifies the conflict'

db_absent_config=$db_test_root/absent-zone.json
jq '.zone = "absent.test"' "$db_config_file" >"$db_absent_config" || exit 1
expect_status 1 'an absent exact zone match is rejected' env \
  MOCK_BUNNY_STATE="$db_state_dir" PATH="$db_mock_bin:$PATH" \
  "$db_program" check "$db_absent_config"
expect_output 'expected one Bunny DNS zone named absent.test, found 0' 'zone lookup failure is explicit'

db_checks=$((db_checks + 1))
if grep 'PUT https://api.bunny.net/dnszone/42/records' "$db_state_dir/requests.log" >/dev/null 2>&1 \
  && grep 'POST https://api.bunny.net/dnszone/42/records/101' "$db_state_dir/requests.log" >/dev/null 2>&1 \
  && grep 'DELETE https://api.bunny.net/dnszone/42/records/' "$db_state_dir/requests.log" >/dev/null 2>&1; then
  record_success 'mutations use Bunny add, update, and delete methods'
else
  record_failure 'expected Bunny mutation methods were not observed'
fi

if [ "$db_failures" -ne 0 ]; then
  printf '%s checks, %s failures\n' "$db_checks" "$db_failures" >&2
  exit 1
fi

printf '%s checks passed\n' "$db_checks"
