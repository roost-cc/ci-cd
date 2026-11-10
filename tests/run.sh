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

printf 'test: gate steps run without the hook GIT_DIR (linked-worktree push)\n'
(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  HOOK_DIR="$TMP_ROOT/hook-env"
  mkdir -p "$HOOK_DIR/step-tmp"
  # The step's temp repo goes under TMP_ROOT, so the exit trap removes it.
  export CI_FIXTURE_TMP="$HOOK_DIR/step-tmp"
  git init -q --bare "$HOOK_DIR/remote.git"
  git init -q -b main "$HOOK_DIR/main"
  cat >"$HOOK_DIR/main/.ci-cd.json" <<'EOF'
{
  "version": 1,
  "project": { "name": "hook-env" },
  "targets": { "local": {} },
  "platforms": ["linux/amd64"],
  "actions": {
    "test": {
      "commands": [
        "d=$(mktemp -d \"$CI_FIXTURE_TMP/step.XXXXXX\") && cd \"$d\" && git init -q && echo x >x && git add x && git -c user.name=t -c user.email=t@t commit -qm fixture && echo gate-step-git-done"
      ],
      "env": { "GIT_DIR": "action-git-dir", "GIT_WORK_TREE": "action-wt", "GIT_INDEX_FILE": "action-index" }
    }
  }
}
EOF
  git -C "$HOOK_DIR/main" add .ci-cd.json
  git -C "$HOOK_DIR/main" -c user.name=t -c user.email=t@t commit -qm init
  git -C "$HOOK_DIR/main" remote add origin "$HOOK_DIR/remote.git"
  git -C "$HOOK_DIR/main" worktree add -q -b wt "$HOOK_DIR/wt"
  printf '#!/bin/sh\nexec "%s/bin/ci" gate --target local --platform linux/amd64\n' "$ROOT" \
    >"$HOOK_DIR/main/.git/hooks/pre-push"
  chmod +x "$HOOK_DIR/main/.git/hooks/pre-push"
  head_before=$(git -C "$HOOK_DIR/wt" rev-parse HEAD)
  index_before=$(git -C "$HOOK_DIR/wt" ls-files --stage)
  git -C "$HOOK_DIR/wt" push -q origin wt >/tmp/ci-cd-hook-env.out 2>&1 ||
    fail "push from the linked worktree must pass the gate"
  assert_contains /tmp/ci-cd-hook-env.out "gate-step-git-done"
  test "$(git -C "$HOOK_DIR/wt" rev-parse HEAD)" = "$head_before" ||
    fail "a gate step moved the pushing worktree's HEAD"
  test "$(git -C "$HOOK_DIR/wt" ls-files --stage)" = "$index_before" ||
    fail "a gate step rewrote the pushing worktree's index"
) || exit 1

printf 'test: gate steps strip each git variable independently\n'
# Every step of `ci run` and `ci gate` fails if GIT_DIR, GIT_WORK_TREE or
# GIT_INDEX_FILE reaches it, whether the caller or the action env sets it.
(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  STRIP_DIR="$TMP_ROOT/strip-git-vars"
  mkdir -p "$STRIP_DIR"
  probe='for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do if env | grep -q \"^$v=\"; then echo leaked-$v >&2; exit 17; fi; done; echo vars-absent'
  write_config() {
    cat >|"$STRIP_DIR/.ci-cd.json" <<EOF
{
  "version": 1,
  "project": { "name": "strip-git-vars" },
  "targets": { "local": {} },
  "platforms": ["linux/amd64"],
  "actions": {
    "test": { "commands": ["$probe", "$probe"], "env": { $1 } },
    "lint": { "commands": ["$probe"] }
  }
}
EOF
  }
  check() {
    label=$1 mode=$2 expected=$3
    out="$STRIP_DIR/out"
    if [ "$mode" = run ]; then
      set -- run test
    else
      set -- gate
    fi
    "$ROOT/bin/ci" "$@" --working-directory "$STRIP_DIR" --target local --platform linux/amd64 >|"$out" 2>&1 ||
      fail "$label: a step saw a git variable: $(cat "$out")"
    count=$(grep -c '^vars-absent$' "$out" || true)
    test "$count" = "$expected" || fail "$label: $count of $expected steps ran clean"
  }
  for mode in run gate; do
    if [ "$mode" = run ]; then expected=2; else expected=3; fi
    write_config ''
    check "$mode empty" "$mode" "$expected"
    for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
      (export "$name=bad-path" && check "$mode caller $name" "$mode" "$expected") || exit 1
      write_config "\"$name\": \"bad-path\""
      check "$mode action $name" "$mode" "$expected"
    done
    write_config '"GIT_DIR": "a", "GIT_WORK_TREE": "b", "GIT_INDEX_FILE": "c"'
    (export GIT_DIR=a GIT_WORK_TREE=b GIT_INDEX_FILE=c && check "$mode caller and action all" "$mode" "$expected") || exit 1
  done
) || exit 1

