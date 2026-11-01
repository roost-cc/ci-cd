#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/tests/assertions.sh"

TMP_ROOT=${TMPDIR:-/tmp}/ci-cd-tests.$$
ARTIFACTS_DIR="$TMP_ROOT/artifacts"
mkdir -p "$ARTIFACTS_DIR"
trap 'rm -rf "$TMP_ROOT"' EXIT

run_ci() {
  fixture=$1
  shift
  "$ROOT/bin/ci" "$@" --working-directory "$ROOT/tests/fixtures/$fixture"
}

printf 'test: generic validate/run/artifacts\n'
run_ci generic-command validate --target local --platform linux/amd64
CI_ARTIFACTS_DIR="$ARTIFACTS_DIR/generic" run_ci generic-command run test --target local --platform linux/amd64
assert_file_exists "$ARTIFACTS_DIR/generic/result.txt"
assert_contains "$ARTIFACTS_DIR/generic/result.txt" "generic-ok"
run_ci generic-command run deploy --target local --platform linux/amd64 >/tmp/ci-cd-repo-script.out
assert_contains /tmp/ci-cd-repo-script.out "repo-script-ok:local"

printf 'test: node helper scripts\n'
run_ci node-package-scripts validate --target ci --platform linux/amd64
run_ci node-package-scripts run lint --target ci --platform linux/amd64
run_ci node-package-scripts run test --target ci --platform linux/amd64

printf 'test: python helper commands\n'
run_ci python-basic validate --target ci --platform linux/amd64
run_ci python-basic run test --target ci --platform linux/amd64

printf 'test: go helper commands\n'
run_ci go-basic validate --target ci --platform linux/amd64
run_ci go-basic run test --target ci --platform linux/amd64

printf 'test: selected and detected toolchain profiles\n'
run_ci toolchain-selected validate --target ci
run_ci toolchain-selected run format --target ci >/tmp/ci-cd-toolchain-format.out
assert_contains /tmp/ci-cd-toolchain-format.out "profile-format"
run_ci toolchain-selected run lint --target ci >/tmp/ci-cd-toolchain-lint.out
assert_contains /tmp/ci-cd-toolchain-lint.out "explicit-lint"
if rg --fixed-strings "profile-lint" /tmp/ci-cd-toolchain-lint.out >/dev/null; then
  fail "explicit action should override selected toolchain action"
fi
run_ci auto-node validate --target ci
run_ci auto-node explain lint --target ci >/tmp/ci-cd-auto-node.out
assert_contains /tmp/ci-cd-auto-node.out "npm run lint"

printf 'test: detection by default and no-target warnings\n'
run_ci empty-repo-minimal validate
run_ci empty-repo-minimal run lint >/tmp/ci-cd-no-targets.out 2>/tmp/ci-cd-no-targets.err
assert_contains /tmp/ci-cd-no-targets.err "no lint targets found"
if rg --fixed-strings "action=lint" /tmp/ci-cd-no-targets.out >/dev/null; then
  fail "no-target run should not print the action banner"
fi
run_ci empty-repo-minimal explain lint >/tmp/ci-cd-no-targets-explain.out 2>&1
assert_contains /tmp/ci-cd-no-targets-explain.out "no lint targets found"
run_ci empty-repo-minimal run release >/tmp/ci-cd-no-targets-release.out 2>&1
assert_contains /tmp/ci-cd-no-targets-release.out "no release targets found"
if run_ci empty-repo-minimal run bogus-action >/tmp/ci-cd-bogus-action.out 2>&1; then
  fail "unknown action should fail on minimal config"
fi
assert_contains /tmp/ci-cd-bogus-action.out "Unknown action 'bogus-action'"
run_ci empty-repo-minimal list-actions >/tmp/ci-cd-minimal-list.out

run_ci detected-python explain lint >/tmp/ci-cd-detected-python.out
assert_contains /tmp/ci-cd-detected-python.out "uv run ruff check ."
run_ci detected-python list-actions >/tmp/ci-cd-detected-python-list.out
assert_contains /tmp/ci-cd-detected-python-list.out "lint"

run_ci detection-disabled run lint >/tmp/ci-cd-detection-disabled.out 2>/tmp/ci-cd-detection-disabled.err
assert_contains /tmp/ci-cd-detection-disabled.err "no lint targets found"
if rg --fixed-strings "npm" /tmp/ci-cd-detection-disabled.out /tmp/ci-cd-detection-disabled.err >/dev/null; then
  fail "disabled detection should not resolve the node toolchain"
fi
run_ci detection-disabled run test >/tmp/ci-cd-detection-disabled-test.out
assert_contains /tmp/ci-cd-detection-disabled-test.out "explicit-test-ok"

