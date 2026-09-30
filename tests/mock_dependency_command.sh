#!/bin/sh

# Filename: mock_dependency_command.sh
# Description: Record package-manager calls without changing the host.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30
# Version: 0.1.0
# Last-Updated: 2026-09-30
# Update #: 1

set -u

# Linked as brew, pkgin, apt-get, and id.  Each call is appended to
# MOCK_DEPENDENCY_LOG; MOCK_DEPENDENCY_FAIL="COMMAND ARG" makes one call fail.

md_command=$(basename "$0")
md_log=${MOCK_DEPENDENCY_LOG:?MOCK_DEPENDENCY_LOG is required}
printf '%s' "$md_command" >>"$md_log"
for md_argument in "$@"; do
  printf ' %s' "$md_argument" >>"$md_log"
done
printf '\n' >>"$md_log"

if [ "${MOCK_DEPENDENCY_FAIL:-}" = "$md_command ${1:-}" ]; then
  exit 1
fi
if [ "$md_command" = id ]; then
  printf '%s\n' 0  # root, so the tools run the package manager directly
fi
