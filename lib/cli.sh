#!/usr/bin/env sh
# Compatibility shim for consumers that source runner modules directly.
# The supported public entrypoint is bin/ci.

ci_cli() {
  "$(dirname "$0")/../bin/ci" "$@"
}