if "$ROOT/bin/ci" validate --working-directory "$ROOT/tests/fixtures/detection-disabled" --config inert.json >/tmp/ci-cd-inert.out 2>&1; then
  fail "detection disabled with no actions or use_toolchains should fail"
fi
assert_contains /tmp/ci-cd-inert.out "actions is required"

if "$ROOT/bin/ci" validate --working-directory "$ROOT/tests/fixtures/detection-disabled" --config unknown-toolchain.json >/tmp/ci-cd-unknown-toolchain.out 2>&1; then
  fail "unknown use_toolchains name should fail"
fi
assert_contains /tmp/ci-cd-unknown-toolchain.out "Unknown toolchain 'team:does-not-exist'"

printf 'test: deploy and stack dry run\n'
run_ci deploy-stack-dry-run validate --target staging --platform linux/amd64
run_ci deploy-stack-dry-run run deploy --target staging --platform linux/amd64
run_ci deploy-stack-dry-run run stack --target local --platform linux/amd64

printf 'test: release action\n'
run_ci release-basic validate
run_ci release-basic explain release >/tmp/ci-cd-release-explain.out
assert_contains /tmp/ci-cd-release-explain.out "run syft"
assert_contains /tmp/ci-cd-release-explain.out "cosign sign-blob --yes"

RELEASE_ARTIFACTS_DIR="$ARTIFACTS_DIR/release"
RELEASE_LOG="$TMP_ROOT/release-gh.log"
PATH="$ROOT/tests/fixtures/release-tools/bin:$PATH" CI_EVENT=tag CI_REF=refs/tags/v1.2.3 CI_REF_NAME=v1.2.3 CI_TAG=v1.2.3 CI_OIDC_TOKEN=present CI_ARTIFACTS_DIR="$RELEASE_ARTIFACTS_DIR" CI_RELEASE_TEST_LOG="$RELEASE_LOG" run_ci release-basic run release
assert_file_exists "$RELEASE_ARTIFACTS_DIR/release-basic.tar.gz"
assert_file_exists "$RELEASE_ARTIFACTS_DIR/release-basic-sbom.cdx.json"
assert_file_exists "$RELEASE_ARTIFACTS_DIR/release-basic.tar.gz.sig"
assert_file_exists "$RELEASE_ARTIFACTS_DIR/release-basic.tar.gz.pem"
assert_file_exists "$RELEASE_ARTIFACTS_DIR/release-basic-sbom.cdx.json.sig"
assert_file_exists "$RELEASE_ARTIFACTS_DIR/release-basic-sbom.cdx.json.pem"
assert_contains "$RELEASE_LOG" "release upload v1.2.3 --clobber"

PATH="$ROOT/tests/fixtures/release-tools/bin:$PATH" CI_EVENT=tag CI_REF=refs/tags/v1.2.4 CI_REF_NAME=v1.2.4 CI_TAG=v1.2.4 CI_OIDC_TOKEN=present CI_ARTIFACTS_DIR="$ARTIFACTS_DIR/release-dry-run" CI_RELEASE_DRY_RUN=true run_ci release-basic run release >/tmp/ci-cd-release-dry-run.out
assert_contains /tmp/ci-cd-release-dry-run.out "dry-run syft"
assert_contains /tmp/ci-cd-release-dry-run.out "dry-run cosign sign-blob --yes"
assert_contains /tmp/ci-cd-release-dry-run.out "dry-run gh release upload v1.2.4 --clobber"

if PATH="$ROOT/tests/fixtures/release-tools/bin:$PATH" CI_EVENT=push CI_REF=refs/heads/main CI_REF_NAME=main CI_TAG=v1.2.3 CI_OIDC_TOKEN=present CI_ARTIFACTS_DIR="$ARTIFACTS_DIR/release-non-tag" run_ci release-basic run release >/tmp/ci-cd-release-non-tag.out 2>&1; then
  fail "release outside a tag event should fail"
fi
assert_contains /tmp/ci-cd-release-non-tag.out "must run on a tag event"

if PATH="$ROOT/tests/fixtures/release-tools/bin:$PATH" CI_EVENT=tag CI_REF=refs/tags/v1.2.3 CI_REF_NAME=v1.2.3 CI_TAG=v1.2.3 CI_ARTIFACTS_DIR="$ARTIFACTS_DIR/release-no-oidc" run_ci release-basic run release >/tmp/ci-cd-release-no-oidc.out 2>&1; then
  fail "release without OIDC token should fail"
fi
assert_contains /tmp/ci-cd-release-no-oidc.out "requires CI_OIDC_TOKEN"

