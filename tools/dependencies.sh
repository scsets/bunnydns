#!/bin/sh

# Filename: dependencies.sh
# Description: Find, report, and install the tools bunnydns needs.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-09-30
# Version: 0.1.0
# Last-Updated: 2026-09-30
# Update #: 1

# bunnydns needs Python 3.9 or newer (3.14 by default) to run and GNU Make to
# check and install it.  SmartOS also needs pkgsrc's CA bundle for HTTPS.

set -u
LC_ALL=C
export LC_ALL

bd_script_dir=$(unset CDPATH; cd "$(dirname "$0")" && pwd) || exit 1
cd "$bd_script_dir/.." || exit 1

bd_make=${BUNNYDNS_MAKE:-gmake}
bd_python=${BUNNYDNS_PYTHON:-}
bd_pkgin=${BUNNYDNS_PKGIN:-}
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

pkgin_path() {
  if [ "$(zonename)" = global ]; then
    printf '%s\n' /opt/tools/bin/pkgin
  else
    printf '%s\n' /opt/local/bin/pkgin
  fi
}

resolve_pkgin() {
  if command_exists "$bd_pkgin"; then
    command -v "$bd_pkgin"
  else
    bd_found=$(pkgin_path)
    [ -x "$bd_found" ] && printf '%s\n' "$bd_found"
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
    bd_bundle=missing
    for bd_candidate in /opt/tools/etc/openssl/certs/ca-certificates.crt \
      /opt/local/etc/openssl/certs/ca-certificates.crt; do
      [ -f "$bd_candidate" ] && { bd_bundle=$bd_candidate; break; }
    done
    printf '  CA certs: %s\n' "$bd_bundle"
  fi
}

# Ask the package manager what it would change, without changing anything.
# Package lists are split into words on purpose.
# shellcheck disable=SC2086
print_package_updates() {
  printf '\nSystem-package update check (using the current package-manager catalog):\n'
  case "$1" in
    Darwin)
      if ! command_exists brew; then
        printf '%s\n' '  Homebrew is missing; install it before running gmake dependencies.'
      elif HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --verbose --formula $bd_brew_packages; then
        printf '%s\n' '  No Homebrew formula updates were reported.'
      else
        printf '%s\n' '  Homebrew reported updates or could not complete the check.'
      fi
      ;;
    SunOS)
      if bd_found=$(resolve_pkgin); then
        "$bd_found" -n install $bd_pkgsrc_packages || printf '%s\n' '  pkgin could not complete the update check.'
      else
        printf '  pkgin is missing at %s.\n' "$(pkgin_path)"
      fi
      ;;
    Linux)
      bd_manager=$(linux_package_manager) || return 0
      case "$bd_manager" in
        apt-get) apt-get --simulate install $bd_linux_packages ;;
        apk) apk version $bd_linux_packages ;;
        zypper) zypper --non-interactive list-updates ;;
        *) "$bd_manager" check-update $bd_linux_packages ;;  # dnf and yum exit 100 when updates exist
      esac || printf '  %s reported updates or could not complete the check.\n' "$bd_manager"
      ;;
    *) printf '  Unsupported operating system: %s\n' "$1" ;;
  esac
}

status_dependencies() {
  bd_os_name=$(uname -s)
  printf 'Toolchain status for %s (no packages will be installed or upgraded):\n' "$bd_os_name"
  print_tool_versions "$bd_os_name"
  print_package_updates "$bd_os_name"
  printf '\n%s\n' 'Run gmake dependencies to install or upgrade the required tools.'
}

# shellcheck disable=SC2086
install_dependencies() {
  bd_os_name=$(uname -s)
  case "$bd_os_name" in
    Darwin)
      command_exists brew || { printf '%s\n' 'Homebrew is required on macOS.' >&2; return 1; }
      brew update-if-needed || return
      brew install $bd_brew_packages || return
      brew upgrade --formula $bd_brew_packages || return
      ;;
    SunOS)
      bd_found=$(resolve_pkgin) || { printf 'pkgin is required at %s.\n' "$(pkgin_path)" >&2; return 1; }
      run_privileged "$bd_found" -y update || return
      run_privileged "$bd_found" -y install $bd_pkgsrc_packages || return
      ;;
    Linux)
      bd_manager=$(linux_package_manager) || return
      case "$bd_manager" in
        apt-get) run_privileged apt-get update && run_privileged apt-get install -y $bd_linux_packages ;;
        apk) run_privileged apk update && run_privileged apk add --upgrade $bd_linux_packages ;;
        zypper) run_privileged zypper --non-interactive refresh &&
          run_privileged zypper --non-interactive install --no-confirm $bd_linux_packages ;;
        *) run_privileged "$bd_manager" -y makecache && run_privileged "$bd_manager" -y install $bd_linux_packages ;;
      esac || return
      ;;
    *)
      printf 'Unsupported operating system: %s\n' "$bd_os_name" >&2
      return 1
      ;;
  esac
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