printf 'test: check runs the gate steps on one commit in a throwaway worktree\n'
(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  CHECK_DIR="$TMP_ROOT/check"
  # ci check makes its worktrees here, so a leftover shows.
  CHECK_TMP="$CHECK_DIR/tmp"
  mkdir -p "$CHECK_TMP"
  "$ROOT/bin/ci" help >"$CHECK_DIR/help.out"
  assert_contains "$CHECK_DIR/help.out" "bin/ci check <commit>"
  if "$ROOT/bin/ci" check >"$CHECK_DIR/no-commit.out" 2>&1; then
    fail "check without a commit must fail"
  fi
  assert_contains "$CHECK_DIR/no-commit.out" "Command 'check' requires a commit."
  # check refuses an absolute --config, and any other: only the commit's own config counts.
  for config in "$ROOT/tests/fixtures/gate-lint-and-test/.ci-cd.json" ../../outside.json .ci-cd.json; do
    if TMPDIR="$CHECK_TMP" "$ROOT/bin/ci" check HEAD --config "$config" --working-directory "$ROOT" \
      >|"$CHECK_DIR/config.out" 2>&1; then
      fail "check must refuse --config $config"
    fi
    assert_contains "$CHECK_DIR/config.out" "Command 'check' reads the commit's own .ci-cd.json; it takes no --config."
  done
  test -z "$(ls -A "$CHECK_TMP")" || fail "a refused --config must add no worktree"

  # Makes the repo $1 with $2 as its committed .ci-cd.json.
  check_repo() {
    git init -q -b main "$CHECK_DIR/$1"
    cp "$2" "$CHECK_DIR/$1/.ci-cd.json"
    git -C "$CHECK_DIR/$1" add .ci-cd.json
    git -C "$CHECK_DIR/$1" -c user.name=t -c user.email=t@t commit -qm init
  }
  # Runs `ci check $2 [args]` in the repo $1; sets CHECK_CODE, output in $1.out.
  run_check() {
    repo=$1 commit=$2
    shift 2
    set +e
    TMPDIR="$CHECK_TMP" "$ROOT/bin/ci" check "$commit" --working-directory "$CHECK_DIR/$repo" "$@" \
      >"$CHECK_DIR/$repo.out" 2>&1
    CHECK_CODE=$?
    set -e
  }
  # The record and log paths of the repo $1's HEAD.
  check_paths() {
    head=$(git -C "$CHECK_DIR/$1" rev-parse HEAD)
    RECORD="$CHECK_DIR/$1/.git/ci-cd/checks/$head.json"
    LOG="$CHECK_DIR/$1/.git/ci-cd/checks/$head.log"
  }
  assert_no_worktree() {
    test "$(git -C "$CHECK_DIR/$1" worktree list | wc -l)" -eq 1 ||
      fail "$1: a worktree was left behind: $(git -C "$CHECK_DIR/$1" worktree list)"
    test -z "$(ls -A "$CHECK_TMP")" || fail "$1: a temp directory was left behind: $(ls -A "$CHECK_TMP")"
  }
  # The repo $1's check failed with a fail record whose steps are $2 (JSON).
  assert_check_fails() {
    test "$CHECK_CODE" -ne 0 || fail "$1: check must exit non-zero"
    check_paths "$1"
    assert_json "$RECORD" "r.verdict === 'fail' && JSON.stringify(r.steps) === '$2'"
    assert_no_worktree "$1"
  }
  gate='--target local --platform linux/amd64'

  check_repo pass "$ROOT/tests/fixtures/gate-lint-and-test/.ci-cd.json"
  run_check pass HEAD $gate
  test "$CHECK_CODE" -eq 0 || fail "check of a passing commit must exit 0: $(cat "$CHECK_DIR/pass.out")"
  check_paths pass
  tree=$(git -C "$CHECK_DIR/pass" rev-parse 'HEAD^{tree}')
  assert_json "$RECORD" "r.commit === '$head' && /^[0-9a-f]{40}$/.test(r.commit) && r.tree === '$tree'"
  assert_json "$RECORD" "r.verdict === 'pass' && JSON.stringify(r.steps) === '[\"lint\",\"test\"]'"
  assert_json "$RECORD" "r.started === new Date(r.started).toISOString() && r.finished >= r.started"
  assert_contains "$LOG" "gate-ran-lint"
  assert_contains "$LOG" "gate-ran-test"
  assert_contains "$LOG" "gate passed"
  assert_contains "$CHECK_DIR/pass.out" "gate-ran-test"
  assert_no_worktree pass

  # A linked worktree of the clone writes to the clone's common git directory.
  git -C "$CHECK_DIR/pass" worktree add -q -b linked "$CHECK_DIR/pass-linked"
  git -C "$CHECK_DIR/pass-linked" -c user.name=t -c user.email=t@t commit -q --allow-empty -m linked
  run_check pass-linked HEAD $gate
  test "$CHECK_CODE" -eq 0 || fail "check from a linked worktree must pass: $(cat "$CHECK_DIR/pass-linked.out")"
  linked_head=$(git -C "$CHECK_DIR/pass-linked" rev-parse HEAD)
  assert_json "$CHECK_DIR/pass/.git/ci-cd/checks/$linked_head.json" "r.verdict === 'pass'"
  git -C "$CHECK_DIR/pass" worktree remove "$CHECK_DIR/pass-linked"

  check_repo failing "$ROOT/tests/fixtures/gate-failing/.ci-cd.json"
  run_check failing HEAD $gate
  assert_check_fails failing '["lint","test"]'
  assert_contains "$LOG" "gate-ran-lint"
  assert_contains "$LOG" "gate failed on 'test'"

  # An untracked file that fails lint in the checkout does not reach the check.
  cat >"$CHECK_DIR/dirty.json" <<'EOF'
{
  "version": 1,
  "project": { "name": "check-dirty" },
  "targets": { "local": {} },
  "platforms": ["linux/amd64"],
  "actions": { "lint": { "commands": ["test ! -e lint-fails"] } }
}
EOF
  check_repo dirty "$CHECK_DIR/dirty.json"
  : >"$CHECK_DIR/dirty/lint-fails"
  if "$ROOT/bin/ci" gate --working-directory "$CHECK_DIR/dirty" $gate >"$CHECK_DIR/dirty-gate.out" 2>&1; then
    fail "the dirty file must fail lint in the checkout"
  fi
  run_check dirty HEAD $gate
  test "$CHECK_CODE" -eq 0 || fail "an uncommitted file must not change the verdict: $(cat "$CHECK_DIR/dirty.out")"
  check_paths dirty
  assert_json "$RECORD" "r.verdict === 'pass'"
  assert_no_worktree dirty

  run_check pass 0123456789abcdef0123456789abcdef01234567 $gate
  test "$CHECK_CODE" -ne 0 || fail "check of an unknown commit must fail"
  assert_contains "$CHECK_DIR/pass.out" "check: not a commit: 0123456789abcdef0123456789abcdef01234567"
  test ! -e "$CHECK_DIR/pass/.git/ci-cd/checks/0123456789abcdef0123456789abcdef01234567.json" ||
    fail "an unknown commit must leave no record"
  assert_no_worktree pass

  check_repo missing-tool "$ROOT/tests/fixtures/missing-tool/.ci-cd.json"
  run_check missing-tool HEAD
  assert_check_fails missing-tool '["test"]'
  assert_contains "$LOG" "requires missing tool"

  printf '{ "version": 1,\n' >"$CHECK_DIR/malformed.json"
  check_repo malformed "$CHECK_DIR/malformed.json"
  run_check malformed HEAD $gate
  assert_check_fails malformed '[]'
  assert_contains "$LOG" "Malformed JSON"

  printf '{ "version": 2, "project": { "name": "check-invalid" }, "actions": {} }\n' >"$CHECK_DIR/invalid.json"
  check_repo invalid "$CHECK_DIR/invalid.json"
  run_check invalid HEAD
  assert_check_fails invalid '[]'
  assert_contains "$LOG" "Config validation failed"

  cat >"$CHECK_DIR/crash.json" <<'EOF'
{
  "version": 1,
  "project": { "name": "check-crash" },
  "actions": { "test": { "commands": ["kill -KILL $$"] } }
}
EOF
  check_repo crash "$CHECK_DIR/crash.json"
  run_check crash HEAD
  assert_check_fails crash '["test"]'
) || exit 1