if PATH="$ROOT/tests/fixtures/release-tools/bin:$PATH" CI_EVENT=tag CI_TAG=v1.2.3 CI_OIDC_TOKEN=present CI_ARTIFACTS_DIR="$ARTIFACTS_DIR/release-no-ref" run_ci release-basic run release >/tmp/ci-cd-release-no-ref.out 2>&1; then
  fail "release without a tag ref should fail"
fi
assert_contains /tmp/ci-cd-release-no-ref.out "requires CI_REF"

if PATH="$ROOT/tests/fixtures/release-tools/bin:$PATH" CI_EVENT=tag CI_REF=refs/tags/v1.2.3 CI_REF_NAME=v1.2.3 CI_TAG=v1.2.3 CI_OIDC_TOKEN=present CI_ARTIFACTS_DIR="$ARTIFACTS_DIR/release-missing-artifact" run_ci release-missing-artifact run release >/tmp/ci-cd-release-missing-artifact.out 2>&1; then
  fail "release with a missing artifact should fail"
fi
assert_contains /tmp/ci-cd-release-missing-artifact.out "Declared artifact is missing"

if PATH="$ROOT/tests/fixtures/release-tools/bin:$PATH" CI_EVENT=tag CI_REF=refs/tags/v1.2.3 CI_REF_NAME=v1.2.3 CI_TAG=v1.2.3 CI_OIDC_TOKEN=present CI_ARTIFACTS_DIR="$ARTIFACTS_DIR/release-no-artifacts" run_ci release-no-artifacts run release >/tmp/ci-cd-release-no-artifacts.out 2>&1; then
  fail "release with no declared artifacts should fail"
fi
assert_contains /tmp/ci-cd-release-no-artifacts.out "produced no release artifacts"

if PATH="/usr/bin:/bin" CI_EVENT=tag CI_REF=refs/tags/v1.2.3 CI_REF_NAME=v1.2.3 CI_TAG=v1.2.3 CI_OIDC_TOKEN=present CI_ARTIFACTS_DIR="$ARTIFACTS_DIR/release-missing-tool" run_ci release-missing-tool run release >/tmp/ci-cd-release-missing-tool.out 2>&1; then
  fail "release with missing tools should fail"
fi
assert_contains /tmp/ci-cd-release-missing-tool.out "requires missing tool"

printf 'test: validation failures\n'
if run_ci generic-command run missing --target local --platform linux/amd64 >/tmp/ci-cd-missing-action.out 2>&1; then
  fail "unknown action should fail"
fi
assert_contains /tmp/ci-cd-missing-action.out "Unknown action 'missing'"

if "$ROOT/bin/ci" validate --working-directory "$ROOT/tests/fixtures/generic-command" --config missing.json >/tmp/ci-cd-missing-config.out 2>&1; then
  fail "missing config should fail"
fi
assert_contains /tmp/ci-cd-missing-config.out "Config file not found"

if "$ROOT/bin/ci" validate --working-directory "$ROOT/tests/fixtures/generic-command" --config malformed.json >/tmp/ci-cd-malformed.out 2>&1; then
  fail "malformed config should fail"
fi
assert_contains /tmp/ci-cd-malformed.out "Malformed JSON"

if run_ci deploy-stack-dry-run run deploy --platform linux/amd64 >/tmp/ci-cd-target.out 2>&1; then
  fail "deploy without target should fail"
fi
assert_contains /tmp/ci-cd-target.out "requires --target"

if run_ci generic-command validate --target missing --platform linux/amd64 >/tmp/ci-cd-target-missing.out 2>&1; then
  fail "unknown target should fail"
fi
assert_contains /tmp/ci-cd-target-missing.out "Unknown target 'missing'"

if run_ci generic-command validate --target local --platform solaris/sparc >/tmp/ci-cd-platform-missing.out 2>&1; then
  fail "unknown platform should fail"
fi
assert_contains /tmp/ci-cd-platform-missing.out "Unknown platform 'solaris/sparc'"

if "$ROOT/bin/ci" run test --working-directory "$ROOT/tests/fixtures/missing-tool" >/tmp/ci-cd-tool.out 2>&1; then
  fail "missing tool should fail"
fi
assert_contains /tmp/ci-cd-tool.out "requires missing tool"

if run_ci missing-default-tool run lint >/tmp/ci-cd-default-tool.out 2>&1; then
  fail "missing default tool should fail"
fi
assert_contains /tmp/ci-cd-default-tool.out "selected toolchain 'team:missing-tool'"
assert_contains /tmp/ci-cd-default-tool.out "override actions.lint"

