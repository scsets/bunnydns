#!/bin/sh

# Filename: test_makefile.sh
# Description: Offline dependency, platform, and staging tests for GNU Make.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-29
# Version: 0.7.0
# Last-Updated: 2026-08-31
# Update #: 12

set -u
LC_ALL=C
export LC_ALL

db_script_dir=$(unset CDPATH; cd "$(dirname "$0")" && pwd) || exit 1
db_project_dir=$(unset CDPATH; cd "$db_script_dir/.." && pwd) || exit 1
db_test_root=$(mktemp -d "${TMPDIR:-/tmp}/bunnydns_make_tests.XXXXXX") || exit 1
db_mock_bin=$db_test_root/mock-bin
db_stage_dir=$db_test_root/stage
db_failures=0
db_checks=0
db_command_output=
db_command_status=0

cleanup() {
  case "$db_test_root" in
    "${TMPDIR:-/tmp}"/bunnydns_make_tests.*) rm -rf "$db_test_root" ;;
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

expect_log() {
  db_needle=$1
  db_label=$2
  db_log=$3
  db_checks=$((db_checks + 1))
  if grep -F "$db_needle" "$db_log" >/dev/null 2>&1; then
    record_success "$db_label"
  else
    record_failure "$db_label (missing from command log: $db_needle)"
    if [ -f "$db_log" ]; then
      sed -n '1,120p' "$db_log" >&2
    else
      printf 'Missing command log: %s\n' "$db_log" >&2
    fi
  fi
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
for db_mock_command in brew pkgin apt-get npm id; do
  ln -s "$db_script_dir/mock_dependency_command.sh" \
    "$db_mock_bin/$db_mock_command" || exit 1
done
db_dependency_log=$db_test_root/dependencies.log
db_node=$(command -v node) || exit 1
: >"$db_dependency_log" || exit 1

expect_status 0 'Darwin defaults resolve to user-local install paths' \
  gmake -C "$db_project_dir" show-install-paths
expect_output '/bin/bunnydns' 'Darwin executable destination is reported'
expect_output '/share/man/man1/bunnydns.1' 'Darwin manual destination is reported'

expect_status 0 'SmartOS global-zone defaults are accepted' env \
  MOCK_UNAME=SunOS MOCK_ZONENAME=global PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" show-install-paths
expect_output '/opt/custom/bin/bunnydns' 'SmartOS executable default is correct'
expect_output '/opt/custom/libexec/bunnydns/bunnydns-node.mjs' 'SmartOS global-zone helper default is correct'
expect_output '/opt/custom/share/man/man1/bunnydns.1' 'SmartOS manual default is correct'

expect_status 0 'SmartOS native-zone defaults are accepted' env \
  MOCK_UNAME=SunOS MOCK_ZONENAME=example-zone PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" show-install-paths
expect_output '/opt/local/bin/bunnydns' 'SmartOS native-zone executable default is correct'
expect_output '/opt/local/libexec/bunnydns/bunnydns-node.mjs' 'SmartOS native-zone helper default is correct'
expect_output '/opt/local/share/man/man1/bunnydns.1' 'SmartOS native-zone manual default is correct'

expect_status 0 'Linux defaults resolve below /usr/local' env \
  MOCK_UNAME=Linux PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" show-install-paths
expect_output '/usr/local/bin/bunnydns' 'Linux executable default is correct'
expect_output '/usr/local/libexec/bunnydns/bunnydns-node.mjs' 'Linux helper default is correct'
expect_output '/usr/local/share/man/man1/bunnydns.1' 'Linux manual default is correct'

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

: >"$db_dependency_log" || exit 1
expect_status 0 'dependency status is informational when updates and advisories exist' env \
  MOCK_UNAME=Darwin MOCK_DEPENDENCY_LOG="$db_dependency_log" \
  PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" dependencies-status \
  NODE="$db_node" NPM="$db_mock_bin/npm"
expect_output 'Toolchain status for Darwin' 'dependency status names the platform'
expect_output 'Current  Wanted  Latest' 'dependency status reports npm update versions'
expect_output 'npm audit returned status 1' 'dependency status highlights audit findings'
expect_log 'brew outdated --verbose --formula jq node make' \
  'dependency status uses Homebrew without auto-updating it' "$db_dependency_log"

expect_status 0 'SmartOS global status reports the global-zone pkgin path' env \
  MOCK_UNAME=SunOS MOCK_ZONENAME=global \
  MOCK_DEPENDENCY_LOG="$db_dependency_log" PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" dependencies-status \
  NODE="$db_node" NPM="$db_mock_bin/npm"
expect_output '/opt/tools/bin/pkgin' 'SmartOS global dependency path is explicit'

expect_status 0 'SmartOS native status reports the native-zone pkgin path' env \
  MOCK_UNAME=SunOS MOCK_ZONENAME=example-zone \
  MOCK_DEPENDENCY_LOG="$db_dependency_log" PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" dependencies-status \
  NODE="$db_node" NPM="$db_mock_bin/npm"
expect_output '/opt/local/bin/pkgin' 'SmartOS native dependency path is explicit'

: >"$db_dependency_log" || exit 1
expect_status 0 'macOS dependency installation uses Homebrew and the npm lockfile' env \
  MOCK_UNAME=Darwin MOCK_DEPENDENCY_LOG="$db_dependency_log" \
  PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" dependencies \
  NODE="$db_node" NPM="$db_mock_bin/npm"
expect_log 'brew update-if-needed' 'macOS refreshes Homebrew metadata' "$db_dependency_log"
expect_log 'brew install jq node make' 'macOS installs required formulae' "$db_dependency_log"
expect_log 'npm ci --ignore-scripts' 'macOS reproduces the reviewed npm lockfile' "$db_dependency_log"

: >"$db_dependency_log" || exit 1
expect_status 0 'SmartOS dependency installation uses pkgin and the npm lockfile' env \
  MOCK_UNAME=SunOS MOCK_ZONENAME=global \
  MOCK_DEPENDENCY_LOG="$db_dependency_log" \
  BUNNYDNS_PKGIN="$db_mock_bin/pkgin" PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" dependencies \
  NODE="$db_node" NPM="$db_mock_bin/npm"
expect_log 'pkgin -y update' 'SmartOS refreshes the pkgin catalog' "$db_dependency_log"
expect_log 'pkgin -y install jq nodejs gmake' \
  'SmartOS installs required pkgsrc packages' "$db_dependency_log"
expect_log 'npm ci --ignore-scripts' 'SmartOS reproduces the reviewed npm lockfile' "$db_dependency_log"

: >"$db_dependency_log" || exit 1
expect_status 0 'Linux dependency installation uses apt-get and the npm lockfile' env \
  MOCK_UNAME=Linux MOCK_DEPENDENCY_LOG="$db_dependency_log" \
  PATH="$db_mock_bin:$PATH" \
  gmake -C "$db_project_dir" dependencies \
  NODE="$db_node" NPM="$db_mock_bin/npm"
expect_log 'apt-get update' 'Linux refreshes apt package metadata' "$db_dependency_log"
expect_log 'apt-get install -y jq nodejs npm make coreutils' \
  'Linux installs required packages' "$db_dependency_log"
expect_log 'npm ci --ignore-scripts' 'Linux reproduces the reviewed npm lockfile' "$db_dependency_log"

expect_status 0 'staged install succeeds with absolute overrides' \
  gmake -C "$db_project_dir" install DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunnydns/bin MANDIR=/opt/bunnydns/share/man/man1

db_installed_program=$db_stage_dir/opt/bunnydns/bin/bunnydns
db_installed_manpage=$db_stage_dir/opt/bunnydns/share/man/man1/bunnydns.1
db_installed_libexec=$db_stage_dir/opt/bunnydns/libexec/bunnydns
db_installed_helper=$db_installed_libexec/bunnydns-node.mjs
db_checks=$((db_checks + 1))
if [ -x "$db_installed_program" ] && [ -x "$db_installed_helper" ] \
  && [ -f "$db_installed_libexec/package-lock.json" ] \
  && [ -f "$db_installed_libexec/node_modules/@bunny.net/openapi-client/package.json" ] \
  && [ -f "$db_installed_manpage" ] \
  && [ "$(file_mode "$db_installed_program")" = 755 ] \
  && [ "$(file_mode "$db_installed_helper")" = 755 ] \
  && [ "$(file_mode "$db_installed_manpage")" = 644 ]; then
  record_success 'staged program, helper, runtime, and manual have the documented layout'
else
  record_failure 'staged application layout or modes are incorrect'
fi

expect_status 0 'the staged executable runs independently' "$db_installed_program" version
expect_output 'bunnydns 0.7.0' 'the staged executable reports the release version'

expect_status 0 'the staged official-client helper resolves its installed dependencies' \
  node "$db_installed_helper" runtime-check
expect_output 'Official Bunny client runtime is available.' \
  'the staged helper confirms the official-client runtime'

expect_status 0 'the recorded script checksum is valid' \
  gmake -C "$db_project_dir" checksum-check
expect_output 'Verified MD5' 'checksum validation reports the script digest'

db_generated_checksum=$db_test_root/generated.md5
db_generated_helper_checksum=$db_test_root/generated-helper.md5
expect_status 0 'a checksum sidecar can be generated in a staging path' \
  gmake -C "$db_project_dir" checksum CHECKSUM="$db_generated_checksum" \
  HELPER_CHECKSUM="$db_generated_helper_checksum"
expect_output 'Recorded MD5' 'checksum generation reports its destination'
db_checks=$((db_checks + 1))
if cmp -s "$db_generated_checksum" "$db_project_dir/bunnydns.md5"; then
  record_success 'generated checksum uses the committed sidecar format'
else
  record_failure 'generated checksum differs from the committed sidecar'
fi
db_checks=$((db_checks + 1))
if cmp -s "$db_generated_helper_checksum" "$db_project_dir/bunnydns-node.mjs.md5"; then
  record_success 'generated helper checksum uses the committed sidecar format'
else
  record_failure 'generated helper checksum differs from the committed sidecar'
fi

db_bad_checksum=$db_test_root/bad.md5
printf '%s  %s\n' 00000000000000000000000000000000 bunnydns >"$db_bad_checksum" || exit 1
expect_status 2 'checksum validation rejects altered metadata' \
  gmake -C "$db_project_dir" checksum-check CHECKSUM="$db_bad_checksum" \
  HELPER_CHECKSUM="$db_project_dir/bunnydns-node.mjs.md5"
expect_output 'Checksum mismatch for bunnydns' \
  'checksum mismatch requires review before regeneration'

chmod 700 "$db_installed_program" || exit 1
expect_status 0 'update skips an identical installed script' \
  gmake -C "$db_project_dir" update DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunnydns/bin MANDIR=/opt/bunnydns/share/man/man1
expect_output 'No update needed: bunnydns 0.7.0 is identical' \
  'no-op update reports the current version'
db_checks=$((db_checks + 1))
if [ "$(file_mode "$db_installed_program")" = 700 ]; then
  record_success 'no-op update leaves the installed file untouched'
else
  record_failure 'no-op update replaced the installed file'
fi

rm -rf "$db_installed_libexec/node_modules/openapi-fetch" || exit 1
expect_status 0 'update repairs an incomplete installed runtime' \
  gmake -C "$db_project_dir" update DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunnydns/bin MANDIR=/opt/bunnydns/share/man/man1
expect_output 'from version 0.7.0 to 0.7.0; content differs' \
  'runtime damage triggers a same-version update'
db_checks=$((db_checks + 1))
if [ -f "$db_installed_libexec/node_modules/openapi-fetch/package.json" ]; then
  record_success 'runtime update restores the missing dependency'
else
  record_failure 'runtime update did not restore the missing dependency'
fi

db_modified_program=$db_test_root/bunnydns.modified
sed 's/^VERSION=0\.7\.0$/VERSION=0.6.0/' \
  "$db_installed_program" >"$db_modified_program" || exit 1
chmod 755 "$db_modified_program" || exit 1
mv "$db_modified_program" "$db_installed_program" || exit 1
expect_status 0 'update replaces different installed script content' \
  gmake -C "$db_project_dir" update DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunnydns/bin MANDIR=/opt/bunnydns/share/man/man1
expect_output 'Updating bunnydns from version 0.6.0 to 0.7.0' \
  'update reports the installed and incoming versions'
expect_output 'MD5' 'content update reports both digests'
expect_output 'Updated bunnydns from version 0.6.0 to 0.7.0' \
  'update confirms the completed version transition'
expect_status 0 'the updated executable has the incoming version' \
  "$db_installed_program" version
expect_output 'bunnydns 0.7.0' 'content update installs the source release'

printf '\n# simulated local content drift\n' >>"$db_installed_program" || exit 1
expect_status 0 'MD5 detects drift even when version strings match' \
  gmake -C "$db_project_dir" update DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunnydns/bin MANDIR=/opt/bunnydns/share/man/man1
expect_output 'from version 0.7.0 to 0.7.0; content differs' \
  'same-version content drift is still updated'
db_checks=$((db_checks + 1))
if cmp -s "$db_installed_program" "$db_project_dir/bunnydns"; then
  record_success 'content-drift update restores the reviewed source script'
else
  record_failure 'content-drift update did not restore the source script'
fi

expect_status 0 'staged uninstall succeeds with matching overrides' \
  gmake -C "$db_project_dir" uninstall DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunnydns/bin MANDIR=/opt/bunnydns/share/man/man1

db_checks=$((db_checks + 1))
if [ ! -e "$db_installed_program" ] && [ ! -e "$db_installed_helper" ] \
  && [ ! -e "$db_installed_libexec/node_modules/@bunny.net/openapi-client" ] \
  && [ ! -e "$db_installed_manpage" ] \
  && [ -d "$(dirname "$db_installed_program")" ] \
  && [ -d "$db_installed_libexec" ] \
  && [ -d "$(dirname "$db_installed_manpage")" ]; then
  record_success 'uninstall removes only files and preserves directories'
else
  record_failure 'uninstall did not preserve the documented boundary'
fi

expect_status 0 'update installs when no installed script exists' \
  gmake -C "$db_project_dir" update DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunnydns/bin MANDIR=/opt/bunnydns/share/man/man1
expect_output 'Installing bunnydns version 0.7.0; no installed copy was found' \
  'missing installation is reported explicitly'
expect_output 'Installed bunnydns version 0.7.0' \
  'first installation confirms the installed version'

expect_status 0 'final staged uninstall succeeds' \
  gmake -C "$db_project_dir" uninstall DESTDIR="$db_stage_dir" \
  BINDIR=/opt/bunnydns/bin MANDIR=/opt/bunnydns/share/man/man1

if [ "$db_failures" -ne 0 ]; then
  printf '%s checks, %s failures\n' "$db_checks" "$db_failures" >&2
  exit 1
fi

printf '%s checks passed\n' "$db_checks"