printf 'test: gate reads .ci-cd.json promotion\n'
(
  # This suite may itself run in a pre-push hook, which sets these.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE PRE_COMMIT_REMOTE_BRANCH PRE_COMMIT_TO_REF
  PROMO_DIR="$TMP_ROOT/promotion"
  mkdir -p "$PROMO_DIR"
  gate='--target local --platform linux/amd64'
  warning='ci-cd: .ci-cd.json sets no "promotion"; the full gate runs in the hook (E70 R11)'

  printf '{ "version": 1, "project": { "name": "bad-promotion" }, "promotion": "x", "actions": {} }\n' \
    >"$PROMO_DIR/bad.json"
  if "$ROOT/bin/ci" validate --config "$PROMO_DIR/bad.json" >"$PROMO_DIR/bad.out" 2>&1; then
    fail "validate must refuse an unknown promotion"
  fi
  assert_contains "$PROMO_DIR/bad.out" "promotion must be one of pre-push-gate, check-record; got 'x'."
  run_ci gate-promotion-check-record validate $gate
  run_ci gate-promotion-pre-push validate $gate

  run_ci gate-test-only gate $gate >"$PROMO_DIR/absent.out"
  assert_contains "$PROMO_DIR/absent.out" "$warning"
  assert_contains "$PROMO_DIR/absent.out" "gate-ran-test"
  # The key absent on a push to main is still today's gate.
  env PRE_COMMIT_REMOTE_BRANCH=refs/heads/main PRE_COMMIT_TO_REF=0123456789abcdef0123456789abcdef01234567 \
    "$ROOT/bin/ci" gate --working-directory "$ROOT/tests/fixtures/gate-test-only" $gate >"$PROMO_DIR/absent-main.out"
  assert_contains "$PROMO_DIR/absent-main.out" "gate-ran-test"

  run_ci gate-promotion-pre-push gate $gate >"$PROMO_DIR/pre-push.out"
  assert_contains "$PROMO_DIR/pre-push.out" "gate-ran-test"
  assert_not_contains 'sets no "promotion"' "$PROMO_DIR/pre-push.out"

  # Not started by a push: the full gate.
  run_ci gate-promotion-check-record gate $gate >"$PROMO_DIR/unpushed.out"
  assert_contains "$PROMO_DIR/unpushed.out" "gate-ran-lint"
  assert_contains "$PROMO_DIR/unpushed.out" "gate-ran-test"
  assert_not_contains 'sets no "promotion"' "$PROMO_DIR/unpushed.out"

  env PRE_COMMIT_REMOTE_BRANCH=refs/heads/feature PRE_COMMIT_TO_REF=0123456789abcdef0123456789abcdef01234567 \
    "$ROOT/bin/ci" gate --working-directory "$ROOT/tests/fixtures/gate-promotion-check-record" $gate \
    >"$PROMO_DIR/branch.out" 2>&1 || fail "a branch push must pass: $(cat "$PROMO_DIR/branch.out")"
  assert_contains "$PROMO_DIR/branch.out" "a push to refs/heads/feature is not a promotion; no check runs"
  assert_not_contains 'gate-ran-|action=' "$PROMO_DIR/branch.out"

  # A push to main reads the check record of the pushed commit.
  REPO="$PROMO_DIR/repo"
  git init -q -b main "$REPO"
  cp "$ROOT/tests/fixtures/gate-promotion-check-record/.ci-cd.json" "$REPO/.ci-cd.json"
  git -C "$REPO" add .ci-cd.json
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm init
  head=$(git -C "$REPO" rev-parse HEAD)
  RECORD="$REPO/.git/ci-cd/checks/$head.json"
  # Runs the gate as a push of $1 to main, with the env assignments $2...; sets
  # GATE_CODE, output in $PROMO_DIR/main.out.
  push_main() {
    to_ref=$1
    shift
    set +e
    env PRE_COMMIT_REMOTE_BRANCH=refs/heads/main ${to_ref:+PRE_COMMIT_TO_REF=$to_ref} "$@" \
      "$ROOT/bin/ci" gate --working-directory "$REPO" $gate >|"$PROMO_DIR/main.out" 2>&1
    GATE_CODE=$?
    set -e
  }
  # The push of $1 is refused for the reason $2 and prints `ci check $3`.
  assert_refused() {
    test "$GATE_CODE" -ne 0 || fail "$2: the push must be refused: $(cat "$PROMO_DIR/main.out")"
    assert_contains "$PROMO_DIR/main.out" "$2"
    assert_contains "$PROMO_DIR/main.out" "ci check $3"
    assert_not_contains 'gate-ran-' "$PROMO_DIR/main.out"
  }

  push_main ''
  assert_refused '' "PRE_COMMIT_TO_REF is not a commit ID" '<commit>'
  push_main "$head"
  assert_refused "$head" "no readable check record for $head" "$head"

  TMPDIR="$PROMO_DIR" "$ROOT/bin/ci" check HEAD --working-directory "$REPO" $gate >"$PROMO_DIR/check.out" 2>&1 ||
    fail "check must pass: $(cat "$PROMO_DIR/check.out")"
  push_main "$head"
  test "$GATE_CODE" -eq 0 || fail "a passing record must pass the push: $(cat "$PROMO_DIR/main.out")"
  assert_contains "$PROMO_DIR/main.out" "check record for $head: pass"
  assert_not_contains 'gate-ran-' "$PROMO_DIR/main.out"

  # The record lookup's git has a 10-second timeout; a timeout refuses.
  mkdir -p "$PROMO_DIR/slow-git"
  printf '#!/bin/sh\nexec sleep 30\n' >"$PROMO_DIR/slow-git/git"
  chmod +x "$PROMO_DIR/slow-git/git"
  started=$(date +%s)
  push_main "$head" PATH="$PROMO_DIR/slow-git:$PATH"
  elapsed=$(($(date +%s) - started))
  assert_refused "$head" "git cannot name the git common directory" "$head"
  test "$elapsed" -lt 20 || fail "the git timeout must refuse in about 10 seconds, took ${elapsed}s"

  sed 's/"verdict": "pass"/"verdict": "fail"/' "$RECORD" >"$PROMO_DIR/fail.json"
  cp "$PROMO_DIR/fail.json" "$RECORD"
  push_main "$head"
  assert_refused "$head" "the check of $head did not pass (fail)" "$head"

  other=0123456789abcdef0123456789abcdef01234567
  printf '{ "commit": "%s", "verdict": "pass" }\n' "$other" >|"$RECORD"
  push_main "$head"
  assert_refused "$head" "the check record is not for $head" "$head"

  printf 'not json\n' >|"$RECORD"
  push_main "$head"
  assert_refused "$head" "no readable check record for $head" "$head"
) || exit 1

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
# The fixtures sit inside this repo's history. Git stops looking at tests/, so
# here they are not a git checkout; `vulns compares` builds real histories.
GIT_CEILING_DIRECTORIES=$(CDPATH= cd -- "$ROOT/tests" && pwd -P)
export GIT_CEILING_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
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
assert_contains /tmp/ci-cd-vulns-high.out "1 new finding(s) at or above high"
assert_contains /tmp/ci-cd-vulns-high.out "sub/package-lock.json: lodash@4.17.15 GHSA-35jh-r3h4-6jhm CVE-2021-23337 severity=high (CVSS 8.1) fixed=4.17.21"
assert_contains "$OSV_LOG" "scan source -r --format json --offline $ROOT/tests/fixtures/vulns-high"

# A medium finding is reported, not blocking.
run_vulns vulns-medium "$(fresh_cache medium)" >/tmp/ci-cd-vulns-medium.out 2>&1
assert_contains /tmp/ci-cd-vulns-medium.out "reported, not blocking (below high)"
assert_contains /tmp/ci-cd-vulns-medium.out "lodash@4.17.15 GHSA-29mw-wpgm-hmr9 CVE-2020-28500 severity=medium (CVSS 5.3)"
assert_contains /tmp/ci-cd-vulns-medium.out "no new findings at or above high"

# --fail-on medium makes it blocking.
if run_vulns vulns-medium "$(fresh_cache medium-fail)" --fail-on medium >/tmp/ci-cd-vulns-medium-fail.out 2>&1; then
  fail "vulns --fail-on medium must fail on a medium finding"
fi
assert_contains /tmp/ci-cd-vulns-medium-fail.out "1 new finding(s) at or above medium"
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
assert_contains /tmp/ci-cd-vulns-ignored.out "no new findings at or above high"
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
assert_contains /tmp/ci-cd-vulns-new-eco.out "no new findings at or above high"

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
assert_json "$JSON_DIR/clean.json" 'r.findings.length === 1 && r.findings[0].blocking === false && r.findings[0].at_fail_on === false && r.findings[0].severity === "medium"'

VULNS_FIXTURE=vulns-mixed vulns_json_case findings
test "$VULNS_CODE" -eq 1 || fail "vulns --json with a high finding must exit 1"
assert_json "$JSON_DIR/findings.json" 'r.status === "findings" && r.error === null && r.findings.length === 2'
assert_json "$JSON_DIR/findings.json" 'JSON.stringify(r.findings[0]) === JSON.stringify({
  lockfile: "sub/package-lock.json", package: "lodash", version: "4.17.15", ecosystem: "npm",
  ids: ["GHSA-35jh-r3h4-6jhm", "CVE-2021-23337"], max_severity: "8.1", severity: "high",
  status: "new", at_fail_on: true, blocking: true, fixed: ["4.17.21"], advisory_published: null })'
assert_json "$JSON_DIR/findings.json" 'r.base.compared === false && r.base.ref === null && r.base.commit === null && r.base.reason === "not a git checkout"'
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