printf 'test: gate runs the declared subset of {lint,typecheck,test}\n'
run_ci gate-test-only gate --target local --platform linux/amd64 >/tmp/ci-cd-gate-test-only.out
assert_contains /tmp/ci-cd-gate-test-only.out "gate actions: test"
assert_contains /tmp/ci-cd-gate-test-only.out "gate-ran-test"
assert_contains /tmp/ci-cd-gate-test-only.out "gate passed"

run_ci gate-lint-and-test gate --target local --platform linux/amd64 >/tmp/ci-cd-gate-both.out
assert_contains /tmp/ci-cd-gate-both.out "gate actions: lint, test"
assert_contains /tmp/ci-cd-gate-both.out "gate-ran-lint"
assert_contains /tmp/ci-cd-gate-both.out "gate-ran-test"
if rg --fixed-strings "gate-ran-format" /tmp/ci-cd-gate-both.out >/dev/null; then
  fail "gate must not run the format action (it mutates)"
fi
if rg --fixed-strings "gate-ran-build" /tmp/ci-cd-gate-both.out >/dev/null; then
  fail "gate must not run the build action (wrong stage for pre-push)"
fi

run_ci gate-empty-actions gate --target local --platform linux/amd64 >/tmp/ci-cd-gate-empty.out
assert_contains /tmp/ci-cd-gate-empty.out "no gate actions declared"

# Gap-1 guard: a repo with package.json but no declared actions must not have
# the auto-detected node:npm profile's lint/test leak into the gate.
run_ci gate-detected-not-declared gate --target local --platform linux/amd64 >/tmp/ci-cd-gate-detected.out 2>&1
assert_contains /tmp/ci-cd-gate-detected.out "no gate actions declared"
if rg --fixed-strings "gate-detected-test-should-not-run" /tmp/ci-cd-gate-detected.out >/dev/null; then
  fail "gate must not run a detected-but-undeclared action"
fi
if rg "Missing script|npm run|action=lint|action=test" /tmp/ci-cd-gate-detected.out >/dev/null; then
  fail "gate must not resolve detected toolchain actions"
fi

# A declared gate action that fails makes the gate fail with its exit code.
if run_ci gate-failing gate --target local --platform linux/amd64 >/tmp/ci-cd-gate-failing.out 2>&1; then
  fail "gate must fail when a declared action fails"
fi
assert_contains /tmp/ci-cd-gate-failing.out "gate-ran-lint"
assert_contains /tmp/ci-cd-gate-failing.out "gate failed on 'test'"

printf 'test: no-TTY pnpm purge-confirm default\n'
# Headless (the test runner has no TTY): the runner injects pnpm_config_ci=true
# so pnpm rebuilds node_modules without a TTY prompt in the pre-push gate. The
# fixture asks pnpm to report its own interpreted `ci` setting (`pnpm config get
# ci`), so this proves pnpm actually consumes the injected value, not just that
# the env var is present.
run_ci env-confirm-purge run test --target local </dev/null >/tmp/ci-cd-purge-default.out
assert_contains /tmp/ci-cd-purge-default.out "ci=true"
# Caller precedence: a value already in the environment is preserved, never
# clobbered by the runner default.
pnpm_config_ci=false run_ci env-confirm-purge run test --target local </dev/null >/tmp/ci-cd-purge-caller.out
assert_contains /tmp/ci-cd-purge-caller.out "ci=false"

printf 'test: vulns (osv-scanner, faked: no network)\n'
OSV_PATH="$ROOT/tests/fixtures/osv-tools/bin:$PATH"
OSV_LOG="$TMP_ROOT/osv.log"
# Each case gets its own cache with a fresh stamp, so scans run --offline.
fresh_cache() {
  cache="$TMP_ROOT/cache-$1"
  mkdir -p "$cache/ci-cd/osv"
  touch "$cache/ci-cd/osv/last-download"
  printf '%s' "$cache"
}
run_vulns() {
  fixture=$1
  cache=$2
  shift 2
  PATH="$OSV_PATH" XDG_CACHE_HOME="$cache" FAKE_OSV_LOG="$OSV_LOG" \
    "$ROOT/bin/ci" vulns --working-directory "$ROOT/tests/fixtures/$fixture" "$@"
}

# A high finding fails the default (high) threshold, one line per finding.
if run_vulns vulns-high "$(fresh_cache high)" >/tmp/ci-cd-vulns-high.out 2>&1; then
  fail "vulns must fail on a high finding"
fi
assert_contains /tmp/ci-cd-vulns-high.out "1 finding(s) at or above high"
assert_contains /tmp/ci-cd-vulns-high.out "sub/package-lock.json: lodash@4.17.15 GHSA-35jh-r3h4-6jhm CVE-2021-23337 severity=high (CVSS 8.1) fixed=4.17.21"
assert_contains "$OSV_LOG" "scan source -r --format json --offline $ROOT/tests/fixtures/vulns-high"

