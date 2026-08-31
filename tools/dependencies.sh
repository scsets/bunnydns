#!/bin/sh

# Filename: dependencies.sh
# Description: Inspect, install, and deliberately refresh bunnydns dependencies.
# Author: SCS
# Copyright (C) 2026, SCS, all rights reserved.
# Created: 2026-08-31
# Version: 0.7.0
# Last-Updated: 2026-08-31
# Update #: 1

set -u
LC_ALL=C
export LC_ALL

bd_script_dir=$(unset CDPATH; cd "$(dirname "$0")" && pwd) || exit 1
bd_project_dir=$(unset CDPATH; cd "$bd_script_dir/.." && pwd) || exit 1
cd "$bd_project_dir" || exit 1

bd_make=${BUNNYDNS_MAKE:-gmake}
bd_node=${BUNNYDNS_NODE:-}
bd_npm=${BUNNYDNS_NPM:-}
bd_brew=${BUNNYDNS_BREW:-brew}
bd_pkgin=${BUNNYDNS_PKGIN:-}
bd_apt_get=${BUNNYDNS_APT_GET:-apt-get}
bd_dnf=${BUNNYDNS_DNF:-dnf}
bd_yum=${BUNNYDNS_YUM:-yum}
bd_apk=${BUNNYDNS_APK:-apk}
bd_zypper=${BUNNYDNS_ZYPPER:-zypper}

usage() {
  printf '%s\n' 'Usage: dependencies.sh status|install|refresh' >&2
  exit 1
}

command_exists() {
  [ -n "$1" ] && command -v "$1" >/dev/null 2>&1
}

resolve_node() {
  if command_exists "$bd_node"; then
    command -v "$bd_node"
  elif command_exists node; then
    command -v node
  elif [ -x /opt/tools/bin/node ]; then
    printf '%s\n' /opt/tools/bin/node
  elif [ -x /opt/local/bin/node ]; then
    printf '%s\n' /opt/local/bin/node
  else
    return 1
  fi
}

resolve_npm() {
  if command_exists "$bd_npm"; then
    command -v "$bd_npm"
  elif command_exists npm; then
    command -v npm
  elif [ -x /opt/tools/bin/npm ]; then
    printf '%s\n' /opt/tools/bin/npm
  elif [ -x /opt/local/bin/npm ]; then
    printf '%s\n' /opt/local/bin/npm
  else
    return 1
  fi
}

resolve_pkgin() {
  if command_exists "$bd_pkgin"; then
    command -v "$bd_pkgin"
    return
  fi
  if [ "$(zonename)" = global ]; then
    bd_pkgin_path=/opt/tools/bin/pkgin
  else
    bd_pkgin_path=/opt/local/bin/pkgin
  fi
  if [ -x "$bd_pkgin_path" ]; then
    printf '%s\n' "$bd_pkgin_path"
  else
    return 1
  fi
}

run_privileged() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    printf '%s\n' \
      'Root privileges are required; install sudo or run this target as root.' >&2
    return 1
  fi
}

print_tool_versions() {
  bd_node_path=
  bd_npm_path=
  bd_md5_tool=missing

  if command_exists jq; then
    printf '  jq:       %s\n' "$(jq --version 2>&1 | sed -n '1p')"
  else
    printf '%s\n' '  jq:       missing'
  fi
  if bd_node_path=$(resolve_node); then
    printf '  Node.js:  %s\n' "$("$bd_node_path" --version 2>&1 | sed -n '1p')"
  else
    printf '%s\n' '  Node.js:  missing'
  fi
  if bd_npm_path=$(resolve_npm); then
    printf '  npm:      %s\n' "$("$bd_npm_path" --version 2>&1 | sed -n '1p')"
  else
    printf '%s\n' '  npm:      missing'
  fi
  printf '  GNU Make: %s\n' "$("$bd_make" --version 2>&1 | sed -n '1p')"
  for bd_candidate in md5 md5sum digest openssl; do
    if command_exists "$bd_candidate"; then
      bd_md5_tool=$bd_candidate
      break
    fi
  done
  printf '  MD5 tool: %s\n' "$bd_md5_tool"
}

