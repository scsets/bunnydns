#!/bin/sh

# Filename: mock_curl.sh
# Description: Stateful curl replacement for offline Bunny DNS behavior tests.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.4.0
# Last-Updated: 2026-08-29
# Update #: 0

set -u

db_method=GET
db_url=
db_body_file=
db_output_file=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config|--header|--write-out)
      [ "$#" -ge 2 ] || exit 2
      shift 2
      ;;
    --request)
      [ "$#" -ge 2 ] || exit 2
      db_method=$2
      shift 2
      ;;
    --url)
      [ "$#" -ge 2 ] || exit 2
      db_url=$2
      shift 2
      ;;
    --data-binary)
      [ "$#" -ge 2 ] || exit 2
      db_body_file=${2#@}
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || exit 2
      db_output_file=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[ -n "$db_url" ] || exit 2
[ -n "$db_output_file" ] || exit 2
: "${MOCK_BUNNY_STATE:?MOCK_BUNNY_STATE is required}"

db_zone_file=$MOCK_BUNNY_STATE/zone.json
db_request_log=$MOCK_BUNNY_STATE/requests.log
printf '%s %s\n' "$db_method" "$db_url" >>"$db_request_log"

respond() {
  printf '%s' "$1"
  exit 0
}

not_found() {
  printf '%s\n' '{"Message":"not found"}' >"$db_output_file"
  respond 404
}

case "$db_url" in
  */dnszone\?*)
    if [ "$db_method" != GET ]; then
      not_found
    fi
    jq '{Items: [{Id: .Id, Domain: .Domain}], CurrentPage: 1, TotalItems: 1, HasMoreItems: false}' \
      "$db_zone_file" >"$db_output_file"
    respond 200
    ;;
  */dnszone/42)
    if [ "$db_method" != GET ]; then
      not_found
    fi
    cp "$db_zone_file" "$db_output_file"
    respond 200
    ;;
  */dnszone/42/records)
    if [ "$db_method" != PUT ] || [ -z "$db_body_file" ]; then
      not_found
    fi
    db_record_id=$(jq '([.Records[].Id] | max // 0) + 1' "$db_zone_file")
    db_tmp_file=$MOCK_BUNNY_STATE/.zone.$$.json
    jq --argjson id "$db_record_id" --slurpfile record "$db_body_file" \
      '.Records += [($record[0] + {Id: $id})]' "$db_zone_file" >"$db_tmp_file" || exit 2
    mv "$db_tmp_file" "$db_zone_file"
    jq --argjson id "$db_record_id" '.Records[] | select(.Id == $id)' \
      "$db_zone_file" >"$db_output_file"
    respond 201
    ;;
  */dnszone/42/records/*)
    db_record_id=${db_url##*/}
    case "$db_record_id" in
      ''|*[!0-9]*) not_found ;;
    esac
    db_exists=$(jq --argjson id "$db_record_id" '[.Records[] | select(.Id == $id)] | length' "$db_zone_file")
    [ "$db_exists" -eq 1 ] || not_found
    db_tmp_file=$MOCK_BUNNY_STATE/.zone.$$.json
    case "$db_method" in
      POST)
        [ -n "$db_body_file" ] || not_found
        jq --argjson id "$db_record_id" --slurpfile record "$db_body_file" \
          '.Records |= map(if .Id == $id then ($record[0] + {Id: $id}) else . end)' \
          "$db_zone_file" >"$db_tmp_file" || exit 2
        mv "$db_tmp_file" "$db_zone_file"
        jq --argjson id "$db_record_id" '.Records[] | select(.Id == $id)' \
          "$db_zone_file" >"$db_output_file"
        respond 200
        ;;
      DELETE)
        jq --argjson id "$db_record_id" '.Records |= map(select(.Id != $id))' \
          "$db_zone_file" >"$db_tmp_file" || exit 2
        mv "$db_tmp_file" "$db_zone_file"
        : >"$db_output_file"
        respond 204
        ;;
      *)
        not_found
        ;;
    esac
    ;;
  *)
    not_found
    ;;
esac