# A medium finding is reported, not blocking.
run_vulns vulns-medium "$(fresh_cache medium)" >/tmp/ci-cd-vulns-medium.out 2>&1
assert_contains /tmp/ci-cd-vulns-medium.out "reported, not blocking (below high)"
assert_contains /tmp/ci-cd-vulns-medium.out "lodash@4.17.15 GHSA-29mw-wpgm-hmr9 CVE-2020-28500 severity=medium (CVSS 5.3)"
assert_contains /tmp/ci-cd-vulns-medium.out "no findings at or above high"

# --fail-on medium makes it blocking.
if run_vulns vulns-medium "$(fresh_cache medium-fail)" --fail-on medium >/tmp/ci-cd-vulns-medium-fail.out 2>&1; then
  fail "vulns --fail-on medium must fail on a medium finding"
fi
assert_contains /tmp/ci-cd-vulns-medium-fail.out "1 finding(s) at or above medium"
if run_vulns vulns-medium "$(fresh_cache bad-level)" --fail-on severe >/tmp/ci-cd-vulns-bad-level.out 2>&1; then
  fail "vulns --fail-on with an unknown level must fail"
fi
assert_contains /tmp/ci-cd-vulns-bad-level.out "--fail-on must be one of low, medium, high, critical"

# A finding with no score counts as high.
if run_vulns vulns-unscored "$(fresh_cache unscored)" >/tmp/ci-cd-vulns-unscored.out 2>&1; then
  fail "vulns must treat an unscored finding as high"
fi
assert_contains /tmp/ci-cd-vulns-unscored.out "severity=high (no score)"

# An accepted finding: the root ignore file is passed with --config, and
# osv-scanner (faked) filters the finding out.
: >"$OSV_LOG"
run_vulns vulns-ignored "$(fresh_cache ignored)" >/tmp/ci-cd-vulns-ignored.out 2>&1
assert_contains /tmp/ci-cd-vulns-ignored.out "no findings at or above high"
assert_contains "$OSV_LOG" "--config $ROOT/tests/fixtures/vulns-ignored/osv-scanner.toml"

# An ignore entry without a reason is refused with exit 2, before scanning.
: >"$OSV_LOG"
set +e
run_vulns vulns-bad-ignore "$(fresh_cache bad-ignore)" >/tmp/ci-cd-vulns-bad-ignore.out 2>&1
code=$?
set -e
test "$code" -eq 2 || fail "vulns with an ignore entry missing reason must exit 2 (got $code)"
assert_contains /tmp/ci-cd-vulns-bad-ignore.out "missing reason"
test ! -s "$OSV_LOG" || fail "vulns must not scan when the ignore file is invalid"

# osv-scanner exit 128 (no lockfiles) passes.
run_vulns vulns-none "$(fresh_cache none)" >/tmp/ci-cd-vulns-none.out 2>&1
assert_contains /tmp/ci-cd-vulns-none.out "ci-cd: vulns: no lockfiles found"

# Any other osv-scanner failure fails with its message.
if FAKE_OSV_EXIT=129 run_vulns vulns-medium "$(fresh_cache exit129)" >/tmp/ci-cd-vulns-129.out 2>&1; then
  fail "vulns must fail when osv-scanner exits 129"
fi
assert_contains /tmp/ci-cd-vulns-129.out "osv-scanner failed (129)"

# A missing binary is a hard error naming the install command.
if PATH="/usr/bin:/bin" XDG_CACHE_HOME="$(fresh_cache missing)" "$ROOT/bin/ci" vulns --working-directory "$ROOT/tests/fixtures/vulns-medium" >/tmp/ci-cd-vulns-missing.out 2>&1; then
  fail "vulns must fail when osv-scanner is missing"
fi
assert_contains /tmp/ci-cd-vulns-missing.out "osv-scanner is not on PATH"
assert_contains /tmp/ci-cd-vulns-missing.out "go install github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.6.0"

# osv-scanner 1.x is refused.
if FAKE_OSV_VERSION=1.9.2 run_vulns vulns-medium "$(fresh_cache v1)" >/tmp/ci-cd-vulns-v1.out 2>&1; then
  fail "vulns must refuse osv-scanner 1.x"
fi
assert_contains /tmp/ci-cd-vulns-v1.out "osv-scanner 2.x is required"

