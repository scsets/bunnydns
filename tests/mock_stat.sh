#!/bin/sh

# Filename: mock_stat.sh
# Description: Return a selected octal file mode for portability tests.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.4.0
# Last-Updated: 2026-08-29
# Update #: 0

set -u
: "${MOCK_FILE_MODE:?MOCK_FILE_MODE is required}"
printf '%s\n' "$MOCK_FILE_MODE"
