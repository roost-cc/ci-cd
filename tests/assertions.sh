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

# Passes when the JS expression holds for the parsed JSON file `r`.
assert_json() {
  node -e '
    const r = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    if (!eval(process.argv[2])) process.exit(1);
  ' "$1" "$2" || fail "expected $1 to satisfy: $2"
}

assert_not_contains() {
  pattern=$1
  shift
  if rg "$pattern" "$@" >/dev/null; then
    fail "unexpected pattern '$pattern' found in $*"
  fi
}