status_system_packages() {
  bd_os_name=$1
  printf '\nSystem-package update check (using the current package-manager catalog):\n'
  case "$bd_os_name" in
    Darwin)
      if command_exists "$bd_brew"; then
        bd_status=0
        HOMEBREW_NO_AUTO_UPDATE=1 \
          "$bd_brew" outdated --verbose --formula jq node make ||
          bd_status=$?
        if [ "$bd_status" -eq 0 ]; then
          printf '%s\n' '  No Homebrew formula updates were reported.'
        elif [ "$bd_status" -ne 1 ]; then
          printf '%s\n' '  Homebrew could not complete the update check.'
        fi
      else
        printf '%s\n' \
          '  Homebrew is missing; install it before running gmake dependencies.'
      fi
      ;;
    SunOS)
      if ! command_exists zonename; then
        printf '%s\n' '  zonename is missing; SmartOS status cannot be resolved.'
      elif bd_pkgin_path=$(resolve_pkgin); then
        "$bd_pkgin_path" -n install jq nodejs gmake ||
          printf '%s\n' '  pkgin could not complete the update check.'
      else
        if [ "$(zonename)" = global ]; then
          bd_expected_pkgin=/opt/tools/bin/pkgin
        else
          bd_expected_pkgin=/opt/local/bin/pkgin
        fi
        printf '  pkgin is missing at %s.\n' "$bd_expected_pkgin"
      fi
      ;;
    Linux)
      if command_exists "$bd_apt_get"; then
        "$bd_apt_get" --simulate install jq nodejs npm make coreutils ||
          printf '%s\n' '  apt-get could not complete the update check.'
      elif command_exists "$bd_dnf"; then
        bd_status=0
        "$bd_dnf" check-update jq nodejs npm make coreutils || bd_status=$?
        [ "$bd_status" -eq 0 ] || [ "$bd_status" -eq 100 ] ||
          printf '%s\n' '  dnf could not complete the update check.'
      elif command_exists "$bd_yum"; then
        bd_status=0
        "$bd_yum" check-update jq nodejs npm make coreutils || bd_status=$?
        [ "$bd_status" -eq 0 ] || [ "$bd_status" -eq 100 ] ||
          printf '%s\n' '  yum could not complete the update check.'
      elif command_exists "$bd_apk"; then
        "$bd_apk" version jq nodejs npm make coreutils ||
          printf '%s\n' '  apk could not complete the update check.'
      elif command_exists "$bd_zypper"; then
        "$bd_zypper" --non-interactive list-updates ||
          printf '%s\n' '  zypper could not complete the update check.'
      else
        printf '%s\n' \
          '  No supported Linux package manager found (apt-get, dnf, yum, apk, or zypper).'
      fi
      ;;
    *)
      printf '  Unsupported operating system: %s\n' "$bd_os_name"
      ;;
  esac
}

status_npm_packages() {
  printf '\nLocked npm dependency updates (Current/Wanted/Latest):\n'
  if bd_npm_path=$(resolve_npm); then
    bd_status=0
    if "$bd_npm_path" outdated --all; then
      printf '%s\n' '  No newer npm dependency versions were reported.'
    else
      bd_status=$?
      printf '  npm outdated returned status %s; review its output above.\n' \
        "$bd_status"
    fi
    printf '\nnpm security audit:\n'
    bd_status=0
    "$bd_npm_path" audit --omit=dev || bd_status=$?
    if [ "$bd_status" -ne 0 ]; then
      printf '  npm audit returned status %s; review its output above.\n' \
        "$bd_status"
    fi
  else
    printf '%s\n' \
      '  npm is missing; dependency and advisory checks were skipped.'
  fi
}

status_dependencies() {
  bd_os_name=$(uname -s)
  printf 'Toolchain status for %s (no packages will be installed or upgraded):\n' \
    "$bd_os_name"
  print_tool_versions
  status_system_packages "$bd_os_name"
  status_npm_packages
  printf '\nRun gmake dependencies to update system tools and reinstall the reviewed lockfile.\n'
  printf '%s\n' \
    'Run gmake dependencies-refresh only when intentionally advancing npm package versions.'
}

