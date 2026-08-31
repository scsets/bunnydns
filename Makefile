# Filename: Makefile
# Description: Build, verify, install, and remove the Bunny DNS reconciler.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.6.0
# Last-Updated: 2026-08-30
# Update #: 10

SHELL = /bin/sh

NODE ?= $(shell if command -v node >/dev/null 2>&1; then command -v node; elif [ -x /opt/tools/bin/node ]; then printf '%s\n' /opt/tools/bin/node; elif [ -x /opt/local/bin/node ]; then printf '%s\n' /opt/local/bin/node; fi)
NPM ?= $(shell if command -v npm >/dev/null 2>&1; then command -v npm; elif [ -x /opt/tools/bin/npm ]; then printf '%s\n' /opt/tools/bin/npm; elif [ -x /opt/local/bin/npm ]; then printf '%s\n' /opt/local/bin/npm; fi)

PROGRAM = dns_bunny.sh
HELPER = dns_bunny_node.mjs
MANPAGE = dns_bunny.1
CHECKSUM = $(PROGRAM).md5
HELPER_CHECKSUM = $(HELPER).md5
RUNTIME_PACKAGE = package.json
RUNTIME_LOCK = package-lock.json
BINDIR =
MANDIR =
LIBEXECDIR =
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
	program_md5=`md5_file '$(PROGRAM)'`; helper_md5=`md5_file '$(HELPER)'`; \
	printf '%s  %s\n' "$$program_md5" '$(PROGRAM)' >'$(CHECKSUM)'; \
	printf '%s  %s\n' "$$helper_md5" '$(HELPER)' >'$(HELPER_CHECKSUM)'; \
	printf 'Recorded MD5 %s for %s in %s.\n' "$$program_md5" '$(PROGRAM)' '$(CHECKSUM)'; \
	printf 'Recorded MD5 %s for %s in %s.\n' "$$helper_md5" '$(HELPER)' '$(HELPER_CHECKSUM)'

checksum-check: require-gnu-make ## Verify the script against its recorded MD5 sidecar.
	@set -eu; \
	md5_file() { \
	  if command -v md5 >/dev/null 2>&1 && md5 -q "$$1" 2>/dev/null; then return 0; fi; \
	  if command -v md5sum >/dev/null 2>&1; then md5sum "$$1" | awk '{print $$1}'; return; fi; \
	  if command -v digest >/dev/null 2>&1; then digest -a md5 "$$1"; return; fi; \
	  if command -v openssl >/dev/null 2>&1; then openssl dgst -md5 "$$1" | awk '{print $$NF}'; return; fi; \
	  printf '%s\n' 'An MD5 tool is required: md5, md5sum, digest, or openssl.' >&2; return 1; \
	}; \
	verify_checksum() { \
	  file=$$1; sidecar=$$2; \
	  [ -f "$$sidecar" ] || { printf 'Missing checksum sidecar: %s\n' "$$sidecar" >&2; exit 1; }; \
	  file_md5=`md5_file "$$file"`; recorded=`cat "$$sidecar"`; expected="$$file_md5  $$file"; \
	  [ "$$recorded" = "$$expected" ] || { \
	    printf 'Checksum mismatch for %s; review the script, then run gmake checksum.\n' "$$file" >&2; exit 1; \
	  }; \
	  printf 'Verified MD5 %s for %s.\n' "$$file_md5" "$$file"; \
	}; \
	verify_checksum '$(PROGRAM)' '$(CHECKSUM)'; \
	verify_checksum '$(HELPER)' '$(HELPER_CHECKSUM)'