# A stale stamp (or none) triggers the download flags and refreshes the stamp.
: >"$OSV_LOG"
STALE_CACHE=$(fresh_cache stale)
touch -d '2 days ago' "$STALE_CACHE/ci-cd/osv/last-download"
run_vulns vulns-medium "$STALE_CACHE" >/tmp/ci-cd-vulns-stale.out 2>&1
assert_contains "$OSV_LOG" "--offline-vulnerabilities --download-offline-databases"
if test -n "$(find "$STALE_CACHE/ci-cd/osv/last-download" -mmin +60)"; then
  fail "a successful refresh must update the stamp"
fi

# A fresh stamp but no local database for this ecosystem: download it.
: >"$OSV_LOG"
FAKE_OSV_NO_DB=1 run_vulns vulns-medium "$(fresh_cache new-ecosystem)" >/tmp/ci-cd-vulns-new-eco.out 2>&1
assert_contains "$OSV_LOG" "--download-offline-databases"
assert_contains /tmp/ci-cd-vulns-new-eco.out "no findings at or above high"

# Refresh fails but a database exists: warn with its age and scan offline.
: >"$OSV_LOG"
OLD_DB_CACHE=$(fresh_cache old-db)
mkdir -p "$OLD_DB_CACHE/ci-cd/osv/osv-scalibr/npm"
touch "$OLD_DB_CACHE/ci-cd/osv/osv-scalibr/npm/all.zip"
touch -d '72 hours ago' "$OLD_DB_CACHE/ci-cd/osv/last-download"
FAKE_OSV_DOWNLOAD_FAIL=1 run_vulns vulns-medium "$OLD_DB_CACHE" >/tmp/ci-cd-vulns-old-db.out 2>&1
assert_contains /tmp/ci-cd-vulns-old-db.out "ci-cd: vulns: OSV database is 72h old (refresh failed)"
assert_contains "$OSV_LOG" "--offline $ROOT/tests/fixtures/vulns-medium"
assert_contains /tmp/ci-cd-vulns-old-db.out "reported, not blocking"

# Refresh fails and no database exists: warn and pass.
FAKE_OSV_DOWNLOAD_FAIL=1 run_vulns vulns-high "$TMP_ROOT/cache-no-db" >/tmp/ci-cd-vulns-no-db.out 2>&1
assert_contains /tmp/ci-cd-vulns-no-db.out "ci-cd: vulns: skipped, no OSV database"

# The config's vulns.fail_on sets the default; --fail-on overrides it.
run_vulns gate-vulns "$(fresh_cache config-threshold)" >/tmp/ci-cd-vulns-config.out 2>&1
assert_contains /tmp/ci-cd-vulns-config.out "fail on critical"
if run_vulns gate-vulns "$(fresh_cache config-override)" --fail-on high >/tmp/ci-cd-vulns-override.out 2>&1; then
  fail "--fail-on high must override the config's critical threshold"
fi
if "$ROOT/bin/ci" validate --working-directory "$ROOT/tests/fixtures/gate-vulns" --config bad-fail-on.json >/tmp/ci-cd-vulns-bad-config.out 2>&1; then
  fail "an unknown vulns.fail_on must fail validation"
fi
assert_contains /tmp/ci-cd-vulns-bad-config.out "vulns.fail_on must be one of"

printf 'test: vulns --json writes a result for every outcome\n'
JSON_DIR="$TMP_ROOT/vulns-json"
mkdir -p "$JSON_DIR"
# Passes when the JS expression holds for the parsed result `r`.
assert_json() {
  node -e '
    const r = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
    if (!eval(process.argv[2])) process.exit(1);
  ' "$1" "$2" || fail "expected $1 to satisfy: $2"
}
# Runs a vulns case without and with --json, each on its own copy of the
# cache, and checks stdout, stderr and the exit code are the same. Extra env
# goes after the case name as NAME=value words.
vulns_json_case() {
  name=$1
  shift
  set +e
  env "$@" PATH="$OSV_PATH" XDG_CACHE_HOME="$(fresh_cache "json-$name-a")" \
    "$ROOT/bin/ci" vulns --working-directory "$ROOT/tests/fixtures/$VULNS_FIXTURE" \
    >"$JSON_DIR/$name.text.out" 2>"$JSON_DIR/$name.text.err"
  text_code=$?
  env "$@" PATH="$OSV_PATH" XDG_CACHE_HOME="$(fresh_cache "json-$name-b")" \
    "$ROOT/bin/ci" vulns --working-directory "$ROOT/tests/fixtures/$VULNS_FIXTURE" \
    --json "$JSON_DIR/$name.json" \
    >"$JSON_DIR/$name.json.out" 2>"$JSON_DIR/$name.json.err"
  json_code=$?
  set -e
  test "$text_code" -eq "$json_code" || fail "vulns --json ($name) exit $json_code, without $text_code"
  cmp -s "$JSON_DIR/$name.text.out" "$JSON_DIR/$name.json.out" || fail "vulns --json ($name) changed stdout"
  cmp -s "$JSON_DIR/$name.text.err" "$JSON_DIR/$name.json.err" || fail "vulns --json ($name) changed stderr"
  assert_file_exists "$JSON_DIR/$name.json"
  assert_json "$JSON_DIR/$name.json" 'r.schema === "ci-cd-vulns/v1" && !Number.isNaN(Date.parse(r.scanned_at)) && Array.isArray(r.findings)'
  VULNS_CODE=$json_code
}

