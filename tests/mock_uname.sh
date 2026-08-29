#!/bin/sh

# Filename: mock_uname.sh
# Description: Return a selected operating-system name for portability tests.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.4.0
# Last-Updated: 2026-08-29
# Update #: 0

set -u
: "${MOCK_UNAME:?MOCK_UNAME is required}"
printf '%s\n' "$MOCK_UNAME"
