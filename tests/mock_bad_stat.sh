#!/bin/sh

# Filename: mock_bad_stat.sh
# Description: Fail if a Darwin mode check accidentally selects stat through PATH.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.4.1
# Last-Updated: 2026-08-29
# Update #: 0

printf '%s\n' 'PATH stat was selected unexpectedly' >&2
exit 64