VULNS_FIXTURE=vulns-medium vulns_json_case clean
test "$VULNS_CODE" -eq 0 || fail "vulns --json clean must exit 0"
assert_json "$JSON_DIR/clean.json" 'r.status === "clean" && r.fail_on === "high" && r.error === null && r.db_refreshed === false && r.db_age_hours === 0'
# Below the threshold: listed, not blocking.
assert_json "$JSON_DIR/clean.json" 'r.findings.length === 1 && r.findings[0].blocking === false && r.findings[0].severity === "medium"'

VULNS_FIXTURE=vulns-mixed vulns_json_case findings
test "$VULNS_CODE" -eq 1 || fail "vulns --json with a high finding must exit 1"
assert_json "$JSON_DIR/findings.json" 'r.status === "findings" && r.error === null && r.findings.length === 2'
assert_json "$JSON_DIR/findings.json" 'JSON.stringify(r.findings[0]) === JSON.stringify({
  lockfile: "sub/package-lock.json", package: "lodash", version: "4.17.15", ecosystem: "npm",
  ids: ["GHSA-35jh-r3h4-6jhm", "CVE-2021-23337"], max_severity: "8.1", severity: "high",
  blocking: true, fixed: ["4.17.21"] })'
assert_json "$JSON_DIR/findings.json" 'r.findings[1].lockfile === "package-lock.json" && r.findings[1].max_severity === "5.3" && r.findings[1].severity === "medium" && r.findings[1].blocking === false'

VULNS_FIXTURE=vulns-unscored vulns_json_case unscored
assert_json "$JSON_DIR/unscored.json" 'r.findings[0].max_severity === null && r.findings[0].severity === "high" && r.findings[0].blocking === true'

VULNS_FIXTURE=vulns-none vulns_json_case no-lockfiles
test "$VULNS_CODE" -eq 0 || fail "vulns --json with no lockfiles must exit 0"
assert_json "$JSON_DIR/no-lockfiles.json" 'r.status === "no-lockfiles" && r.findings.length === 0 && r.error === null'

# No database and the download fails (the cache has a stamp but no database).
VULNS_FIXTURE=vulns-high vulns_json_case skipped FAKE_OSV_DOWNLOAD_FAIL=1 FAKE_OSV_NO_DB=1
test "$VULNS_CODE" -eq 0 || fail "vulns --json skipped must exit 0"
assert_json "$JSON_DIR/skipped.json" 'r.status === "skipped" && r.error === "no OSV database" && r.db_refreshed === false && r.db_age_hours === null'

VULNS_FIXTURE=vulns-medium vulns_json_case osv-failed FAKE_OSV_EXIT=129
test "$VULNS_CODE" -eq 1 || fail "vulns --json with osv-scanner failing must exit 1"
assert_json "$JSON_DIR/osv-failed.json" 'r.status === "error" && r.error.includes("osv-scanner failed (129)") && r.fail_on === "high"'

VULNS_FIXTURE=vulns-bad-ignore vulns_json_case bad-ignore
test "$VULNS_CODE" -eq 2 || fail "vulns --json with a bad ignore entry must exit 2"
assert_json "$JSON_DIR/bad-ignore.json" 'r.status === "error" && r.error.includes("missing reason") && r.findings.length === 0'

# A refresh that succeeds is recorded.
REFRESH_CACHE="$(fresh_cache json-refresh)"
touch -d '2 days ago' "$REFRESH_CACHE/ci-cd/osv/last-download"
PATH="$OSV_PATH" XDG_CACHE_HOME="$REFRESH_CACHE" "$ROOT/bin/ci" vulns \
  --working-directory "$ROOT/tests/fixtures/vulns-medium" --json "$JSON_DIR/refresh.json" >/dev/null 2>&1
assert_json "$JSON_DIR/refresh.json" 'r.db_refreshed === true && r.db_age_hours === 0 && r.status === "clean"'

