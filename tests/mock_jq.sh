#!/bin/sh

# Filename: mock_jq.sh
# Description: Delegate to jq while injecting selected dependency and planning failures.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.4.1
# Last-Updated: 2026-08-29
# Update #: 0

set -u
: "${MOCK_JQ_REAL:?MOCK_JQ_REAL is required}"

if [ "${MOCK_JQ_NO_IN:-0}" = 1 ] \
  && [ "${1:-}" = -n ] && [ "${2:-}" = 'IN(1)' ]; then
  exit 3
fi

if [ -n "${MOCK_JQ_FAIL_ACTION_AT:-}" ] \
  && [ "${1:-}" = -cn ] && [ "${2:-}" = --arg ] && [ "${3:-}" = action ]; then
  : "${MOCK_JQ_STATE:?MOCK_JQ_STATE is required for action failures}"
  db_mock_jq_count=0
  if [ -f "$MOCK_JQ_STATE" ]; then
    IFS= read -r db_mock_jq_count <"$MOCK_JQ_STATE" || exit 65
  fi
  case "$db_mock_jq_count:$MOCK_JQ_FAIL_ACTION_AT" in
    *[!0-9:]*|:*|*:) exit 65 ;;
  esac
  db_mock_jq_count=$((db_mock_jq_count + 1))
  printf '%s\n' "$db_mock_jq_count" >"$MOCK_JQ_STATE" || exit 65
  [ "$db_mock_jq_count" -ne "$MOCK_JQ_FAIL_ACTION_AT" ] || exit 70
fi

exec "$MOCK_JQ_REAL" "$@"
