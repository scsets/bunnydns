#!/bin/sh

# Filename: install.sh
# Description: Install, update, uninstall, and checksum bunnydns for the Makefile.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30
# Version: 0.1.0
# Last-Updated: 2026-09-30
# Update #: 1

# The Makefile passes PYTHON, BINDIR, MANDIR, and DESTDIR in the environment.
# The installed command is bunnydns.py with its #! line set to PYTHON, so it
# runs the same interpreter under cron or in a SmartOS zone with another PATH.
#
# Default locations:
#   SmartOS global zone  /opt/custom/sbin, /opt/custom/man/man8
#   SmartOS native zone  /opt/local/sbin, /opt/local/man/man8
#   macOS (XDG)          ~/.local/bin, ${XDG_DATA_HOME:-~/.local/share}/man/man8
#   Linux                /usr/local/sbin, /usr/local/share/man/man8

set -u
LC_ALL=C
export LC_ALL

bi_script_dir=$(unset CDPATH; cd "$(dirname "$0")" && pwd) || exit 1
cd "$bi_script_dir/.." || exit 1

bi_source=bunnydns.py
bi_program=bunnydns
bi_manpage=bunnydns.8
bi_python=${PYTHON:-}
bi_bindir=${BINDIR:-}
bi_mandir=${MANDIR:-}
bi_destdir=${DESTDIR:-}
bi_work_dir=

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

cleanup() {
  [ -z "$bi_work_dir" ] || rm -rf "$bi_work_dir"
}
trap cleanup 0
trap 'cleanup; exit 130' HUP INT TERM

md5_file() {
  if command -v md5 >/dev/null 2>&1 && md5 -q "$1" 2>/dev/null; then return; fi
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'; return; fi
  if command -v digest >/dev/null 2>&1; then digest -a md5 "$1"; return; fi
  if command -v openssl >/dev/null 2>&1; then openssl dgst -md5 "$1" | awk '{print $NF}'; return; fi
  die 'An MD5 tool is required: md5, md5sum, digest, or openssl.'
}

program_version() {
  bi_version=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$1" | sed -n '1p')
  printf '%s\n' "${bi_version:-unknown}"
}

