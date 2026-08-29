#!/bin/sh

# Filename: mock_zonename.sh
# Description: Return a selected SmartOS zone name for installer tests.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.4.0
# Last-Updated: 2026-08-29
# Update #: 0

set -u
: "${MOCK_ZONENAME:?MOCK_ZONENAME is required}"
printf '%s\n' "$MOCK_ZONENAME"