install_system_dependencies() {
  bd_os_name=$(uname -s)
  case "$bd_os_name" in
    Darwin)
      command_exists "$bd_brew" || {
        printf '%s\n' 'Homebrew is required on macOS.' >&2
        return 1
      }
      "$bd_brew" update-if-needed
      "$bd_brew" install jq node make
      "$bd_brew" upgrade --formula jq node make
      ;;
    SunOS)
      command_exists zonename || {
        printf '%s\n' 'zonename is required on SmartOS.' >&2
        return 1
      }
      bd_pkgin_path=$(resolve_pkgin) || {
        if [ "$(zonename)" = global ]; then
          bd_expected_pkgin=/opt/tools/bin/pkgin
        else
          bd_expected_pkgin=/opt/local/bin/pkgin
        fi
        printf 'pkgin is required at %s.\n' "$bd_expected_pkgin" >&2
        return 1
      }
      run_privileged "$bd_pkgin_path" -y update
      run_privileged "$bd_pkgin_path" -y install jq nodejs gmake
      ;;
    Linux)
      if command_exists "$bd_apt_get"; then
        run_privileged "$bd_apt_get" update
        run_privileged "$bd_apt_get" install -y \
          jq nodejs npm make coreutils
      elif command_exists "$bd_dnf"; then
        run_privileged "$bd_dnf" -y makecache
        run_privileged "$bd_dnf" -y install \
          jq nodejs npm make coreutils
      elif command_exists "$bd_yum"; then
        run_privileged "$bd_yum" -y makecache
        run_privileged "$bd_yum" -y install \
          jq nodejs npm make coreutils
      elif command_exists "$bd_apk"; then
        run_privileged "$bd_apk" update
        run_privileged "$bd_apk" add --upgrade \
          jq nodejs npm make coreutils
      elif command_exists "$bd_zypper"; then
        run_privileged "$bd_zypper" --non-interactive refresh
        run_privileged "$bd_zypper" --non-interactive install --no-confirm \
          jq nodejs npm make coreutils
      else
        printf '%s\n' \
          'No supported Linux package manager found (apt-get, dnf, yum, apk, or zypper).' >&2
        return 1
      fi
      ;;
    *)
      printf 'Unsupported operating system: %s\n' "$bd_os_name" >&2
      return 1
      ;;
  esac
}

install_dependencies() {
  install_system_dependencies || return
  bd_node_path=$(resolve_node) || {
    printf '%s\n' 'Node.js was not found after system dependency installation.' >&2
    return 1
  }
  "$bd_node_path" -e \
    'process.exit(Number(process.versions.node.split(".")[0]) >= 18 ? 0 : 1)' || {
      printf '%s\n' 'The installed Node.js is older than version 18.' >&2
      return 1
    }
  bd_npm_path=$(resolve_npm) || {
    printf '%s\n' 'npm was not found after system dependency installation.' >&2
    return 1
  }
  "$bd_npm_path" ci --ignore-scripts
  status_dependencies
}

refresh_dependencies() {
  install_dependencies || return
  bd_node_path=$(resolve_node) || return
  bd_npm_path=$(resolve_npm) || return
  bd_direct_dependencies=$(
    "$bd_node_path" -e \
      'const p = require("./package.json"); for (const name of Object.keys(p.dependencies || {})) console.log(name + "@latest")'
  ) || return
  if [ -z "$bd_direct_dependencies" ]; then
    printf '%s\n' 'package.json has no direct dependencies to refresh.'
    return
  fi
  # npm package names cannot contain shell whitespace; split one name per line.
  # shellcheck disable=SC2086
  "$bd_npm_path" install --save-exact --ignore-scripts $bd_direct_dependencies
  "$bd_make" --no-print-directory self-check
  status_dependencies
}

[ "$#" -eq 1 ] || usage
case "$1" in
  status) status_dependencies ;;
  install) install_dependencies ;;
  refresh) refresh_dependencies ;;
  *) usage ;;
esac