resolve_paths() {
  bi_os_name=$(uname -s)
  case "$bi_os_name" in
    SunOS)
      command -v zonename >/dev/null 2>&1 || die 'zonename is required on SmartOS.'
      if [ "$(zonename)" = global ]; then bi_prefix=/opt/custom; else bi_prefix=/opt/local; fi
      bi_default_bindir=$bi_prefix/sbin
      bi_default_mandir=$bi_prefix/man/man8
      ;;
    Darwin)
      bi_default_bindir=${HOME:?HOME is not set}/.local/bin
      bi_default_mandir=${XDG_DATA_HOME:-$HOME/.local/share}/man/man8
      ;;
    Linux)
      bi_default_bindir=/usr/local/sbin
      bi_default_mandir=/usr/local/share/man/man8
      ;;
    *) die "Unsupported operating system: $bi_os_name" ;;
  esac
  [ -n "$bi_bindir" ] || bi_bindir=$bi_default_bindir
  [ -n "$bi_mandir" ] || bi_mandir=$bi_default_mandir
  case "$bi_bindir" in /*) ;; *) die 'BINDIR must be absolute.' ;; esac
  case "$bi_mandir" in /*) ;; *) die 'MANDIR must be absolute.' ;; esac
  case "$bi_destdir" in '' | /*) ;; *) die 'DESTDIR must be empty or absolute.' ;; esac
  bi_installed_program=$bi_destdir$bi_bindir/$bi_program
  bi_installed_manual=$bi_destdir$bi_mandir/$bi_manpage
}

# Write the command to install: the source with PYTHON in its #! line.
render_program() {
  case "$bi_python" in /*) ;; *) die 'PYTHON must be an absolute path.' ;; esac
  sed -n '1p' "$bi_source" | grep '^#!' >/dev/null || die "$bi_source must start with a #! line."
  bi_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/bunnydns-install.XXXXXX") || die 'cannot create a temporary directory'
  bi_rendered=$bi_work_dir/$bi_program
  { printf '#!%s\n' "$bi_python"; sed '1d' "$bi_source"; } >"$bi_rendered" || die 'cannot prepare the program'
}

show_paths() {
  resolve_paths
  printf 'Command: %s\n' "$bi_installed_program"
  printf 'Manual:  %s\n' "$bi_installed_manual"
  printf 'Python:  %s\n' "${bi_python:-not found; run gmake dependencies}"
}

install_files() {
  mkdir -p "$bi_destdir$bi_bindir" "$bi_destdir$bi_mandir" || exit 1
  cp "$bi_rendered" "$bi_installed_program" || exit 1
  chmod 755 "$bi_installed_program" || exit 1
  cp "$bi_manpage" "$bi_installed_manual" || exit 1
  chmod 644 "$bi_installed_manual" || exit 1
  printf 'Installed %s (Python %s) and %s.\n' "$bi_installed_program" "$bi_python" "$bi_installed_manual"
}

uninstall_files() {
  rm -f "$bi_installed_program" "$bi_installed_manual" || exit 1
  printf '%s\n' 'Removed the command and manual; directories, settings, and backups were kept.'
}

# Replace an installation only if the command or manual differs by MD5.
update_installation() {
  bi_new_version=$(program_version "$bi_source")
  if [ ! -f "$bi_installed_program" ]; then
    printf 'Installing %s %s; no installed copy was found.\n' "$bi_program" "$bi_new_version"
    install_files
    return
  fi
  bi_old_version=$(program_version "$bi_installed_program")
  bi_new_md5=$(md5_file "$bi_rendered")
  bi_old_md5=$(md5_file "$bi_installed_program")
  bi_new_manual_md5=$(md5_file "$bi_manpage")
  bi_old_manual_md5=missing
  [ ! -f "$bi_installed_manual" ] || bi_old_manual_md5=$(md5_file "$bi_installed_manual")
  if [ "$bi_old_md5" = "$bi_new_md5" ] && [ "$bi_old_manual_md5" = "$bi_new_manual_md5" ]; then
    printf 'No update needed: %s %s is identical (command MD5 %s; manual MD5 %s).\n' \
      "$bi_program" "$bi_new_version" "$bi_new_md5" "$bi_new_manual_md5"
    return
  fi
  printf 'Updating %s %s to %s.\n' "$bi_program" "$bi_old_version" "$bi_new_version"
  printf 'Content MD5: command %s -> %s; manual %s -> %s.\n' \
    "$bi_old_md5" "$bi_new_md5" "$bi_old_manual_md5" "$bi_new_manual_md5"
  install_files
}

write_checksum() {
  bi_md5=$(md5_file "$bi_source")
  printf '%s  %s\n' "$bi_md5" "$bi_source" >"$1" || exit 1
  printf 'Recorded MD5 %s for %s in %s.\n' "$bi_md5" "$bi_source" "$1"
}

verify_checksum() {
  [ -f "$1" ] || die "Missing checksum sidecar: $1"
  bi_md5=$(md5_file "$bi_source")
  [ "$(cat "$1")" = "$bi_md5  $bi_source" ] ||
    die "Checksum mismatch for $bi_source; review the program, then run gmake checksum."
  printf 'Verified MD5 %s for %s.\n' "$bi_md5" "$bi_source"
}

case "${1:-}" in
  paths) show_paths ;;
  install) resolve_paths && render_program && install_files ;;
  update) resolve_paths && render_program && update_installation ;;
  uninstall) resolve_paths && uninstall_files ;;
  checksum) write_checksum "${2:?checksum needs a sidecar path}" ;;
  checksum-check) verify_checksum "${2:?checksum-check needs a sidecar path}" ;;
  *) die 'Usage: install.sh paths|install|update|uninstall|checksum FILE|checksum-check FILE' ;;
esac
