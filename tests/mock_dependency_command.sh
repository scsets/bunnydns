#!/bin/sh

# Filename: mock_dependency_command.sh
# Description: Record dependency-manager calls without changing the host.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-31
# Version: 0.7.0
# Last-Updated: 2026-08-31
# Update #: 1

set -u

md_command=$(basename "$0")
md_log=${MOCK_DEPENDENCY_LOG:?MOCK_DEPENDENCY_LOG is required}
printf '%s' "$md_command" >>"$md_log"
for md_argument in "$@"; do
  printf ' %s' "$md_argument" >>"$md_log"
done
printf '\n' >>"$md_log"

case "$md_command" in
  id)
    printf '%s\n' "${MOCK_ID_UID:-0}"
    ;;
  npm)
    case "${1:-}" in
      --version)
        printf '%s\n' '11.5.2'
        ;;
      outdated)
        printf '%s\n' 'Package  Current  Wanted  Latest'
        printf '%s\n' '@bunny.net/openapi-client  0.3.0  0.3.0  0.4.0'
        exit 1
        ;;
      audit)
        printf '%s\n' 'mock audit finding'
        exit 1
        ;;
      *)
        :
        ;;
    esac
    ;;
  *)
    :
    ;;
esac
