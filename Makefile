# Filename: Makefile
# Description: Check, test, install, update, and remove bunnydns.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30
# Version: 0.1.0
# Last-Updated: 2026-10-01
# Update #: 2

SHELL = /bin/sh

SOURCE = bunnydns.py
MANPAGE = bunnydns.8
CHECKSUM = $(SOURCE).md5
BINDIR =
MANDIR =
DESTDIR =

# The interpreter for checks, tests, and the installed #! line.  Found once;
# override with PYTHON=/absolute/path/to/python3.
ifeq ($(origin PYTHON), undefined)
PYTHON := $(shell tools/dependencies.sh python-path 2>/dev/null)
endif

# Tests import the program from the source tree; keep __pycache__ out of it.
export PYTHONDONTWRITEBYTECODE = 1

INSTALL = PYTHON='$(PYTHON)' BINDIR='$(BINDIR)' MANDIR='$(MANDIR)' DESTDIR='$(DESTDIR)' tools/install.sh

.PHONY: help require-gnu-make require-python dependencies-status dependencies checksum \
	checksum-check check test self-check man-check show-install-paths install uninstall update

help: require-gnu-make ## Show the available targets without changing anything.
	@awk 'BEGIN {FS = ":.*## "} /^[[:alnum:]_-]+:.*## / {printf "%-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

require-gnu-make: ## Require GNU Make; use gmake on SmartOS.
	@first_line=`$(MAKE) --version 2>/dev/null | sed -n '1p'`; \
	case "$$first_line" in \
	  "GNU Make "*) : ;; \
	  *) printf '%s\n' 'GNU Make is required. On SmartOS, install and invoke gmake.' >&2; exit 1 ;; \
	esac

require-python: require-gnu-make ## Require Python 3.9 or newer at an absolute path.
	@case '$(PYTHON)' in \
	  /*) '$(PYTHON)' -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null && exit 0 ;; \
	esac; \
	printf '%s\n' 'Python 3.9 or newer is required; run gmake dependencies or set PYTHON=/absolute/path/to/python3.' >&2; \
	exit 1

dependencies-status: require-gnu-make ## Report installed tools and missing packages.
	@BUNNYDNS_MAKE='$(MAKE)' BUNNYDNS_PYTHON='$(PYTHON)' tools/dependencies.sh status

dependencies: require-gnu-make ## Install Python 3.14 and GNU Make (and CA certificates on SmartOS) if missing.
	@BUNNYDNS_MAKE='$(MAKE)' tools/dependencies.sh install

checksum: require-gnu-make ## Record the program's MD5 after reviewing changes.
	@tools/install.sh checksum '$(CHECKSUM)'

checksum-check: require-gnu-make ## Verify the program against its recorded MD5.
	@tools/install.sh checksum-check '$(CHECKSUM)'

check: checksum-check require-python ## Compile the Python, lint the shell, and validate the example.
	@cache=`mktemp -d "$${TMPDIR:-/tmp}/bunnydns-pycache.XXXXXX"` || exit 1; \
	PYTHONPYCACHEPREFIX="$$cache" '$(PYTHON)' -m py_compile $(SOURCE) tests/*.py; status=$$?; \
	rm -rf "$$cache"; exit $$status
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh tools/*.sh tests/*.sh; \
	else printf '%s\n' 'shellcheck not found; style check skipped.'; fi
	@'$(PYTHON)' $(SOURCE) validate -f records.example.json

test: require-python ## Run the offline unit and integration tests.
	@BUNNYDNS_TEST_MAKE='$(MAKE)' '$(PYTHON)' -m unittest discover -s tests

self-check: check test man-check ## Run every project verification.

man-check: require-gnu-make ## Check that the manual page formats correctly.
	@if command -v mandoc >/dev/null 2>&1; then mandoc -T lint $(MANPAGE); \
	elif command -v nroff >/dev/null 2>&1; then nroff -man $(MANPAGE) >/dev/null; \
	else printf '%s\n' 'Neither mandoc nor nroff is available; manual-page check skipped.'; fi

show-install-paths: require-gnu-make ## Show where install would put the command and manual.
	@$(INSTALL) paths

install: check man-check ## Install the command (with PYTHON in its #! line) and manual.
	@$(INSTALL) install

uninstall: require-gnu-make ## Remove the installed command and manual; keep settings and backups.
	@$(INSTALL) uninstall

update: check man-check ## Install or replace a differing installation; skip an identical one.
	@$(INSTALL) update
