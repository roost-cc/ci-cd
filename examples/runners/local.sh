#!/usr/bin/env sh
set -eu

: "${CI_TARGET:=local}"
: "${CI_PLATFORM:=linux/amd64}"
export CI_EVENT="${CI_EVENT:-local}"
export CI_TARGET
export CI_PLATFORM

"$(dirname "$0")/../../bin/ci" run "${1:-test}" --target "$CI_TARGET" --platform "$CI_PLATFORM"
