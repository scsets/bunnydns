# Filename: Makefile
# Description: Build, verify, install, and remove the Bunny DNS reconciler.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.5.3
# Last-Updated: 2026-08-30
# Update #: 5

SHELL = /bin/sh

PROGRAM = dns_bunny.sh
MANPAGE = dns_bunny.1
BINDIR =
MANDIR =
DESTDIR =

.PHONY: help require-gnu-make check test self-check man-check show-install-paths install uninstall

help: require-gnu-make ## Show the available targets without changing anything.
	@awk 'BEGIN {FS = ":.*## "} /^[[:alnum:]_-]+:.*## / {printf "%-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

require-gnu-make: ## Require GNU Make; use gmake on SmartOS.
	@first_line=`$(MAKE) --version 2>/dev/null | sed -n '1p'`; \
	case "$$first_line" in \
	  "GNU Make "*) : ;; \
	  *) printf '%s\n' 'GNU Make is required. On SmartOS, install and invoke gmake.' >&2; exit 1 ;; \
	esac

check: require-gnu-make ## Check syntax, style, and the example declaration.
	@sh -n $(PROGRAM)
	@if command -v shellcheck >/dev/null 2>&1; then shellcheck -s sh $(PROGRAM) tests/*.sh; \
	else printf '%s\n' 'shellcheck not found; style check skipped.'; fi
	@./$(PROGRAM) validate records.example.json

test: require-gnu-make ## Run the offline behavior tests.
	@./tests/test_dns_bunny.sh
	@./tests/test_makefile.sh

self-check: check test man-check ## Run every project verification.

man-check: require-gnu-make ## Check that the manual page formats correctly.
	@if command -v mandoc >/dev/null 2>&1; then \
	  mandoc -T lint $(MANPAGE); \
	elif command -v nroff >/dev/null 2>&1; then \
	  nroff -man $(MANPAGE) >/dev/null; \
	else \
	  printf '%s\n' 'Neither mandoc nor nroff is available; manual-page check skipped.'; \
	fi

show-install-paths: require-gnu-make ## Show resolved executable and manual destinations.
	@set -eu; \
	os_name=`uname -s`; bindir='$(BINDIR)'; mandir='$(MANDIR)'; destdir='$(DESTDIR)'; \
	case "$$os_name" in \
	  Darwin) [ -n "$$bindir" ] || bindir="$${HOME:?HOME is not set}/bin"; \
	          [ -n "$$mandir" ] || mandir="$${HOME:?HOME is not set}/share/man/man1" ;; \
	  SunOS) command -v zonename >/dev/null 2>&1 || { printf '%s\n' 'zonename is required on SmartOS.' >&2; exit 1; }; \
	         [ "`zonename`" = global ] || { printf '%s\n' 'Installation is supported only in the SmartOS global zone.' >&2; exit 1; }; \
	         [ -n "$$bindir" ] || bindir=/opt/custom/bin; \
	         [ -n "$$mandir" ] || mandir=/opt/custom/share/man/man1 ;; \
	  *) printf 'Unsupported operating system: %s\n' "$$os_name" >&2; exit 1 ;; \
	esac; \
	case "$$bindir" in /*) ;; *) printf '%s\n' 'BINDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$mandir" in /*) ;; *) printf '%s\n' 'MANDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$destdir" in ''|/*) ;; *) printf '%s\n' 'DESTDIR must be empty or absolute.' >&2; exit 1 ;; esac; \
	printf 'Executable: %s%s/%s\n' "$$destdir" "$$bindir" '$(PROGRAM)'; \
	printf 'Manual:     %s%s/%s\n' "$$destdir" "$$mandir" '$(MANPAGE)'

install: check man-check ## Install the executable and manual page.
	@set -eu; \
	os_name=`uname -s`; bindir='$(BINDIR)'; mandir='$(MANDIR)'; destdir='$(DESTDIR)'; \
	case "$$os_name" in \
	  Darwin) [ -n "$$bindir" ] || bindir="$${HOME:?HOME is not set}/bin"; \
	          [ -n "$$mandir" ] || mandir="$${HOME:?HOME is not set}/share/man/man1" ;; \
	  SunOS) command -v zonename >/dev/null 2>&1 || { printf '%s\n' 'zonename is required on SmartOS.' >&2; exit 1; }; \
	         [ "`zonename`" = global ] || { printf '%s\n' 'Installation is supported only in the SmartOS global zone.' >&2; exit 1; }; \
	         [ -n "$$bindir" ] || bindir=/opt/custom/bin; \
	         [ -n "$$mandir" ] || mandir=/opt/custom/share/man/man1 ;; \
	  *) printf 'Unsupported operating system: %s\n' "$$os_name" >&2; exit 1 ;; \
	esac; \
	case "$$bindir" in /*) ;; *) printf '%s\n' 'BINDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$mandir" in /*) ;; *) printf '%s\n' 'MANDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$destdir" in ''|/*) ;; *) printf '%s\n' 'DESTDIR must be empty or absolute.' >&2; exit 1 ;; esac; \
	mkdir -p "$$destdir$$bindir" "$$destdir$$mandir"; \
	cp '$(PROGRAM)' "$$destdir$$bindir/$(PROGRAM)"; \
	chmod 755 "$$destdir$$bindir/$(PROGRAM)"; \
	cp '$(MANPAGE)' "$$destdir$$mandir/$(MANPAGE)"; \
	chmod 644 "$$destdir$$mandir/$(MANPAGE)"; \
	printf 'Installed %s and %s.\n' "$$destdir$$bindir/$(PROGRAM)" "$$destdir$$mandir/$(MANPAGE)"

uninstall: require-gnu-make ## Remove only the installed executable and manual page.
	@set -eu; \
	os_name=`uname -s`; bindir='$(BINDIR)'; mandir='$(MANDIR)'; destdir='$(DESTDIR)'; \
	case "$$os_name" in \
	  Darwin) [ -n "$$bindir" ] || bindir="$${HOME:?HOME is not set}/bin"; \
	          [ -n "$$mandir" ] || mandir="$${HOME:?HOME is not set}/share/man/man1" ;; \
	  SunOS) command -v zonename >/dev/null 2>&1 || { printf '%s\n' 'zonename is required on SmartOS.' >&2; exit 1; }; \
	         [ "`zonename`" = global ] || { printf '%s\n' 'Uninstallation is supported only in the SmartOS global zone.' >&2; exit 1; }; \
	         [ -n "$$bindir" ] || bindir=/opt/custom/bin; \
	         [ -n "$$mandir" ] || mandir=/opt/custom/share/man/man1 ;; \
	  *) printf 'Unsupported operating system: %s\n' "$$os_name" >&2; exit 1 ;; \
	esac; \
	case "$$bindir" in /*) ;; *) printf '%s\n' 'BINDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$mandir" in /*) ;; *) printf '%s\n' 'MANDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$destdir" in ''|/*) ;; *) printf '%s\n' 'DESTDIR must be empty or absolute.' >&2; exit 1 ;; esac; \
	rm -f "$$destdir$$bindir/$(PROGRAM)" "$$destdir$$mandir/$(MANPAGE)"; \
	printf 'Removed installed files; installation directories were preserved.\n'