# A failed refresh over an old database still scans, and says how old it is.
STALE_DB_CACHE="$(fresh_cache json-stale-db)"
mkdir -p "$STALE_DB_CACHE/ci-cd/osv/osv-scalibr/npm"
touch "$STALE_DB_CACHE/ci-cd/osv/osv-scalibr/npm/all.zip"
touch -d '72 hours ago' "$STALE_DB_CACHE/ci-cd/osv/last-download"
env FAKE_OSV_DOWNLOAD_FAIL=1 PATH="$OSV_PATH" XDG_CACHE_HOME="$STALE_DB_CACHE" "$ROOT/bin/ci" vulns \
  --working-directory "$ROOT/tests/fixtures/vulns-medium" --json "$JSON_DIR/stale-db.json" >/dev/null 2>&1
assert_json "$JSON_DIR/stale-db.json" 'r.status === "clean" && r.db_refreshed === false && r.db_age_hours === 72'

# A relative --json path is from the caller's directory; its parent must exist.
(cd "$JSON_DIR" && PATH="$OSV_PATH" XDG_CACHE_HOME="$(fresh_cache json-relative)" "$ROOT/bin/ci" vulns \
  --working-directory "$ROOT/tests/fixtures/vulns-medium" --json relative.json >/dev/null 2>&1)
assert_json "$JSON_DIR/relative.json" 'r.status === "clean"'
: >"$OSV_LOG"
if run_vulns vulns-medium "$(fresh_cache json-no-parent)" --json "$JSON_DIR/missing/out.json" >/tmp/ci-cd-vulns-json-no-parent.out 2>&1; then
  fail "vulns --json with a missing parent directory must fail"
fi
assert_contains /tmp/ci-cd-vulns-json-no-parent.out "--json: parent directory does not exist: $JSON_DIR/missing"
test ! -s "$OSV_LOG" || fail "vulns must not scan when the --json parent directory is missing"

printf 'test: gate runs vulns only when declared, after the actions\n'
: >"$OSV_LOG"
PATH="$OSV_PATH" XDG_CACHE_HOME="$(fresh_cache gate-undeclared)" FAKE_OSV_LOG="$OSV_LOG" \
  run_ci gate-test-only gate --target local --platform linux/amd64 >/tmp/ci-cd-gate-no-vulns.out
assert_contains /tmp/ci-cd-gate-no-vulns.out "gate actions: test"
test ! -s "$OSV_LOG" || fail "gate must not run vulns when the config has no vulns block"

PATH="$OSV_PATH" XDG_CACHE_HOME="$(fresh_cache gate-vulns)" FAKE_OSV_LOG="$OSV_LOG" \
  run_ci gate-vulns gate --target local --platform linux/amd64 >/tmp/ci-cd-gate-vulns.out 2>&1
assert_contains /tmp/ci-cd-gate-vulns.out "gate actions: test, vulns"
assert_contains /tmp/ci-cd-gate-vulns.out "gate-ran-test"
assert_contains /tmp/ci-cd-gate-vulns.out "reported, not blocking (below critical)"
assert_contains /tmp/ci-cd-gate-vulns.out "gate passed"

if PATH="$OSV_PATH" XDG_CACHE_HOME="$(fresh_cache gate-vulns-failing)" \
  run_ci gate-vulns-failing gate --target local --platform linux/amd64 >/tmp/ci-cd-gate-vulns-failing.out 2>&1; then
  fail "gate must fail on a high finding when vulns is declared"
fi
assert_contains /tmp/ci-cd-gate-vulns-failing.out "gate actions: vulns"
assert_contains /tmp/ci-cd-gate-vulns-failing.out "gate failed on 'vulns' (1)"

printf 'test: provider-agnostic guards\n'
assert_not_contains 'GITHUB_' "$ROOT/bin" "$ROOT/lib" "$ROOT/schema" "$ROOT/ci.mk"
assert_not_contains '/home/robert|work/roost|Roost' "$ROOT/bin" "$ROOT/lib" "$ROOT/schema" "$ROOT/ci.mk"
assert_not_contains '(^|[^[:alnum:]_])bl([^[:alnum:]_]|$)' "$ROOT/bin" "$ROOT/lib" "$ROOT/schema" "$ROOT/ci.mk"

printf 'test: versioning and pinning policy guard\n'
assert_contains "$ROOT/README.md" "## Versioning"
assert_contains "$ROOT/README.md" "v1"
assert_contains "$ROOT/README.md" "v1.0.0"
assert_contains "$ROOT/README.md" "commit SHA"
assert_contains "$ROOT/examples/runners/github-actions/ci.yml" "--branch v1"
assert_contains "$ROOT/examples/runners/gitlab-ci.yml" "--branch v1"

printf 'ok\n'
