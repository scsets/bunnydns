#!/bin/sh

# Filename: dependencies.sh
# Description: Find, report, and install the tools bunnydns needs.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30
# Version: 0.1.0
# Last-Updated: 2026-10-01
# Update #: 2

# bunnydns needs Python 3.9 or newer (3.14 by default) to run and GNU Make to
# check and install it.  SmartOS also needs pkgsrc's CA bundle for HTTPS.
# Only missing packages are installed; installed ones are never upgraded,
# because an upgrade can carry unrelated packages along with it.  Upgrades
# are the host's own routine.

set -u
LC_ALL=C
export LC_ALL

bd_script_dir=$(unset CDPATH; cd "$(dirname "$0")" && pwd) || exit 1
cd "$bd_script_dir/.." || exit 1

bd_make=${BUNNYDNS_MAKE:-gmake}
bd_python=${BUNNYDNS_PYTHON:-}
bd_pkgsrc_prefix=${BUNNYDNS_PKGSRC_PREFIX:-}
bd_pkgsrc_packages='python314 gmake mozilla-rootcerts-openssl'
bd_brew_packages='python@3.14 make'
bd_linux_packages='python3 make'

usage() {
  printf '%s\n' 'Usage: dependencies.sh status|install|python-path' >&2
  exit 1
}

command_exists() {
  [ -n "$1" ] && command -v "$1" >/dev/null 2>&1
}

python_is_supported() {
  [ -x "$1" ] && "$1" -c 'import sys; sys.exit(sys.version_info < (3, 9))' >/dev/null 2>&1
}

# Print the Python to use: BUNNYDNS_PYTHON if set, else Python 3.14, else any
# python3 that is 3.9 or newer.  pkgsrc puts them under /opt/tools (global
# zone) or /opt/local (native zone), which may not be on PATH.
resolve_python() {
  if [ -n "$bd_python" ]; then
    printf '%s\n' "$bd_python"
    return
  fi
  for bd_name in python3.14 python3; do
    for bd_candidate in "$(command -v "$bd_name" 2>/dev/null)" "/opt/tools/bin/$bd_name" "/opt/local/bin/$bd_name"; do
      python_is_supported "$bd_candidate" && { printf '%s\n' "$bd_candidate"; return; }
    done
  done
  return 1
}

# pkgsrc lives in /opt/tools in the global zone and /opt/local in native zones.
pkgsrc_prefix() {
  if [ -n "$bd_pkgsrc_prefix" ]; then
    printf '%s\n' "$bd_pkgsrc_prefix"
  elif [ "$(zonename)" = global ]; then
    printf '%s\n' /opt/tools
  else
    printf '%s\n' /opt/local
  fi
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    printf '%s\n' 'Root privileges are required; install sudo or run this target as root.' >&2
    return 1
  fi
}

linux_package_manager() {
  for bd_candidate in apt-get dnf yum apk zypper; do
    command_exists "$bd_candidate" && { printf '%s\n' "$bd_candidate"; return; }
  done
  printf '%s\n' 'No supported Linux package manager found (apt-get, dnf, yum, apk, or zypper).' >&2
  return 1
}

# Require the package manager; on Linux, also choose it as bd_manager.
check_package_manager() {
  case "$1" in
    Darwin) command_exists brew || { printf '%s\n' 'Homebrew is required on macOS.' >&2; return 1; } ;;
    SunOS) [ -x "$(pkgsrc_prefix)/bin/pkgin" ] || { printf 'pkgsrc is required at %s.\n' "$(pkgsrc_prefix)" >&2; return 1; } ;;
    Linux) bd_manager=$(linux_package_manager) ;;
    *) printf 'Unsupported operating system: %s\n' "$1" >&2; return 1 ;;
  esac
}

required_packages() {
  case "$1" in
    Darwin) printf '%s\n' "$bd_brew_packages" ;;
    SunOS) printf '%s\n' "$bd_pkgsrc_packages" ;;
    Linux) printf '%s\n' "$bd_linux_packages" ;;
  esac
}

# Succeed when package $2 is installed.  Only the package database is read.
# shellcheck disable=SC2016
package_installed() {
  case "$1" in
    Darwin) brew list --formula "$2" >/dev/null 2>&1 ;;
    SunOS) "$(pkgsrc_prefix)/sbin/pkg_info" -q -e "$2" ;;
    Linux)
      case "$bd_manager" in
        apt-get) [ "$(dpkg-query -W -f='${db:Status-Status}' "$2" 2>/dev/null)" = installed ] ;;
        apk) apk info -e "$2" >/dev/null 2>&1 ;;
        *) rpm -q --quiet "$2" ;;
      esac
      ;;
  esac
}

