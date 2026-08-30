#!/bin/sh

# Filename: test_makefile.sh
# Description: Offline platform and staging tests for the GNU Make installer.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.5.2
# Last-Updated: 2026-08-30
# Update #: 4

set -u
LC_ALL=C
export LC_ALL

db_script_dir=$(unset CDPATH; cd "$(dirname "$0")" && pwd) || exit 1
db_project_dir=$(unset CDPATH; cd "$db_script_dir/.." && pwd) || exit 1
db_test_root=$(mktemp -d "${TMPDIR:-/tmp}/dns_bunny_make_tests.XXXXXX") || exit 1
db_mock_bin=$db_test_root/mock-bin
db_stage_dir=$db_test_root/stage
db_failures=0
db_checks=0
db_command_output=
db_command_status=0

cleanup() {
  case "$db_test_root" in
    "${TMPDIR:-/tmp}"/dns_bunny_make_tests.*) rm -rf "$db_test_root" ;;
    *) printf 'Refusing to remove unexpected test path: %s\n' "$db_test_root" >&2 ;;
  esac
}
trap 'cleanup' 0 HUP INT TERM

record_failure() {
  db_failures=$((db_failures + 1))
  printf 'not ok - %s\n' "$1" >&2
}

record_success() {
  printf 'ok - %s\n' "$1"
}

run_command() {
  db_command_output=$("$@" 2>&1)
  db_command_status=$?
}

expect_status() {
  db_expected_status=$1
  db_label=$2
  shift 2
  db_checks=$((db_checks + 1))
  run_command "$@"
  if [ "$db_command_status" -eq "$db_expected_status" ]; then
    record_success "$db_label"
  else
    record_failure "$db_label (status $db_command_status, expected $db_expected_status)"
    printf '%s\n' "$db_command_output" >&2
  fi
}

expect_output() {
  db_needle=$1
  db_label=$2
  db_checks=$((db_checks + 1))
  case "$db_command_output" in
    *"$db_needle"*) record_success "$db_label" ;;
    *)
      record_failure "$db_label (missing: $db_needle)"
      printf '%s\n' "$db_command_output" >&2
      ;;
  esac
}

file_mode() {
  case $(uname -s) in
    Darwin) /usr/bin/stat -f '%Lp' "$1" ;;
    Linux|SunOS) stat -c '%a' "$1" ;;
    *) return 1 ;;
  esac
}

mkdir -p "$db_mock_bin" || exit 1
ln -s "$db_script_dir/mock_uname.sh" "$db_mock_bin/uname" || exit 1
ln -s "$db_script_dir/mock_zonename.sh" "$db_mock_bin/zonename" || exit 1

expect_status 0 'Darwin defaults resolve to user-local install paths' \
  gmake -C "$db_project_dir" show-install-paths
expect_output '/bin/dns_bunny.sh' 'Darwin executable destination is reported'
expect_output '/share/man/man1/dns_bunny.1' 'Darwin manual destination is reported'

expect_status 0 'SmartOS global-zone defaults are accepted' env \
  MOCK_UNAME=SunOS MOCK_ZONENAME=global PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" show-install-paths
expect_output '/opt/custom/bin/dns_bunny.sh' 'SmartOS executable default is correct'
expect_output '/opt/custom/share/man/man1/dns_bunny.1' 'SmartOS manual default is correct'

expect_status 2 'SmartOS non-global zones are refused' env \
  MOCK_UNAME=SunOS MOCK_ZONENAME=example-zone PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" show-install-paths
expect_output 'supported only in the SmartOS global zone' 'non-global refusal is explicit'

expect_status 2 'unsupported operating systems are refused' env \
  MOCK_UNAME=Plan9 MOCK_ZONENAME=global PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" show-install-paths
expect_output 'Unsupported operating system: Plan9' 'unsupported-OS refusal names the platform'

expect_status 2 'relative executable destinations are refused' \
  gmake -C "$db_project_dir" show-install-paths BINDIR=relative/path
expect_output 'BINDIR must be absolute' 'relative destination error is explicit'

expect_status 2 'a non-GNU make implementation is refused' \
  gmake -C "$db_project_dir" require-gnu-make MAKE="$db_script_dir/mock_non_gnu_make.sh"
expect_output 'GNU Make is required' 'non-GNU make refusal explains the requirement'

expect_status 0 'staged install succeeds with absolute overrides' \
  gmake -C "$db_project_dir" install DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunny-dns/bin MANDIR=/opt/bunny-dns/share/man/man1

db_installed_program=$db_stage_dir/opt/bunny-dns/bin/dns_bunny.sh
db_installed_manpage=$db_stage_dir/opt/bunny-dns/share/man/man1/dns_bunny.1
db_checks=$((db_checks + 1))
if [ -x "$db_installed_program" ] && [ -f "$db_installed_manpage" ] \
  && [ "$(file_mode "$db_installed_program")" = 755 ] \
  && [ "$(file_mode "$db_installed_manpage")" = 644 ]; then
  record_success 'staged files have the documented modes'
else
  record_failure 'staged files or their modes are incorrect'
fi

expect_status 0 'the staged executable runs independently' "$db_installed_program" version
expect_output 'dns_bunny.sh 0.5.2' 'the staged executable reports the release version'

expect_status 0 'staged uninstall succeeds with matching overrides' \
  gmake -C "$db_project_dir" uninstall DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunny-dns/bin MANDIR=/opt/bunny-dns/share/man/man1

db_checks=$((db_checks + 1))
if [ ! -e "$db_installed_program" ] && [ ! -e "$db_installed_manpage" ] \
  && [ -d "$(dirname "$db_installed_program")" ] \
  && [ -d "$(dirname "$db_installed_manpage")" ]; then
  record_success 'uninstall removes only files and preserves directories'
else
  record_failure 'uninstall did not preserve the documented boundary'
fi

if [ "$db_failures" -ne 0 ]; then
  printf '%s checks, %s failures\n' "$db_checks" "$db_failures" >&2
  exit 1
fi

printf '%s checks passed\n' "$db_checks"
