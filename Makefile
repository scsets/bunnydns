# Filename: Makefile
# Description: Build, verify, install, and remove the Bunny DNS reconciler.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.5.4
# Last-Updated: 2026-08-30
# Update #: 6

SHELL = /bin/sh

PROGRAM = dns_bunny.sh
MANPAGE = dns_bunny.1
CHECKSUM = $(PROGRAM).md5
BINDIR =
MANDIR =
DESTDIR =

.PHONY: help require-gnu-make checksum checksum-check check test self-check man-check show-install-paths install uninstall update

help: require-gnu-make ## Show the available targets without changing anything.
	@awk 'BEGIN {FS = ":.*## "} /^[[:alnum:]_-]+:.*## / {printf "%-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

require-gnu-make: ## Require GNU Make; use gmake on SmartOS.
	@first_line=`$(MAKE) --version 2>/dev/null | sed -n '1p'`; \
	case "$$first_line" in \
	  "GNU Make "*) : ;; \
	  *) printf '%s\n' 'GNU Make is required. On SmartOS, install and invoke gmake.' >&2; exit 1 ;; \
	esac

checksum: require-gnu-make ## Refresh the MD5 sidecar after reviewing script changes.
	@set -eu; \
	md5_file() { \
	  if command -v md5 >/dev/null 2>&1 && md5 -q "$$1" 2>/dev/null; then return 0; fi; \
	  if command -v md5sum >/dev/null 2>&1; then md5sum "$$1" | awk '{print $$1}'; return; fi; \
	  if command -v digest >/dev/null 2>&1; then digest -a md5 "$$1"; return; fi; \
	  if command -v openssl >/dev/null 2>&1; then openssl dgst -md5 "$$1" | awk '{print $$NF}'; return; fi; \
	  printf '%s\n' 'An MD5 tool is required: md5, md5sum, digest, or openssl.' >&2; return 1; \
	}; \
	program_md5=`md5_file '$(PROGRAM)'`; \
	printf '%s  %s\n' "$$program_md5" '$(PROGRAM)' >'$(CHECKSUM)'; \
	printf 'Recorded MD5 %s for %s in %s.\n' "$$program_md5" '$(PROGRAM)' '$(CHECKSUM)'

checksum-check: require-gnu-make ## Verify the script against its recorded MD5 sidecar.
	@set -eu; \
	md5_file() { \
	  if command -v md5 >/dev/null 2>&1 && md5 -q "$$1" 2>/dev/null; then return 0; fi; \
	  if command -v md5sum >/dev/null 2>&1; then md5sum "$$1" | awk '{print $$1}'; return; fi; \
	  if command -v digest >/dev/null 2>&1; then digest -a md5 "$$1"; return; fi; \
	  if command -v openssl >/dev/null 2>&1; then openssl dgst -md5 "$$1" | awk '{print $$NF}'; return; fi; \
	  printf '%s\n' 'An MD5 tool is required: md5, md5sum, digest, or openssl.' >&2; return 1; \
	}; \
	[ -f '$(CHECKSUM)' ] || { printf 'Missing checksum sidecar: %s\n' '$(CHECKSUM)' >&2; exit 1; }; \
	program_md5=`md5_file '$(PROGRAM)'`; \
	recorded=`cat '$(CHECKSUM)'`; \
	expected="$$program_md5  $(PROGRAM)"; \
	[ "$$recorded" = "$$expected" ] || { \
	  printf 'Checksum mismatch for %s; review the script, then run gmake checksum.\n' '$(PROGRAM)' >&2; \
	  exit 1; \
	}; \
	printf 'Verified MD5 %s for %s.\n' "$$program_md5" '$(PROGRAM)'

check: checksum-check ## Check syntax, style, checksum, and the example declaration.
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

update: check man-check ## Replace a differing installation; skip identical script content.
	@set -eu; \
	os_name=`uname -s`; bindir='$(BINDIR)'; destdir='$(DESTDIR)'; \
	case "$$os_name" in \
	  Darwin) [ -n "$$bindir" ] || bindir="$${HOME:?HOME is not set}/bin" ;; \
	  SunOS) command -v zonename >/dev/null 2>&1 || { printf '%s\n' 'zonename is required on SmartOS.' >&2; exit 1; }; \
	         [ "`zonename`" = global ] || { printf '%s\n' 'Updating is supported only in the SmartOS global zone.' >&2; exit 1; }; \
	         [ -n "$$bindir" ] || bindir=/opt/custom/bin ;; \
	  *) printf 'Unsupported operating system: %s\n' "$$os_name" >&2; exit 1 ;; \
	esac; \
	case "$$bindir" in /*) ;; *) printf '%s\n' 'BINDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$destdir" in ''|/*) ;; *) printf '%s\n' 'DESTDIR must be empty or absolute.' >&2; exit 1 ;; esac; \
	md5_file() { \
	  if command -v md5 >/dev/null 2>&1 && md5 -q "$$1" 2>/dev/null; then return 0; fi; \
	  if command -v md5sum >/dev/null 2>&1; then md5sum "$$1" | awk '{print $$1}'; return; fi; \
	  if command -v digest >/dev/null 2>&1; then digest -a md5 "$$1"; return; fi; \
	  if command -v openssl >/dev/null 2>&1; then openssl dgst -md5 "$$1" | awk '{print $$NF}'; return; fi; \
	  printf '%s\n' 'An MD5 tool is required: md5, md5sum, digest, or openssl.' >&2; return 1; \
	}; \
	installed_program="$$destdir$$bindir/$(PROGRAM)"; \
	source_md5=`md5_file '$(PROGRAM)'`; \
	source_version=`awk -F= '$$1 == "VERSION" {print $$2; exit}' '$(PROGRAM)'`; \
	[ -n "$$source_version" ] || source_version=unknown; \
	was_update=false; installed_version=none; \
	if [ -f "$$installed_program" ]; then \
	  installed_md5=`md5_file "$$installed_program"`; \
	  installed_version=`awk -F= '$$1 == "VERSION" {print $$2; exit}' "$$installed_program"`; \
	  [ -n "$$installed_version" ] || installed_version=unknown; \
	  if [ "$$installed_md5" = "$$source_md5" ]; then \
	    printf 'No update needed: %s %s is identical (MD5 %s).\n' '$(PROGRAM)' "$$source_version" "$$source_md5"; \
	    exit 0; \
	  fi; \
	  if [ "$$installed_version" = "$$source_version" ]; then \
	    printf 'Updating %s from version %s to %s; content differs (MD5 %s -> %s).\n' \
	      '$(PROGRAM)' "$$installed_version" "$$source_version" "$$installed_md5" "$$source_md5"; \
	  else \
	    printf 'Updating %s from version %s to %s (MD5 %s -> %s).\n' \
	      '$(PROGRAM)' "$$installed_version" "$$source_version" "$$installed_md5" "$$source_md5"; \
	  fi; \
	  was_update=true; \
	  $(MAKE) --no-print-directory uninstall; \
	else \
	  printf 'Installing %s version %s; no installed copy was found.\n' '$(PROGRAM)' "$$source_version"; \
	fi; \
	$(MAKE) --no-print-directory install; \
	if [ "$$was_update" = true ]; then \
	  printf 'Updated %s from version %s to %s.\n' '$(PROGRAM)' "$$installed_version" "$$source_version"; \
	else \
	  printf 'Installed %s version %s.\n' '$(PROGRAM)' "$$source_version"; \
	fi