check: checksum-check ## Check syntax, style, checksum, and the example declaration.
	@sh -n $(PROGRAM)
	@[ -n '$(NODE)' ] || { printf '%s\n' 'Node.js 18 or newer is required.' >&2; exit 1; }
	@'$(NODE)' -e 'const major = Number(process.versions.node.split(".")[0]); process.exit(major >= 18 ? 0 : 1)' \
	  || { printf '%s\n' 'Node.js 18 or newer is required.' >&2; exit 1; }
	@[ -n '$(NPM)' ] || { printf '%s\n' 'npm is required to verify the locked runtime.' >&2; exit 1; }
	@'$(NODE)' --check $(HELPER)
	@'$(NODE)' $(HELPER) runtime-check >/dev/null
	@'$(NPM)' ls --all --omit=dev >/dev/null
	@'$(NODE)' -e 'const p = require("./package.json"); const l = require("./package-lock.json"); if (p.version !== "0.6.0" || l.packages[""].version !== p.version || p.dependencies["@bunny.net/openapi-client"] !== "0.3.0") process.exit(1)'
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
	os_name=`uname -s`; bindir='$(BINDIR)'; mandir='$(MANDIR)'; libexecdir='$(LIBEXECDIR)'; destdir='$(DESTDIR)'; \
	case "$$os_name" in \
	  Darwin) [ -n "$$bindir" ] || bindir="$${HOME:?HOME is not set}/bin"; \
	          [ -n "$$mandir" ] || mandir="$${HOME:?HOME is not set}/share/man/man1" ;; \
	  SunOS) command -v zonename >/dev/null 2>&1 || { printf '%s\n' 'zonename is required on SmartOS.' >&2; exit 1; }; \
	         if [ "`zonename`" = global ]; then smartos_prefix=/opt/custom; else smartos_prefix=/opt/local; fi; \
	         [ -n "$$bindir" ] || bindir=$$smartos_prefix/bin; \
	         [ -n "$$mandir" ] || mandir=$$smartos_prefix/share/man/man1 ;; \
	  *) printf 'Unsupported operating system: %s\n' "$$os_name" >&2; exit 1 ;; \
	esac; \
	[ -n "$$libexecdir" ] || libexecdir=`dirname "$$bindir"`/libexec/dns-bunny; \
	case "$$bindir" in /*) ;; *) printf '%s\n' 'BINDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$mandir" in /*) ;; *) printf '%s\n' 'MANDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$libexecdir" in /*) ;; *) printf '%s\n' 'LIBEXECDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$destdir" in ''|/*) ;; *) printf '%s\n' 'DESTDIR must be empty or absolute.' >&2; exit 1 ;; esac; \
	printf 'Executable: %s%s/%s\n' "$$destdir" "$$bindir" '$(PROGRAM)'; \
	printf 'Helper:     %s%s/%s\n' "$$destdir" "$$libexecdir" '$(HELPER)'; \
	printf 'Runtime:    %s%s/node_modules/\n' "$$destdir" "$$libexecdir"; \
	printf 'Manual:     %s%s/%s\n' "$$destdir" "$$mandir" '$(MANPAGE)'

install: check man-check ## Install the executable, official-client runtime, and manual page.
	@set -eu; \
	os_name=`uname -s`; bindir='$(BINDIR)'; mandir='$(MANDIR)'; libexecdir='$(LIBEXECDIR)'; destdir='$(DESTDIR)'; \
	case "$$os_name" in \
	  Darwin) [ -n "$$bindir" ] || bindir="$${HOME:?HOME is not set}/bin"; \
	          [ -n "$$mandir" ] || mandir="$${HOME:?HOME is not set}/share/man/man1" ;; \
	  SunOS) command -v zonename >/dev/null 2>&1 || { printf '%s\n' 'zonename is required on SmartOS.' >&2; exit 1; }; \
	         if [ "`zonename`" = global ]; then smartos_prefix=/opt/custom; else smartos_prefix=/opt/local; fi; \
	         [ -n "$$bindir" ] || bindir=$$smartos_prefix/bin; \
	         [ -n "$$mandir" ] || mandir=$$smartos_prefix/share/man/man1 ;; \
	  *) printf 'Unsupported operating system: %s\n' "$$os_name" >&2; exit 1 ;; \
	esac; \
	[ -n "$$libexecdir" ] || libexecdir=`dirname "$$bindir"`/libexec/dns-bunny; \
	case "$$bindir" in /*) ;; *) printf '%s\n' 'BINDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$mandir" in /*) ;; *) printf '%s\n' 'MANDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$libexecdir" in /*) ;; *) printf '%s\n' 'LIBEXECDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$destdir" in ''|/*) ;; *) printf '%s\n' 'DESTDIR must be empty or absolute.' >&2; exit 1 ;; esac; \
	for package_dir in node_modules/@bunny.net/openapi-client node_modules/openapi-fetch node_modules/openapi-typescript-helpers; do \
	  [ -d "$$package_dir" ] || { printf 'Missing runtime dependency: %s; run npm ci --ignore-scripts.\n' "$$package_dir" >&2; exit 1; }; \
	done; \
	mkdir -p "$$destdir$$bindir" "$$destdir$$mandir" \
	  "$$destdir$$libexecdir/node_modules/@bunny.net" "$$destdir$$libexecdir/node_modules"; \
	cp '$(PROGRAM)' "$$destdir$$bindir/$(PROGRAM)"; \
	chmod 755 "$$destdir$$bindir/$(PROGRAM)"; \
	cp '$(HELPER)' "$$destdir$$libexecdir/$(HELPER)"; \
	chmod 755 "$$destdir$$libexecdir/$(HELPER)"; \
	cp '$(RUNTIME_PACKAGE)' '$(RUNTIME_LOCK)' "$$destdir$$libexecdir/"; \
	chmod 644 "$$destdir$$libexecdir/$(RUNTIME_PACKAGE)" "$$destdir$$libexecdir/$(RUNTIME_LOCK)"; \
	rm -rf "$$destdir$$libexecdir/node_modules/@bunny.net/openapi-client" \
	  "$$destdir$$libexecdir/node_modules/openapi-fetch" \
	  "$$destdir$$libexecdir/node_modules/openapi-typescript-helpers"; \
	cp -R node_modules/@bunny.net/openapi-client "$$destdir$$libexecdir/node_modules/@bunny.net/"; \
	cp -R node_modules/openapi-fetch node_modules/openapi-typescript-helpers \
	  "$$destdir$$libexecdir/node_modules/"; \
	chmod -R u=rwX,go=rX "$$destdir$$libexecdir/node_modules"; \
	cp '$(MANPAGE)' "$$destdir$$mandir/$(MANPAGE)"; \
	chmod 644 "$$destdir$$mandir/$(MANPAGE)"; \
	printf 'Installed %s, official-client runtime in %s, and %s.\n' \
	  "$$destdir$$bindir/$(PROGRAM)" "$$destdir$$libexecdir" "$$destdir$$mandir/$(MANPAGE)"

uninstall: require-gnu-make ## Remove only files and packages installed by this project.
	@set -eu; \
	os_name=`uname -s`; bindir='$(BINDIR)'; mandir='$(MANDIR)'; libexecdir='$(LIBEXECDIR)'; destdir='$(DESTDIR)'; \
	case "$$os_name" in \
	  Darwin) [ -n "$$bindir" ] || bindir="$${HOME:?HOME is not set}/bin"; \
	          [ -n "$$mandir" ] || mandir="$${HOME:?HOME is not set}/share/man/man1" ;; \
	  SunOS) command -v zonename >/dev/null 2>&1 || { printf '%s\n' 'zonename is required on SmartOS.' >&2; exit 1; }; \
	         if [ "`zonename`" = global ]; then smartos_prefix=/opt/custom; else smartos_prefix=/opt/local; fi; \
	         [ -n "$$bindir" ] || bindir=$$smartos_prefix/bin; \
	         [ -n "$$mandir" ] || mandir=$$smartos_prefix/share/man/man1 ;; \
	  *) printf 'Unsupported operating system: %s\n' "$$os_name" >&2; exit 1 ;; \
	esac; \
	[ -n "$$libexecdir" ] || libexecdir=`dirname "$$bindir"`/libexec/dns-bunny; \
	case "$$bindir" in /*) ;; *) printf '%s\n' 'BINDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$mandir" in /*) ;; *) printf '%s\n' 'MANDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$libexecdir" in /*) ;; *) printf '%s\n' 'LIBEXECDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$destdir" in ''|/*) ;; *) printf '%s\n' 'DESTDIR must be empty or absolute.' >&2; exit 1 ;; esac; \
	rm -f "$$destdir$$bindir/$(PROGRAM)" "$$destdir$$mandir/$(MANPAGE)" \
	  "$$destdir$$libexecdir/$(HELPER)" "$$destdir$$libexecdir/$(RUNTIME_PACKAGE)" \
	  "$$destdir$$libexecdir/$(RUNTIME_LOCK)"; \
	rm -rf "$$destdir$$libexecdir/node_modules/@bunny.net/openapi-client" \
	  "$$destdir$$libexecdir/node_modules/openapi-fetch" \
	  "$$destdir$$libexecdir/node_modules/openapi-typescript-helpers"; \
	printf 'Removed installed files; installation directories were preserved.\n'

update: check man-check ## Replace a differing installation; skip identical application content.
	@set -eu; \
	os_name=`uname -s`; bindir='$(BINDIR)'; libexecdir='$(LIBEXECDIR)'; destdir='$(DESTDIR)'; \
	case "$$os_name" in \
	  Darwin) [ -n "$$bindir" ] || bindir="$${HOME:?HOME is not set}/bin" ;; \
	  SunOS) command -v zonename >/dev/null 2>&1 || { printf '%s\n' 'zonename is required on SmartOS.' >&2; exit 1; }; \
	         if [ "`zonename`" = global ]; then smartos_prefix=/opt/custom; else smartos_prefix=/opt/local; fi; \
	         [ -n "$$bindir" ] || bindir=$$smartos_prefix/bin ;; \
	  *) printf 'Unsupported operating system: %s\n' "$$os_name" >&2; exit 1 ;; \
	esac; \
	[ -n "$$libexecdir" ] || libexecdir=`dirname "$$bindir"`/libexec/dns-bunny; \
	case "$$bindir" in /*) ;; *) printf '%s\n' 'BINDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$libexecdir" in /*) ;; *) printf '%s\n' 'LIBEXECDIR must be absolute.' >&2; exit 1 ;; esac; \
	case "$$destdir" in ''|/*) ;; *) printf '%s\n' 'DESTDIR must be empty or absolute.' >&2; exit 1 ;; esac; \
	md5_file() { \
	  if command -v md5 >/dev/null 2>&1 && md5 -q "$$1" 2>/dev/null; then return 0; fi; \
	  if command -v md5sum >/dev/null 2>&1; then md5sum "$$1" | awk '{print $$1}'; return; fi; \
	  if command -v digest >/dev/null 2>&1; then digest -a md5 "$$1"; return; fi; \
	  if command -v openssl >/dev/null 2>&1; then openssl dgst -md5 "$$1" | awk '{print $$NF}'; return; fi; \
	  printf '%s\n' 'An MD5 tool is required: md5, md5sum, digest, or openssl.' >&2; return 1; \
	}; \
	installed_program="$$destdir$$bindir/$(PROGRAM)"; \
	installed_helper="$$destdir$$libexecdir/$(HELPER)"; \
	installed_lock="$$destdir$$libexecdir/$(RUNTIME_LOCK)"; \
	source_md5=`md5_file '$(PROGRAM)'`; \
	source_helper_md5=`md5_file '$(HELPER)'`; \
	source_lock_md5=`md5_file '$(RUNTIME_LOCK)'`; \
	source_version=`awk -F= '$$1 == "VERSION" {print $$2; exit}' '$(PROGRAM)'`; \
	[ -n "$$source_version" ] || source_version=unknown; \
	was_update=false; installed_version=none; \
	if [ -f "$$installed_program" ]; then \
	  installed_md5=`md5_file "$$installed_program"`; \
	  if [ -f "$$installed_helper" ]; then installed_helper_md5=`md5_file "$$installed_helper"`; else installed_helper_md5=missing; fi; \
	  if [ -f "$$installed_lock" ]; then installed_lock_md5=`md5_file "$$installed_lock"`; else installed_lock_md5=missing; fi; \
	  installed_version=`awk -F= '$$1 == "VERSION" {print $$2; exit}' "$$installed_program"`; \
	  [ -n "$$installed_version" ] || installed_version=unknown; \
	  installed_runtime_ok=false; \
	  if [ -n '$(NODE)' ] && '$(NODE)' "$$installed_helper" runtime-check >/dev/null 2>&1; then installed_runtime_ok=true; fi; \
	  if [ "$$installed_md5" = "$$source_md5" ] \
	    && [ "$$installed_helper_md5" = "$$source_helper_md5" ] \
	    && [ "$$installed_lock_md5" = "$$source_lock_md5" ] \
	    && [ "$$installed_runtime_ok" = true ]; then \
	    printf 'No update needed: %s %s is identical (script MD5 %s; helper MD5 %s; lock MD5 %s).\n' \
	      '$(PROGRAM)' "$$source_version" "$$source_md5" "$$source_helper_md5" "$$source_lock_md5"; \
	    exit 0; \
	  fi; \
	  if [ "$$installed_version" = "$$source_version" ]; then \
	    printf 'Updating %s from version %s to %s; content differs.\n' \
	      '$(PROGRAM)' "$$installed_version" "$$source_version"; \
	  else \
	    printf 'Updating %s from version %s to %s.\n' \
	      '$(PROGRAM)' "$$installed_version" "$$source_version"; \
	  fi; \
	  printf 'Content MD5: script %s -> %s; helper %s -> %s; lock %s -> %s.\n' \
	    "$$installed_md5" "$$source_md5" "$$installed_helper_md5" "$$source_helper_md5" \
	    "$$installed_lock_md5" "$$source_lock_md5"; \
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
