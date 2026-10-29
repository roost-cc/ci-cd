#!/usr/bin/env sh
set -eu

fail() {
  printf 'not ok: %s\n' "$*" >&2
  exit 1
}

assert_file_exists() {
  test -e "$1" || fail "expected file to exist: $1"
}

assert_contains() {
  file=$1
  needle=$2
  rg --fixed-strings -- "$needle" "$file" >/dev/null || fail "expected $file to contain: $needle"
}

assert_not_contains() {
  pattern=$1
  shift
  if rg "$pattern" "$@" >/dev/null; then
    fail "unexpected pattern '$pattern' found in $*"
  fi
}