printf 'test: vulns compares with the merge base\n'
COMPARE_DIR="$TMP_ROOT/vulns-compare"
mkdir -p "$COMPARE_DIR"
OSV_JSON="$ROOT/tests/fixtures/osv-tools/osv-json.mjs"
git_commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m "$2"
}
# Commits the scanner's answer for these findings (each a JSON argument of
# osv-json.mjs); with none, a scan that finds nothing.
commit_findings() {
  repo=$1
  shift
  node "$OSV_JSON" "$@" >"$repo/osv-output.json"
  git_commit "$repo" findings
}
# A repo whose main has these findings, with origin/main and origin/HEAD on it.
base_repo() {
  repo="$COMPARE_DIR/$1"
  shift
  git init -q -b main "$repo"
  commit_findings "$repo" "$@"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
# Runs vulns on a repo, sets COMPARE_CODE and leaves the result in $name.json
# and the output in $name.out. COMPARE_ENV adds env words, COMPARE_PATH replaces
# PATH and COMPARE_REPO the directory, for that one run.
compare() {
  name=$1
  shift
  set +e
  env ${COMPARE_ENV:-} PATH="${COMPARE_PATH:-$OSV_PATH}" XDG_CACHE_HOME="$(fresh_cache "compare-$name")" \
    FAKE_OSV_LOG="$OSV_LOG" "$ROOT/bin/ci" vulns --working-directory "${COMPARE_REPO:-$COMPARE_DIR/$name}" \
    --json "$COMPARE_DIR/$name.json" "$@" >"$COMPARE_DIR/$name.out" 2>&1
  COMPARE_CODE=$?
  set -e
  # Shells differ on whether `VAR=x function` outlives the call.
  COMPARE_ENV=
  COMPARE_PATH=
  COMPARE_REPO=
}
assert_blocks() {
  test "$COMPARE_CODE" -eq 1 || fail "vulns ($1) must block, exit $COMPARE_CODE"
  assert_json "$COMPARE_DIR/$1.json" 'r.status === "findings" && r.findings.some((f) => f.blocking)'
}
assert_passes() {
  test "$COMPARE_CODE" -eq 0 || fail "vulns ($1) must pass, exit $COMPARE_CODE"
  assert_json "$COMPARE_DIR/$1.json" 'r.findings.every((f) => !f.blocking)'
}
OLD='"published":"2021-02-15T13:15:00Z"'
YOUNG='"published":"2026-10-31T00:00:00Z"'
WITH_FIX="{\"fixed\":\"4.17.21\",$OLD}"
NO_FIX="{$OLD}"
YOUNG_FIX="{\"fixed\":\"4.17.21\",$YOUNG}"

# A finding the branch adds blocks, whatever its fix; one main has does not.
for case in "with-fix:$WITH_FIX" "no-fix:$NO_FIX" "young-fix:$YOUNG_FIX"; do
  kind=${case%%:*}
  finding=${case#*:}
  base_repo "new-$kind"
  commit_findings "$COMPARE_DIR/new-$kind" "$finding"
  compare "new-$kind"
  assert_blocks "new-$kind"
  assert_contains "$COMPARE_DIR/new-$kind.out" "1 new finding(s) at or above high"
  assert_contains "$COMPARE_DIR/new-$kind.out" "1 new, 0 existing"
  assert_json "$COMPARE_DIR/new-$kind.json" 'r.findings[0].status === "new" && r.base.compared === true && r.base.ref === "origin/HEAD" && r.base.reason === null && /^[0-9a-f]{40}$/.test(r.base.commit)'

  base_repo "existing-$kind" "$finding"
  compare "existing-$kind"
  assert_passes "existing-$kind"
  assert_contains "$COMPARE_DIR/existing-$kind.out" "existing, already on the base, not blocking"
  assert_contains "$COMPARE_DIR/existing-$kind.out" "0 new, 1 existing"
  assert_contains "$COMPARE_DIR/existing-$kind.out" "no new findings at or above high"
  assert_json "$COMPARE_DIR/existing-$kind.json" 'r.status === "findings" && r.findings[0].status === "existing"'
done
assert_contains "$COMPARE_DIR/existing-with-fix.out" "severity=high (CVSS 8.1) fixed=4.17.21 advisory=2021-02-15"
assert_json "$COMPARE_DIR/existing-with-fix.json" 'r.findings[0].advisory_published === "2021-02-15T13:15:00Z"'

# An existing finding never blocks at any severity; below fail_on it is `clean`.
base_repo existing-critical '{"score":"9.8"}'
compare existing-critical --fail-on low
assert_passes existing-critical
base_repo existing-medium '{"score":"5.3"}'
compare existing-medium
assert_passes existing-medium
assert_json "$COMPARE_DIR/existing-medium.json" 'r.status === "clean"'

# A new finding below fail_on is reported, and exit and status stay clean.
base_repo new-medium
commit_findings "$COMPARE_DIR/new-medium" '{"score":"5.3"}'
compare new-medium
assert_passes new-medium
assert_contains "$COMPARE_DIR/new-medium.out" "reported, not blocking (below high)"
assert_json "$COMPARE_DIR/new-medium.json" 'r.status === "clean" && r.findings[0].status === "new"'

# One new finding among existing ones blocks, and only it does.
base_repo mixed '{"package":"old-pkg"}'
commit_findings "$COMPARE_DIR/mixed" '{"package":"old-pkg"}' '{"package":"new-pkg"}'
compare mixed
assert_blocks mixed
assert_contains "$COMPARE_DIR/mixed.out" "1 new, 1 existing"
assert_json "$COMPARE_DIR/mixed.json" 'r.findings.find((f) => f.package === "old-pkg").blocking === false && r.findings.find((f) => f.package === "new-pkg").blocking === true'

# The version is not in the key, and ids can group differently per version.
base_repo version-move '{"version":"4.17.15"}'
commit_findings "$COMPARE_DIR/version-move" '{"version":"4.17.16"}'
compare version-move
assert_passes version-move
assert_json "$COMPARE_DIR/version-move.json" 'r.findings[0].status === "existing"'
base_repo alias-move '{"ids":["GHSA-aaaa-aaaa-aaaa"],"aliases":["CVE-2021-1"]}'
commit_findings "$COMPARE_DIR/alias-move" '{"ids":["GHSA-bbbb-bbbb-bbbb"],"aliases":["CVE-2021-1"]}'
compare alias-move
assert_passes alias-move

# A new advisory, a new lock file and a new package are new.
base_repo new-advisory-on-a-found-package '{"ids":["GHSA-aaaa-aaaa-aaaa"]}'
commit_findings "$COMPARE_DIR/new-advisory-on-a-found-package" '{"ids":["GHSA-bbbb-bbbb-bbbb"]}'
compare new-advisory-on-a-found-package
assert_blocks new-advisory-on-a-found-package
base_repo new-lockfile '{"lockfile":"package-lock.json"}'
commit_findings "$COMPARE_DIR/new-lockfile" '{"lockfile":"sub/package-lock.json"}'
compare new-lockfile
assert_blocks new-lockfile
base_repo new-package '{"package":"lodash"}'
commit_findings "$COMPARE_DIR/new-package" '{"package":"minimist"}'
compare new-package
assert_blocks new-package

# Earliest date in a group of advisories.
base_repo earliest
commit_findings "$COMPARE_DIR/earliest" '{"ids":["GHSA-aaaa-aaaa-aaaa","GHSA-bbbb-bbbb-bbbb"],"published":["2024-01-01T00:00:00Z","2023-01-01T00:00:00Z"]}'
compare earliest
assert_json "$COMPARE_DIR/earliest.json" 'r.findings[0].advisory_published === "2023-01-01T00:00:00Z"'

# One case per lane: the rule does not depend on the ecosystem.
for lane in \
  'npm:package-lock.json:npm' \
  'pnpm:pnpm-lock.yaml:npm' \
  'uv:assistant/uv.lock:PyPI' \
  'go:go.mod:Go'; do
  manager=${lane%%:*}
  rest=${lane#*:}
  lockfile=${rest%%:*}
  ecosystem=${rest#*:}
  finding="{\"lockfile\":\"$lockfile\",\"ecosystem\":\"$ecosystem\",\"package\":\"pkg\",\"version\":\"1.0.0\"}"
  base_repo "lane-$manager-existing" "$finding"
  compare "lane-$manager-existing"
  assert_passes "lane-$manager-existing"
  assert_json "$COMPARE_DIR/lane-$manager-existing.json" 'r.findings[0].status === "existing"'
  base_repo "lane-$manager-new"
  commit_findings "$COMPARE_DIR/lane-$manager-new" "$finding"
  compare "lane-$manager-new"
  assert_blocks "lane-$manager-new"
done

# --base names the ref, and without origin/HEAD origin/main is the fallback.
base_repo explicit-base
commit_findings "$COMPARE_DIR/explicit-base" "$WITH_FIX"
git -C "$COMPARE_DIR/explicit-base" branch release HEAD
compare explicit-base --base release
assert_passes explicit-base
assert_json "$COMPARE_DIR/explicit-base.json" 'r.base.ref === "release" && r.base.compared === true'
base_repo fallback "$WITH_FIX"
git -C "$COMPARE_DIR/fallback" symbolic-ref --delete refs/remotes/origin/HEAD
compare fallback
assert_passes fallback
assert_json "$COMPARE_DIR/fallback.json" 'r.base.ref === "origin/main"'

# The merge base is what counts, not where main has moved to since.
base_repo diverged
git -C "$COMPARE_DIR/diverged" branch feature HEAD
commit_findings "$COMPARE_DIR/diverged" "$WITH_FIX"
git -C "$COMPARE_DIR/diverged" update-ref refs/remotes/origin/main HEAD
git -C "$COMPARE_DIR/diverged" switch -q feature
node "$OSV_JSON" "$WITH_FIX" >"$COMPARE_DIR/diverged/osv-output.json"
git_commit "$COMPARE_DIR/diverged" "the branch's own commit"
compare diverged
assert_blocks diverged

# A subdirectory scan stays a subdirectory, also under a hook's GIT_DIR.
base_repo subdirectory
mkdir "$COMPARE_DIR/subdirectory/app"
rm "$COMPARE_DIR/subdirectory/osv-output.json"
node "$OSV_JSON" "$WITH_FIX" >"$COMPARE_DIR/subdirectory/app/osv-output.json"
git_commit "$COMPARE_DIR/subdirectory" subdirectory
git -C "$COMPARE_DIR/subdirectory" update-ref refs/remotes/origin/main HEAD
COMPARE_ENV=GIT_DIR=.git COMPARE_REPO="$COMPARE_DIR/subdirectory/app" compare subdirectory
assert_passes subdirectory
assert_json "$COMPARE_DIR/subdirectory.json" 'r.base.compared === true && r.findings[0].lockfile === "package-lock.json" && r.findings[0].status === "existing"'

# The base unpacks to a temporary directory that is removed afterwards.
SCRATCH="$COMPARE_DIR/scratch"
mkdir "$SCRATCH"
base_repo scratch-removed "$WITH_FIX"
: >"$OSV_LOG"
COMPARE_ENV=TMPDIR=$SCRATCH compare scratch-removed
assert_passes scratch-removed
assert_contains "$OSV_LOG" "--offline $SCRATCH/ci-cd-vulns-"
test -z "$(ls -A "$SCRATCH")" || fail "vulns must remove the base's temporary directory"

# A base with no lockfiles at all makes everything new.
base_repo no-base-lockfiles
rm "$COMPARE_DIR/no-base-lockfiles/osv-output.json"
git_commit "$COMPARE_DIR/no-base-lockfiles" remove
git -C "$COMPARE_DIR/no-base-lockfiles" update-ref refs/remotes/origin/main HEAD
commit_findings "$COMPARE_DIR/no-base-lockfiles" "$WITH_FIX"
compare no-base-lockfiles
assert_blocks no-base-lockfiles
assert_json "$COMPARE_DIR/no-base-lockfiles.json" 'r.base.compared === true'

# No findings on the branch: nothing to compare, so nothing is unpacked.
base_repo nothing-to-compare "$WITH_FIX"
commit_findings "$COMPARE_DIR/nothing-to-compare"
: >"$OSV_LOG"
compare nothing-to-compare
assert_passes nothing-to-compare
test "$(wc -l <"$OSV_LOG")" -eq 1 || fail "vulns with no findings must scan once"
assert_json "$COMPARE_DIR/nothing-to-compare.json" 'r.status === "clean" && r.base.compared === false && r.base.reason === "no findings to compare"'

# Both sides are judged by the branch's ignore file.
base_repo ignored "$WITH_FIX"
cp "$ROOT/tests/fixtures/vulns-ignored/osv-scanner.toml" "$COMPARE_DIR/ignored/osv-scanner.toml"
commit_findings "$COMPARE_DIR/ignored" "$WITH_FIX"
: >"$OSV_LOG"
compare ignored
assert_passes ignored
test "$(grep -c -- "--config $COMPARE_DIR/ignored/osv-scanner.toml" "$OSV_LOG")" -eq 2 ||
  fail "both scans must take the branch's ignore file"
# An entry that accepts a finding the branch adds is honoured.
base_repo ignore-added
cp "$ROOT/tests/fixtures/vulns-ignored/osv-scanner.toml" "$COMPARE_DIR/ignore-added/osv-scanner.toml"
node "$OSV_JSON" >"$COMPARE_DIR/ignore-added/osv-output.ignored.json"
commit_findings "$COMPARE_DIR/ignore-added" "$WITH_FIX"
compare ignore-added
assert_passes ignore-added
assert_json "$COMPARE_DIR/ignore-added.json" 'r.findings.length === 0'
# A branch that drops the file loses the base's entries on both sides, so a
# finding the base only hid is existing, not new.
base_repo ignore-dropped "$WITH_FIX"
cp "$ROOT/tests/fixtures/vulns-ignored/osv-scanner.toml" "$COMPARE_DIR/ignore-dropped/osv-scanner.toml"
node "$OSV_JSON" >"$COMPARE_DIR/ignore-dropped/osv-output.ignored.json"
git_commit "$COMPARE_DIR/ignore-dropped" ignore
git -C "$COMPARE_DIR/ignore-dropped" update-ref refs/remotes/origin/main HEAD
rm "$COMPARE_DIR/ignore-dropped/osv-scanner.toml"
git_commit "$COMPARE_DIR/ignore-dropped" drop
compare ignore-dropped
assert_passes ignore-dropped
assert_json "$COMPARE_DIR/ignore-dropped.json" 'r.findings[0].status === "existing"'

# A clone of main as the sweep makes it compares. Whether it has origin/HEAD
# depends on the git version; `fallback` above covers its absence.
base_repo shallow-source "$WITH_FIX"
commit_findings "$COMPARE_DIR/shallow-source" "$WITH_FIX"
git clone -q --depth 1 --single-branch "file://$COMPARE_DIR/shallow-source" "$COMPARE_DIR/shallow"
compare shallow
assert_passes shallow
assert_json "$COMPARE_DIR/shallow.json" 'r.base.compared === true && r.findings[0].status === "existing"'

printf 'test: vulns blocks when the base cannot be compared\n'
assert_cannot_compare() {
  assert_blocks "$1"
  assert_contains "$COMPARE_DIR/$1.out" "cannot compare with the base, every finding counts as new: $2"
  assert_json "$COMPARE_DIR/$1.json" 'r.base.compared === false && r.base.reason !== null && r.findings[0].status === "new"'
}
git init -q -b main "$COMPARE_DIR/no-base-ref"
commit_findings "$COMPARE_DIR/no-base-ref" "$WITH_FIX"
compare no-base-ref
assert_cannot_compare no-base-ref "no base ref: origin/HEAD, origin/main not found"

base_repo bad-base "$WITH_FIX"
compare bad-base --base no-such-ref
assert_cannot_compare bad-base "no base ref: no-such-ref not found"

base_repo no-merge-base "$WITH_FIX"
git -C "$COMPARE_DIR/no-merge-base" switch -q --orphan unrelated
node "$OSV_JSON" "$WITH_FIX" >"$COMPARE_DIR/no-merge-base/osv-output.json"
git_commit "$COMPARE_DIR/no-merge-base" "an unrelated root"
compare no-merge-base
assert_cannot_compare no-merge-base "no merge base between HEAD and origin/HEAD"

base_repo unpack-failure "$WITH_FIX"
FAKE_TAR="$COMPARE_DIR/fake-tar"
mkdir "$FAKE_TAR"
printf '#!/bin/sh\necho tar broke >&2\nexit 2\n' >"$FAKE_TAR/tar"
chmod +x "$FAKE_TAR/tar"
COMPARE_PATH="$FAKE_TAR:$OSV_PATH" compare unpack-failure
assert_cannot_compare unpack-failure "could not unpack the base: tar broke"

base_repo base-scan-failure "$WITH_FIX"
SCRATCH_FAIL="$COMPARE_DIR/scratch-fail"
mkdir "$SCRATCH_FAIL"
COMPARE_ENV="TMPDIR=$SCRATCH_FAIL FAKE_OSV_FAIL_UNDER=$SCRATCH_FAIL" compare base-scan-failure
assert_cannot_compare base-scan-failure "vulns: osv-scanner failed (129)"
test -z "$(ls -A "$SCRATCH_FAIL")" || fail "vulns must remove the base's temporary directory after a failure"

printf 'test: gate compares with the base too\n'
base_repo gate-existing "$WITH_FIX"
cp "$ROOT/tests/fixtures/gate-vulns-failing/.ci-cd.json" "$COMPARE_DIR/gate-existing/"
PATH="$OSV_PATH" XDG_CACHE_HOME="$(fresh_cache gate-existing)" "$ROOT/bin/ci" gate \
  --working-directory "$COMPARE_DIR/gate-existing" --target local --platform linux/amd64 >"$COMPARE_DIR/gate-existing.out" 2>&1
assert_contains "$COMPARE_DIR/gate-existing.out" "gate passed"
assert_contains "$COMPARE_DIR/gate-existing.out" "0 new, 1 existing"

base_repo gate-new
cp "$ROOT/tests/fixtures/gate-vulns-failing/.ci-cd.json" "$COMPARE_DIR/gate-new/"
commit_findings "$COMPARE_DIR/gate-new" "$WITH_FIX"
if PATH="$OSV_PATH" XDG_CACHE_HOME="$(fresh_cache gate-new)" "$ROOT/bin/ci" gate \
  --working-directory "$COMPARE_DIR/gate-new" --target local --platform linux/amd64 >"$COMPARE_DIR/gate-new.out" 2>&1; then
  fail "gate must fail on a new high finding"
fi
assert_contains "$COMPARE_DIR/gate-new.out" "gate failed on 'vulns' (1)"

printf 'test: vulns --ages and --fix (fake registry and package managers)\n'
FIX_TOOLS="$ROOT/tests/fixtures/fix-tools"
FIX_PATH="$FIX_TOOLS/bin:$OSV_PATH"
AGE_DIR="$TMP_ROOT/deployment"
mkdir -p "$AGE_DIR"
printf '{ "the_age": "7 days" }\n' >"$AGE_DIR/ages.json"
printf '{ "release_age": { "file": "ages.json", "key": "the_age" }, "gate_on_aged_fix": ["Go"] }\n' >"$AGE_DIR/config.json"
REGISTRY_LOG="$TMP_ROOT/registry.log"
UPGRADE_LOG="$TMP_ROOT/upgrade.log"
AGED_DATE=2021-02-20T00:00:00Z
FUTURE=2099-01-01T00:00:00Z
cat >"$AGE_DIR/registry.json" <<EOF
{
  "https://registry.npmjs.org/lodash": { "time": { "4.17.21": "$AGED_DATE" } },
  "https://registry.npmjs.org/@scope%2Fpkg": { "time": { "2.0.0": "$AGED_DATE" } },
  "https://registry.npmjs.org/young-pkg": { "time": { "4.17.21": "$FUTURE" } },
  "https://pypi.org/pypi/aiohttp/3.14.4/json": { "urls": [{ "upload_time_iso_8601": "$AGED_DATE" }] },
  "https://proxy.golang.org/golang.org/x/net/@v/v0.38.0.info": { "Time": "$AGED_DATE" },
  "https://proxy.golang.org/github.com/!azure/young/@v/v1.1.0.info": { "Time": "$FUTURE" }
}
EOF
FIX_ENV="CI_CD_DEPLOYMENT_CONFIG=$AGE_DIR/config.json NODE_OPTIONS=--import=$FIX_TOOLS/fake-fetch.mjs FAKE_REGISTRY=$AGE_DIR/registry.json FAKE_REGISTRY_LOG=$REGISTRY_LOG FAKE_UPGRADE_LOG=$UPGRADE_LOG"
: >"$REGISTRY_LOG"
: >"$UPGRADE_LOG"
# compare, with the deployment, the fake registry and the fake package managers.
# AGED_ENV adds env words for that one run.
aged() {
  COMPARE_ENV="$FIX_ENV FAKE_SCAN_DIR=$COMPARE_DIR/$1 ${AGED_ENV:-}"
  AGED_ENV=
  COMPARE_PATH=$FIX_PATH
  compare "$@"
}
assert_state() {
  assert_json "$COMPARE_DIR/$1.json" "r.findings[0].fix_state === \"$2\" && r.findings[0].release_age_days === 7"
}
assert_no_registry() {
  test ! -s "$REGISTRY_LOG" || fail "no registry may be called ($1)"
}
assert_no_upgrade() {
  test ! -s "$UPGRADE_LOG" || fail "nothing may be upgraded ($1)"
}
# The scanner's answer after an upgrade: the finding is gone, the package is not.
fixed_result() {
  node "$OSV_JSON" "$@" >"$AGE_DIR/fixed-$FIXED_NAME.json"
  printf '%s' "$AGE_DIR/fixed-$FIXED_NAME.json"
}

# A plain scan and a plain gate ask no registry; --ages reports each state.
base_repo plain "$WITH_FIX"
aged plain
assert_passes plain
assert_no_registry "plain scan"
assert_json "$COMPARE_DIR/plain.json" '!("fix_state" in r.findings[0]) && !("release_age_days" in r.findings[0])'

base_repo state-ready "$WITH_FIX"
aged state-ready --ages
assert_state state-ready ready
assert_contains "$REGISTRY_LOG" "https://registry.npmjs.org/lodash"
assert_contains "$COMPARE_DIR/state-ready.out" "fix_state=ready"
assert_no_upgrade "--ages"

base_repo state-scoped '{"package":"@scope/pkg","version":"1.0.0","fixed":"2.0.0"}'
aged state-scoped --ages
assert_state state-scoped ready

base_repo state-young '{"package":"young-pkg","fixed":"4.17.21"}'
aged state-young --ages
assert_state state-young young

base_repo state-unknown '{"package":"not-in-the-registry","fixed":"4.17.21"}'
aged state-unknown --ages
assert_state state-unknown unknown

base_repo state-watching "{\"published\":\"$FUTURE\"}"
aged state-watching --ages
assert_state state-watching watching

base_repo state-decide "$NO_FIX"
aged state-decide --ages
assert_state state-decide decide

# The fix is the lowest version above the installed one, and a commit is none.
base_repo state-lowest '{"version":"1.0.0","fixed":["0.9.0","1.5.0","4.17.21"]}'
aged state-lowest --ages
assert_state state-lowest unknown
assert_contains "$REGISTRY_LOG" "https://registry.npmjs.org/lodash"
base_repo state-only-below '{"version":"5.0.0","fixed":"4.17.21"}'
aged state-only-below --ages
assert_state state-only-below decide
base_repo state-commit '{"gitFixed":"0123456789abcdef"}'
aged state-commit --ages
assert_state state-commit decide
assert_json "$COMPARE_DIR/state-commit.json" 'r.findings[0].fixed.length === 0'

# The lock file's own setting is missing or differs: no-age, for each manager.
for setting in null 3; do
  base_repo "npm-age-$setting" "$WITH_FIX"
  AGED_ENV="FAKE_NPM_AGE=$setting" aged "npm-age-$setting" --ages
  assert_state "npm-age-$setting" no-age
done
PNPM_FINDING='{"lockfile":"pnpm-lock.yaml"}'
base_repo pnpm-age "{\"lockfile\":\"pnpm-lock.yaml\",\"fixed\":\"4.17.21\"}"
aged pnpm-age --ages
assert_state pnpm-age ready
base_repo pnpm-no-age "{\"lockfile\":\"pnpm-lock.yaml\",\"fixed\":\"4.17.21\"}"
AGED_ENV=FAKE_PNPM_AGE=1440 aged pnpm-no-age --ages
assert_state pnpm-no-age no-age
base_repo pnpm-unset "$PNPM_FINDING"
AGED_ENV=FAKE_PNPM_AGE=undefined aged pnpm-unset --ages
assert_state pnpm-unset no-age

UV_FINDING='{"lockfile":"assistant/uv.lock","ecosystem":"PyPI","package":"aiohttp","version":"3.14.3","fixed":"3.14.4"}'
base_repo uv-none "$UV_FINDING"
aged uv-none --ages
assert_state uv-none no-age
base_repo uv-age "$UV_FINDING"
mkdir "$COMPARE_DIR/uv-age/assistant"
printf 'exclude-newer = "7 days"\n' >"$COMPARE_DIR/uv-age/assistant/uv.toml"
aged uv-age --ages
assert_state uv-age ready
base_repo uv-parent "$UV_FINDING"
printf 'exclude-newer = "7 days"\n' >"$COMPARE_DIR/uv-parent/uv.toml"
aged uv-parent --ages
assert_state uv-parent ready
base_repo uv-differs "$UV_FINDING"
printf 'exclude-newer = "3 days"\n' >"$COMPARE_DIR/uv-differs/uv.toml"
aged uv-differs --ages
assert_state uv-differs no-age
base_repo uv-bad "$UV_FINDING"
printf 'exclude-newer = "2 weeks"\n' >"$COMPARE_DIR/uv-bad/uv.toml"
aged uv-bad --ages
test "$COMPARE_CODE" -eq 1 || fail "a uv value that is not <n> days must fail"
assert_contains "$COMPARE_DIR/uv-bad.out" "must read '<n> days'"
assert_json "$COMPARE_DIR/uv-bad.json" 'r.status === "error"'

# A lock file with no setting to read is no-age; Go never is.
base_repo yarn-lock '{"lockfile":"yarn.lock","fixed":"4.17.21"}'
aged yarn-lock --ages
assert_state yarn-lock no-age
GO_FIX='{"lockfile":"go.mod","ecosystem":"Go","package":"golang.org/x/net","version":"0.37.0","fixed":"0.38.0"}'
GO_YOUNG='{"lockfile":"go.mod","ecosystem":"Go","package":"github.com/Azure/young","version":"1.0.0","fixed":"1.1.0"}'
GO_NO_FIX='{"lockfile":"go.mod","ecosystem":"Go","package":"golang.org/x/net","version":"0.37.0"}'
GO_UNKNOWN='{"lockfile":"go.mod","ecosystem":"Go","package":"golang.org/x/text","version":"0.1.0","fixed":"0.2.0"}'
base_repo go-young "$GO_YOUNG"
aged go-young --ages
assert_state go-young young

printf 'test: the deployment config\n'
# The operator's shell may set the real deployment config; this case needs none.
unset CI_CD_DEPLOYMENT_CONFIG
base_repo no-config "$WITH_FIX"
COMPARE_PATH=$FIX_PATH compare no-config --ages
test "$COMPARE_CODE" -eq 1 || fail "--ages without a deployment config must fail"
assert_contains "$COMPARE_DIR/no-config.out" "--ages needs a release age: set CI_CD_DEPLOYMENT_CONFIG"
assert_json "$COMPARE_DIR/no-config.json" 'r.status === "error"'
COMPARE_PATH=$FIX_PATH compare no-config --fix
test "$COMPARE_CODE" -eq 1 || fail "--fix without a deployment config must fail"
assert_contains "$COMPARE_DIR/no-config.out" "--fix needs a release age"

printf '{ "the_age": "a week" }\n' >"$AGE_DIR/bad-ages.json"
printf '{ "release_age": { "file": "bad-ages.json", "key": "the_age" } }\n' >"$AGE_DIR/bad-config.json"
base_repo bad-age "$WITH_FIX"
AGED_ENV="CI_CD_DEPLOYMENT_CONFIG=$AGE_DIR/bad-config.json" aged bad-age --ages
test "$COMPARE_CODE" -eq 1 || fail "an age that is not <n> days must fail"
assert_contains "$COMPARE_DIR/bad-age.out" "the_age in $AGE_DIR/bad-ages.json must read '<n> days'"
printf '{ "release_age": { "file": "ages.json" } }\n' >"$AGE_DIR/no-key.json"
AGED_ENV="CI_CD_DEPLOYMENT_CONFIG=$AGE_DIR/no-key.json" aged bad-age --ages
assert_contains "$COMPARE_DIR/bad-age.out" "release_age needs a file and a key"
AGED_ENV="CI_CD_DEPLOYMENT_CONFIG=$AGE_DIR/missing.json" aged bad-age --ages
assert_contains "$COMPARE_DIR/bad-age.out" "cannot read deployment config"

printf 'test: vulns --fix upgrades what is ready\n'
FIXED_NAME=npm
AGED_ENV="FAKE_UPGRADE_RESULT=$(fixed_result '{"version":"4.17.21","clean":true}')"
base_repo fix-npm "$WITH_FIX"
aged fix-npm --fix
test "$COMPARE_CODE" -eq 0 || fail "--fix must exit 0 when the finding goes"
assert_contains "$UPGRADE_LOG" "npm update lodash --package-lock-only (in $COMPARE_DIR/fix-npm)"
assert_contains "$OSV_LOG" "--all-packages"
assert_contains "$COMPARE_DIR/fix-npm.out" "fixed lodash 4.17.15 → 4.17.21 (package-lock.json)"
assert_json "$COMPARE_DIR/fix-npm.json" 'r.schema === "ci-cd-vulns/v1" && r.findings.length === 0 && r.fixes[0].outcome === "fixed" && r.fixes[0].to === "4.17.21"'

FIXED_NAME=pnpm
AGED_ENV="FAKE_UPGRADE_RESULT=$(fixed_result '{"lockfile":"pnpm-lock.yaml","version":"4.17.21","clean":true}')"
base_repo fix-pnpm '{"lockfile":"pnpm-lock.yaml","fixed":"4.17.21"}'
aged fix-pnpm --fix
test "$COMPARE_CODE" -eq 0 || fail "--fix must fix a pnpm finding"
assert_contains "$UPGRADE_LOG" "pnpm update lodash --lockfile-only --no-save (in $COMPARE_DIR/fix-pnpm)"

FIXED_NAME=uv
AGED_ENV="FAKE_UPGRADE_RESULT=$(fixed_result '{"lockfile":"assistant/uv.lock","ecosystem":"PyPI","package":"aiohttp","version":"3.14.4","clean":true}')"
base_repo fix-uv "$UV_FINDING"
printf 'exclude-newer = "7 days"\n' >"$COMPARE_DIR/fix-uv/uv.toml"
mkdir "$COMPARE_DIR/fix-uv/assistant"
aged fix-uv --fix
test "$COMPARE_CODE" -eq 0 || fail "--fix must fix a uv finding"
assert_contains "$UPGRADE_LOG" "uv lock --upgrade-package aiohttp (in $COMPARE_DIR/fix-uv/assistant)"
assert_contains "$COMPARE_DIR/fix-uv.out" "fixed aiohttp 3.14.3 → 3.14.4 (assistant/uv.lock)"

# Nothing ready: exit 0, nothing changes, each finding is reported.
for case in \
  'young:{"package":"young-pkg","fixed":"4.17.21"}' \
  "watching:{\"published\":\"$FUTURE\"}" \
  "decide:$NO_FIX" \
  'unknown:{"package":"young-pkg-gone","fixed":"4.17.21"}'; do
  state=${case%%:*}
  : >"$UPGRADE_LOG"
  base_repo "wait-$state" "${case#*:}"
  aged "wait-$state" --fix
  assert_no_upgrade "$state"
  test "$COMPARE_CODE" -eq 0 || fail "--fix with a $state finding must exit 0"
  assert_contains "$COMPARE_DIR/wait-$state.out" "waiting "
  assert_contains "$COMPARE_DIR/wait-$state.out" " $state"
  assert_json "$COMPARE_DIR/wait-$state.json" "r.fixes[0].outcome === \"waiting\" && r.fixes[0].fix_state === \"$state\""
done
base_repo wait-no-age "$WITH_FIX"
AGED_ENV=FAKE_NPM_AGE=null aged wait-no-age --fix
assert_no_upgrade no-age
test "$COMPARE_CODE" -eq 0 || fail "--fix with a no-age finding must exit 0"
assert_contains "$COMPARE_DIR/wait-no-age.out" "waiting lodash no-age"

# Below fail_on is left alone, and --fail-on moves that line.
base_repo below-fail-on '{"score":"5.3","fixed":"4.17.21"}'
aged below-fail-on --fix
assert_no_upgrade "below fail_on"
assert_contains "$COMPARE_DIR/below-fail-on.out" "waiting lodash ready"
FIXED_NAME=medium
AGED_ENV="FAKE_UPGRADE_RESULT=$(fixed_result '{"version":"4.17.21","clean":true}')"
base_repo fail-on-medium '{"score":"5.3","fixed":"4.17.21"}'
aged fail-on-medium --fix --fail-on medium
assert_contains "$UPGRADE_LOG" "npm update lodash --package-lock-only (in $COMPARE_DIR/fail-on-medium)"
: >"$UPGRADE_LOG"

# A package being upgraded is listed once, whatever its lesser advisories say.
FIXED_NAME=lesser
AGED_ENV="FAKE_UPGRADE_RESULT=$(fixed_result '{"version":"4.17.21","clean":true}')"
base_repo fix-lesser "$WITH_FIX" '{"ids":["GHSA-bbbb-bbbb-bbbb"],"score":"5.3","fixed":"4.17.21"}'
aged fix-lesser --fix
assert_json "$COMPARE_DIR/fix-lesser.json" 'r.fixes.length === 1 && r.fixes[0].outcome === "fixed"'

# Clean: nothing to do.
base_repo fix-clean
aged fix-clean --fix
test "$COMPARE_CODE" -eq 0 || fail "--fix on a clean repo must exit 0"
assert_contains "$COMPARE_DIR/fix-clean.out" "nothing to fix"

# A scan that never ran says nothing was fixed; bl would close the story as "no change needed".
printf 'test: vulns --fix fails when the scan was skipped\n'
base_repo fix-skipped "$WITH_FIX"
AGED_ENV="FAKE_OSV_DOWNLOAD_FAIL=1 FAKE_OSV_NO_DB=1" aged fix-skipped --fix
test "$COMPARE_CODE" -eq 1 || fail "--fix must fail when the scan was skipped"
assert_contains "$COMPARE_DIR/fix-skipped.out" "the scan did not run"

# An upgrade that leaves the finding, or a package the manifest holds, fails it.
base_repo fix-left "$WITH_FIX"
aged fix-left --fix
test "$COMPARE_CODE" -eq 1 || fail "--fix must fail when the finding stays"
assert_contains "$COMPARE_DIR/fix-left.out" "failed lodash"
assert_json "$COMPARE_DIR/fix-left.json" 'r.fixes[0].outcome === "failed" && r.findings.length === 1'

base_repo fix-other-version "$WITH_FIX"
FIXED_NAME=still
AGED_ENV="FAKE_UPGRADE_RESULT=$(fixed_result '{"version":"4.17.16","fixed":"4.17.21"}')"
printf '{ "dependencies": { "lodash": "^4.17.15" } }\n' >"$COMPARE_DIR/fix-other-version/package.json"
aged fix-other-version --fix
test "$COMPARE_CODE" -eq 1 || fail "--fix must fail when a lower version moved but stays vulnerable"
assert_contains "$COMPARE_DIR/fix-other-version.out" "failed lodash"

base_repo fix-failed "$WITH_FIX"
AGED_ENV=FAKE_UPGRADE_FAIL=1 aged fix-failed --fix
test "$COMPARE_CODE" -eq 1 || fail "--fix must fail when the upgrade fails"
assert_contains "$COMPARE_DIR/fix-failed.out" "fake upgrade failure"
assert_contains "$COMPARE_DIR/fix-failed.out" "failed lodash"

base_repo fix-pinned "$WITH_FIX"
printf '{ "dependencies": { "lodash": "4.17.15" } }\n' >"$COMPARE_DIR/fix-pinned/package.json"
aged fix-pinned --fix
test "$COMPARE_CODE" -eq 1 || fail "--fix must fail on a pinned package"
assert_contains "$COMPARE_DIR/fix-pinned.out" "lodash pinned in package.json"
assert_json "$COMPARE_DIR/fix-pinned.json" 'r.fixes[0].outcome === "pinned" && r.fixes[0].manifest === "package.json"'

base_repo fix-uv-pinned "$UV_FINDING"
mkdir "$COMPARE_DIR/fix-uv-pinned/assistant"
printf 'exclude-newer = "7 days"\n' >"$COMPARE_DIR/fix-uv-pinned/uv.toml"
cat >"$COMPARE_DIR/fix-uv-pinned/assistant/uv.lock" <<'EOF'
[[package]]
name = "assistant"
version = "0.1.0"
source = { virtual = "." }
dependencies = [{ name = "aiohttp" }]
EOF
aged fix-uv-pinned --fix
test "$COMPARE_CODE" -eq 1 || fail "--fix must fail on a pinned uv package"
assert_contains "$COMPARE_DIR/fix-uv-pinned.out" "aiohttp pinned in pyproject.toml"

# --lockfile scopes both the upgrades and the report; the manifest is untouched.
: >"$UPGRADE_LOG"
FIXED_NAME=scope
AGED_ENV="FAKE_UPGRADE_RESULT=$(fixed_result '{"lockfile":"a/package-lock.json","fixed":"4.17.21"}' '{"lockfile":"b/package-lock.json","version":"4.17.21","clean":true}')"
base_repo fix-scope '{"lockfile":"a/package-lock.json","fixed":"4.17.21"}' '{"lockfile":"b/package-lock.json","fixed":"4.17.21"}'
mkdir "$COMPARE_DIR/fix-scope/a" "$COMPARE_DIR/fix-scope/b"
printf '{ "dependencies": {} }\n' >"$COMPARE_DIR/fix-scope/b/package.json"
aged fix-scope --fix --lockfile b/package-lock.json
test "$COMPARE_CODE" -eq 0 || fail "--fix --lockfile must fix that lock file"
assert_contains "$UPGRADE_LOG" "(in $COMPARE_DIR/fix-scope/b)"
if grep -q "fix-scope/a)" "$UPGRADE_LOG"; then
  fail "--fix --lockfile must leave other lock files alone"
fi
assert_contains "$COMPARE_DIR/fix-scope.out" "fixed lodash 4.17.15 → 4.17.21 (b/package-lock.json)"
assert_json "$COMPARE_DIR/fix-scope.json" 'r.fixes.length === 1 && r.findings.length === 1'
if run_vulns vulns-medium "$(fresh_cache lockfile-alone)" --lockfile a >/tmp/ci-cd-vulns-lockfile.out 2>&1; then
  fail "--lockfile without --fix must fail"
fi
assert_contains /tmp/ci-cd-vulns-lockfile.out "--lockfile needs --fix"

printf 'test: gate holds a gate_on_aged_fix ecosystem to the age\n'
GATE_CONFIG="$ROOT/tests/fixtures/gate-vulns-failing/.ci-cd.json"
# Runs the gate on a repo; sets COMPARE_CODE, output in $name.out.
gate_aged() {
  name=$1
  shift
  cp "$GATE_CONFIG" "$COMPARE_DIR/$name/"
  set +e
  env "$@" PATH="$FIX_PATH" XDG_CACHE_HOME="$(fresh_cache "gate-$name")" "$ROOT/bin/ci" gate \
    --working-directory "$COMPARE_DIR/$name" --target local --platform linux/amd64 >"$COMPARE_DIR/$name.out" 2>&1
  COMPARE_CODE=$?
  set -e
}

base_repo overdue "$GO_FIX"
gate_aged overdue $FIX_ENV
test "$COMPARE_CODE" -eq 1 || fail "gate must block an overdue finding"
assert_contains "$COMPARE_DIR/overdue.out" "1 overdue finding(s), with a fix at least 7 days old"
assert_contains "$COMPARE_DIR/overdue.out" "gate failed on 'vulns' (1)"
assert_contains "$COMPARE_DIR/overdue.out" "0 new, 1 existing"
assert_contains "$REGISTRY_LOG" "https://proxy.golang.org/golang.org/x/net/@v/v0.38.0.info"
if grep -q "new finding(s)" "$COMPARE_DIR/overdue.out"; then
  fail "an overdue finding is its own group"
fi

aged overdue --ages
assert_blocks overdue
assert_state overdue overdue

: >"$REGISTRY_LOG"
for case in "young:$GO_YOUNG" "no-fix:$GO_NO_FIX" "lookup-failed:$GO_UNKNOWN"; do
  kind=${case%%:*}
  base_repo "overdue-$kind" "${case#*:}"
  gate_aged "overdue-$kind" $FIX_ENV
  test "$COMPARE_CODE" -eq 0 || fail "gate must pass an existing Go finding ($kind)"
  assert_contains "$COMPARE_DIR/overdue-$kind.out" "gate passed"
done

# An overdue finding below fail_on is not one.
base_repo overdue-medium '{"lockfile":"go.mod","ecosystem":"Go","package":"golang.org/x/net","version":"0.37.0","fixed":"0.38.0","score":"5.3"}'
gate_aged overdue-medium $FIX_ENV
test "$COMPARE_CODE" -eq 0 || fail "gate must pass a finding below fail_on"
aged overdue-medium --ages
assert_state overdue-medium ready

# A branch that removes a finding the base has passes; a new finding still blocks.
base_repo overdue-removes "$GO_FIX" "$GO_YOUNG"
commit_findings "$COMPARE_DIR/overdue-removes" "$GO_FIX"
gate_aged overdue-removes $FIX_ENV
test "$COMPARE_CODE" -eq 0 || fail "gate must pass a branch that removes a finding"
assert_contains "$COMPARE_DIR/overdue-removes.out" "gate passed"
aged overdue-removes --ages
assert_contains "$COMPARE_DIR/overdue-removes.out" "this branch removes a finding the base has"
assert_passes overdue-removes

base_repo overdue-removes-adds "$GO_FIX" "$GO_YOUNG"
commit_findings "$COMPARE_DIR/overdue-removes-adds" "$GO_FIX" '{"lockfile":"go.mod","ecosystem":"Go","package":"golang.org/x/added","version":"1.0.0"}'
gate_aged overdue-removes-adds $FIX_ENV
test "$COMPARE_CODE" -eq 1 || fail "gate must still block what a branch adds"

# No deployment config: the gate is as it was, and asks no registry.
: >"$REGISTRY_LOG"
base_repo overdue-no-config "$GO_FIX"
gate_aged overdue-no-config FAKE_REGISTRY_LOG="$REGISTRY_LOG"
test "$COMPARE_CODE" -eq 0 || fail "gate without a deployment config must pass an existing finding"
assert_no_registry "gate without a deployment config"

# An ecosystem the deployment does not list asks no registry at the gate.
base_repo gate-npm "$WITH_FIX"
gate_aged gate-npm $FIX_ENV
test "$COMPARE_CODE" -eq 0 || fail "gate must pass an existing npm finding"
assert_no_registry "gate on an unlisted ecosystem"

# --fix leaves overdue findings to whatever updates that ecosystem.
: >"$UPGRADE_LOG"
base_repo overdue-fix "$GO_FIX"
aged overdue-fix --fix
assert_no_upgrade overdue
test "$COMPARE_CODE" -eq 0 || fail "--fix must not fail on an overdue finding"
assert_contains "$COMPARE_DIR/overdue-fix.out" "waiting golang.org/x/net overdue"

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