# Print the required packages that are not installed, on one line.
# shellcheck disable=SC2046
missing_packages() {
  bd_absent=
  for bd_package in $(required_packages "$1"); do
    package_installed "$1" "$bd_package" || bd_absent="$bd_absent $bd_package"
  done
  printf '%s\n' "${bd_absent# }"
}

print_tool_versions() {
  if bd_found=$(resolve_python); then
    printf '  Python:   %s (%s)\n' "$("$bd_found" --version 2>&1)" "$bd_found"
  else
    printf '%s\n' '  Python:   missing (3.9 or newer is required)'
  fi
  printf '  GNU Make: %s\n' "$("$bd_make" --version 2>&1 | sed -n '1p')"
  bd_md5_tool=missing
  for bd_candidate in md5 md5sum digest openssl; do
    command_exists "$bd_candidate" && { bd_md5_tool=$bd_candidate; break; }
  done
  printf '  MD5 tool: %s\n' "$bd_md5_tool"
  if [ "$1" = SunOS ]; then
    printf '  pkgsrc:   %s\n' "$(pkgsrc_prefix)"
    bd_bundle=missing
    for bd_candidate in /opt/tools/etc/openssl/certs/ca-certificates.crt \
      /opt/local/etc/openssl/certs/ca-certificates.crt; do
      [ -f "$bd_candidate" ] && { bd_bundle=$bd_candidate; break; }
    done
    printf '  CA certs: %s\n' "$bd_bundle"
  fi
}

# Report which required packages are missing; set bd_missing.
print_packages() {
  bd_missing=
  printf '\nRequired packages: %s\n' "$(required_packages "$1")"
  check_package_manager "$1" || return 0
  bd_missing=$(missing_packages "$1")
  if [ -n "$bd_missing" ]; then
    printf '  Missing: %s\n' "$bd_missing"
  else
    printf '%s\n' '  All installed.'
  fi
}

status_dependencies() {
  bd_os_name=$(uname -s)
  printf 'Toolchain status for %s (nothing will be installed):\n' "$bd_os_name"
  print_tool_versions "$bd_os_name"
  print_packages "$bd_os_name"
  if [ -n "$bd_missing" ]; then
    printf '\n%s\n' 'Run gmake dependencies to install the missing packages.'
  fi
}

# shellcheck disable=SC2086
install_dependencies() {
  bd_os_name=$(uname -s)
  check_package_manager "$bd_os_name" || return
  bd_missing=$(missing_packages "$bd_os_name")
  if [ -z "$bd_missing" ]; then
    printf 'Nothing to install: %s are installed.\n' "$(required_packages "$bd_os_name")"
  else
    printf 'Installing %s.\n' "$bd_missing"
    case "$bd_os_name" in
      Darwin) brew install $bd_missing || return ;;
      SunOS)
        # Installing one package can make pkgin refresh or upgrade many
        # others, so it runs without -y: it shows its plan and asks first.
        run_privileged "$(pkgsrc_prefix)/bin/pkgin" -y update || return
        run_privileged "$(pkgsrc_prefix)/bin/pkgin" install $bd_missing || return
        ;;
      Linux)
        case "$bd_manager" in
          apt-get) run_privileged apt-get update && run_privileged apt-get install -y $bd_missing ;;
          apk) run_privileged apk update && run_privileged apk add $bd_missing ;;
          zypper) run_privileged zypper --non-interactive refresh &&
            run_privileged zypper --non-interactive install --no-confirm $bd_missing ;;
          *) run_privileged "$bd_manager" -y makecache && run_privileged "$bd_manager" -y install $bd_missing ;;
        esac || return
        ;;
    esac
  fi
  python_is_supported "$(resolve_python)" || {
    printf '%s\n' 'Python 3.9 or newer was not found after installation.' >&2
    return 1
  }
  status_dependencies
}

[ "$#" -eq 1 ] || usage
case "$1" in
  status) status_dependencies ;;
  install) install_dependencies ;;
  python-path) resolve_python ;;
  *) usage ;;
esac
