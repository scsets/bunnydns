#!/bin/sh

# Filename: mock_uname.sh
# Description: Report a chosen operating-system name for the Makefile tests.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30
# Version: 0.1.0
# Last-Updated: 2026-09-30
# Update #: 1

set -u
: "${MOCK_UNAME:?MOCK_UNAME is required}"
printf '%s\n' "$MOCK_UNAME"
