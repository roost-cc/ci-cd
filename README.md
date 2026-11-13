# ci-cd

`ci-cd` is the shared automation layer for software lifecycle work: format,
lint, test, build, package, release, deploy, and stack operations.

It is intentionally application-agnostic. This repo should not know about
any one organization, product, workspace layout, repository topology, service,
or forge/CI provider. Repositories describe their own lifecycle in config;
`ci-cd` validates that config and executes it consistently from local shells,
package scripts, Makefiles, hosted CI, manual deploys, and agent workflows.

## Principles

- `ci-cd` owns reusable automation behavior.
- Application repos own declarative configuration.
- Local scripts should be thin wrappers around `ci-cd`.
- Hosted CI files should be thin shims around `ci-cd`.
- Agents and tools such as `bl` should call the same runner humans use.
- Provider-specific details belong in runner shims, not core runner logic.
- App-specific details belong in repo config, not this repo.

## Target Shape

The primary interface is a portable runner:

```sh
bin/ci run <action> \
  --config .ci-cd.json \
  --target local \
  --platform linux/amd64
```

Expected actions include:

- `format`
- `lint`
- `test`
- `build`
- `package`
- `release`
- `deploy`
- `stack`

Repos may also define custom actions when needed, but the common lifecycle
names above should remain stable so humans, CI systems, and agents can share
one vocabulary.

## Consumer Config

Consumer repos should provide a `.ci-cd.json` file that declares the lifecycle
actions available for that repo.

Example shape:

```json
{
  "version": 1,
  "project": {
    "name": "example-service"
  },
  "languages": ["node"],
  "use_toolchains": ["node:pnpm"],
  "targets": {
    "local": {},
    "ci": {},
    "staging": {},
    "production": {}
  },
  "platforms": ["linux/amd64"],
  "actions": {
    "test": {
      "commands": ["pnpm test"],
      "artifacts": ["coverage/"]
    },
    "build": {
      "commands": ["pnpm build"],
      "artifacts": ["dist/"]
    },
    "deploy": {
      "target_required": true,
      "commands": ["./scripts/deploy.sh ${CI_TARGET}"]
    }
  }
}
```

The config is the source of truth. The runner provides language-aware
toolchain profiles for Node, Python, Go, and other ecosystems. Profiles are
auto-detected by default from durable marker files, and explicit config always
wins: `actions` overrides selected profiles, `use_toolchains` overrides
detection order, and `auto_detect_toolchains: false` disables detection for
pure-explicit repos. Auto-detection is a convenience for choosing a default
profile; it must not silently decide how an application deploys — no built-in
profile contributes a `deploy`, `stack`, or `release` action, so those remain
explicit-config-only.

The v1 schema lives at `schema/ci-cd.schema.json`. It supports:

- `version`: currently `1`.
- `project.name`: human-readable project name for logs.
- `languages[]`: optional declared helper languages: `node`, `typescript`,
  `python`, and `go`.
- `use_toolchains[]`: optional toolchain profiles to apply before explicit
  action definitions. Built-ins include `node:pnpm`, `node:yarn`, `node:bun`,
  `node:npm`, `python:uv-ruff-pytest`, and `go:standard`.
- `auto_detect_toolchains`: defaults to `true`. Detects profiles from durable
  files such as lockfiles, `package.json`, `pyproject.toml`, and `go.mod`. Set
  `false` to disable detection; a config with detection disabled and neither
  `actions` nor `use_toolchains` is inert and fails validation.
- `toolchains`: optional repo-defined profiles. These can replace built-ins by
  name or define project/org-specific defaults.
- `targets`: named execution targets such as `local`, `ci`, `staging`, and
  `production`.
- `platforms`: supported runtime/build platforms such as `linux/amd64` and
  `linux/arm64`.
- `actions`: lifecycle action definitions for `format`, `lint`, `typecheck`,
  `test`, `build`, `package`, `release`, `deploy`, and `stack`. Custom actions
  must set `custom: true`.
- Per-action `commands[]`, `env`, `working_directory`, `artifacts`,
  `required_tools`, `required_env`, `skip_if_missing`, and `target_required`.
- Per-action `helpers` for opt-in language commands.
- `vulns`: optional; opts `bin/ci gate` into the lockfile vulnerability scan.
  `vulns.fail_on` (`critical`, `high`, `medium` or `low`; default `high`)
  sets the threshold. See [Vulnerability Scan](#vulnerability-scan).
- `promotion`: optional; `pre-push-gate` or `check-record`. See
  [Promotion](#promotion-the-gate-or-the-check-record).

Action precedence is:

```text
explicit actions.<name>
  > selected toolchain profile action
  > auto-detected profile action
  > no-targets warning (standard action) or actionable error (unknown action)
```

Validation happens before execution. The runner fails with actionable messages
for malformed JSON, unsupported schema versions, unknown actions, unknown
toolchain names, unknown targets, unknown platforms, missing required tools,
missing required environment variables, empty action command plans,
deploy/stack actions without an explicit target, and missing declared
artifacts.

An action miss is split on vocabulary versus targets. An action name outside
the known vocabulary — the standard lifecycle names plus anything defined by
config `actions` or an available toolchain — is a hard `Unknown action` error.
A known action that resolved to nothing (nothing detected, nothing configured)
degrades to a single `ci-cd: no <action> targets found` warning on stderr and
exit 0, so gates such as pre-push hooks pass on repos that legitimately have no
code yet and start running for real the moment a marker file like
`package.json`, `pyproject.toml`, or `go.mod` appears. Explicit-configuration
failures stay hard errors: a typo'd `use_toolchains` name or a resolved action
with missing tools never silently passes a gate.

## Commands

```sh
bin/ci validate --config .ci-cd.json
bin/ci list-actions --config .ci-cd.json
bin/ci explain test --config .ci-cd.json
bin/ci run test --config .ci-cd.json --target ci --platform linux/amd64
bin/ci gate --config .ci-cd.json --target local --platform linux/amd64
bin/ci check HEAD --target local --platform linux/amd64
bin/ci vulns --working-directory . --fail-on high
```

`gate` is the pre-push gate entry point. It runs the fast subset of the
lifecycle — `lint`, `typecheck`, and `test`, in that order — restricted to the
actions the repo _explicitly declares_ in `.ci-cd.json`. `format` is excluded
(it mutates files; a gate checks) and `build`, `package`, `release`, `deploy`,
and `stack` are excluded (too slow or the wrong stage for pre-push). It keys off
declared actions only, never auto-detected toolchain actions, so a
detected-but-unwired command (for example a `node:npm` `lint` inferred from a
`package.json` with no `lint` script) can never break the gate. A repo that
declares none of `lint`/`typecheck`/`test` gets a single
`ci-cd: no gate actions declared` notice and exit 0; a repo that declares only
`test` gets a test gate; one that declares `lint` and `test` gets both. The gate
runs each declared action in order and stops at the first failure, exiting with
that action's exit code. When the config has a top-level `vulns` block, the
gate then runs `vulns` (see [Vulnerability Scan](#vulnerability-scan)). This is
what the shared pre-push hook invokes, so no action name is hardcoded in the
scaffold.

A `gate` that fails leaves a record of the run, so the process that ran
`git push` can read why without parsing the hook's output. It writes the record
and the log where `check` does (see [Checking One Commit](#checking-one-commit)),
with `"by": "gate"`, for the pushed commit (`PRE_COMMIT_TO_REF`) when a push
runs it (`PRE_COMMIT_REMOTE_BRANCH` is set), else for `HEAD`. A refused push to
`main` is a failure too (see [Promotion](#promotion-the-gate-or-the-check-record)).
A reader takes a record as its push's only when its `started` is not before
the push began: the hook can fail before `gate` writes. `gate` writes nothing:

- when it passes, or is interrupted;
- over a record that `check` wrote (`by` is `check`, or absent). It then
  prints `ci-cd: gate failed; the check record of <commit> stays (ci check wrote it): <path>`;
- when git cannot name the commit or the git common directory (not a git
  checkout, `PRE_COMMIT_TO_REF` unset or unknown, a git timeout). It then
  prints `ci-cd: gate wrote no record: <git's message>`;
- when the record cannot be written (for example a read-only `.git`). It then
  prints `ci-cd: gate wrote no record: <the error>`, and exits with the gate's
  own exit code.

It replaces an older `gate` record of the commit, and a file there that is not
a JSON object. In a git checkout, its steps run as `check`'s do: in their own process
group, with their output piped through `gate` into the log and no stdin. A tool
that colours its output only for a terminal then prints no colour.

`check <commit>` runs the same steps as `gate` on exactly one commit. See
[Checking One Commit](#checking-one-commit).

`vulns` scans the checkout's lockfiles for known vulnerabilities with
osv-scanner and fails on what the branch introduces. It needs no `.ci-cd.json`;
see
[Vulnerability Scan](#vulnerability-scan).

`--working-directory` points at the consumer repo root when invoking `ci-cd`
from another checkout location. Relative config paths, action
`working_directory` values, and artifact paths are resolved from that consumer
root.

## Checking One Commit

```sh
bin/ci check <commit> [--target <name>] [--platform <name>] [--working-directory <clone>]
```

`check` runs the gate steps on one commit, outside any git operation. In order:

1. It resolves `<commit>` (any name git accepts, such as `HEAD` or a branch) to
   its 40-character ID.
2. It adds a throwaway worktree, detached at the commit, in a new directory
   under the system temp directory (`TMPDIR`). The worktree directory has the
   same name as the clone's directory.
3. It runs the steps of `gate` there: the `lint`, `typecheck` and `test`
   actions that the commit's own `.ci-cd.json` declares, then `vulns` if the
   commit declares a `vulns` block. Uncommitted and untracked files of the
   clone are not in the worktree, so they never change the result.
4. It writes the check record and the log, then removes the worktree,
   whatever happened. It exits 0 only when every step passed.

The check record is `<git-common-dir>/ci-cd/checks/<commit>.json`, for
example `.git/ci-cd/checks/<commit>.json` in an ordinary clone:

```json
{
  "commit": "<40 hex>",
  "tree": "<40 hex>",
  "by": "check",
  "verdict": "fail",
  "steps": ["lint", "test"],
  "started": "2026-11-10T09:00:00.000Z",
  "finished": "2026-11-10T09:07:00.000Z",
  "exit_code": 1,
  "error": null,
  "vulns": null
}
```

- `by` names the command that wrote the record: `check`, or `gate` (see
  [Commands](#commands)). A record from before `by` has none, and counts as
  `check`.
- `verdict` is `pass` or `fail`. A failed check also writes a record, with
  `fail`.
- `steps` names the steps that started, in order. A check that stops at
  `test` lists `test` last.
- `exit_code` is `null` on a pass, else the exit code of the run: the failed
  step's, or the one ci-cd exits with when it threw.
- `error` is the message of the error that stopped the run when ci-cd threw
  one (an invalid `.ci-cd.json`, a missing tool, a missing `osv-scanner`), else
  `null`. A step that exits non-zero leaves it `null`. When `error` is set,
  `steps` may be empty.
- `vulns` is the `ci-cd-vulns/v1` report of the `vulns` step when it ran (see
  [Vulnerability Scan](#vulnerability-scan)), else `null`. When that step
  threw, the report has `status: "error"`.
- `<commit>.log`, beside the record, holds everything the check printed.
- A check that cannot run fails closed: an invalid or malformed
  `.ci-cd.json`, a missing tool and a step that crashes each exit non-zero
  and write a `fail` record. An unknown commit exits non-zero and writes no
  record.
- An interrupted check (`SIGINT`, `SIGTERM` or `SIGHUP`) removes its worktree
  and writes no record. An older record of the same commit stays.

Linked worktrees of a clone share its git common directory, so a check run
from one worktree is found from every other. A check can take minutes: start
it in another terminal, do other work, and read the record and the log when it
is done.

### Promotion: the gate or the check record

The `.ci-cd.json` key `promotion` says how a commit reaches `main`, and so
what `gate` does in the pre-push hook. The hook entry is the same in every
repo.

- `"pre-push-gate"`: `gate` runs the full gate, as it always did.
- `"check-record"`: a push to `refs/heads/main` passes only when the check
  record of the pushed commit (`PRE_COMMIT_TO_REF`) has that `commit`, the
  verdict `pass`, and a `by` that is `check` or absent: only a record that
  `check` wrote promotes. Otherwise `gate` refuses the push with one line that
  names `ci check <commit>`: run it, then push again. A missing or unparsable
  record, a `fail` record, a record of another commit, a record that `gate`
  wrote and an unset `PRE_COMMIT_TO_REF` each refuse. A refusal is a failed
  gate, so `gate` records it: `steps` is empty, `exit_code` is 1 and `error`
  is the refusal line. Every git command of the lookup has a
  10-second timeout, and a timeout refuses. A push to any other branch runs no
  check. Without `PRE_COMMIT_REMOTE_BRANCH`, `gate` was not started by a push
  (a person, or `pre-commit run --hook-stage pre-push --all-files`), so it
  runs the full gate.
- No key: the full gate runs, and `gate` prints the warning
  `ci-cd: .ci-cd.json sets no "promotion"; the full gate runs in the hook (E70 R11)`.

pre-commit gives a pre-push hook only the first ref of a push, so a push of
several refs at once can carry a commit to `main` past the check.

## Vulnerability Scan

```sh
bin/ci vulns [--working-directory <dir>] [--fail-on critical|high|medium|low] [--base <ref>] [--json <path>] [--ages]
bin/ci vulns --fix [--lockfile <path>] [--working-directory <dir>] [--fail-on critical|high|medium|low] [--base <ref>] [--json <path>]
```

`vulns` scans every lockfile in a checkout, transitive dependencies included
(`package-lock.json`, `pnpm-lock.yaml`, `uv.lock`, `go.mod`, and the rest that
[osv-scanner](https://google.github.io/osv-scanner/) reads), against a locally
cached copy of the OSV database. It runs
`osv-scanner scan source -r --format json [--config <dir>/osv-scanner.toml] <dir>`
with the offline flags below. Recursive scans respect `.gitignore`, so
`node_modules/` lockfiles are skipped.

It works **with or without** a `.ci-cd.json`, so any checkout can be scanned.
When the config has a top-level `vulns` block, `bin/ci gate` runs the scan after
the declared `lint`/`typecheck`/`test` actions; without the block the gate is
unchanged:

```json
{
  "vulns": { "fail_on": "high" }
}
```

**Threshold.** A finding's severity comes from its group's `max_severity` (a
CVSS base score): `critical` is 9.0 and up, `high` 7.0 and up, `medium` 4.0 and
up, `low` above 0. A finding with **no** score counts as `high`, so it fails the
default gate until someone triages it. `new` findings at or above the threshold
fail the scan, one line each (lockfile, package, version, OSV/GHSA/CVE IDs,
severity, fixed versions if known, advisory date). `new` findings below it print
under a "reported, not blocking" heading. The threshold is `--fail-on`, else
`vulns.fail_on` from the config, else `high`.

**Only what the branch introduces blocks.** When there are findings, the scan
also runs on the merge base of `HEAD` and `--base <ref>`, else `origin/HEAD`,
else `origin/main`, unpacked with `git archive` to a temporary directory, with
the branch's `osv-scanner.toml` and the same OSV database. A finding is
`existing` when the base has that lockfile and package and shares an advisory ID
with it; the version does not count, so moving between two versions under one
advisory adds nothing. Anything else is `new`, whether or not a fix exists. An
`existing` finding never blocks, at any severity: it prints in a group of its
own and the summary counts `new` and `existing`. It needs no ignore entry. If the
base cannot be compared (not a git checkout, no base ref, no merge base, a failed
archive or scan), the scan logs why, every finding counts as `new`, and the scan
blocks as if there were no base.

**Accepted findings** live in one `osv-scanner.toml` at the repo root, as
osv-scanner `[[IgnoredVulns]]` entries:

```toml
[[IgnoredVulns]]
id = "GHSA-xxxx-xxxx-xxxx"
ignoreUntil = 2026-12-31
reason = "Dev-only dependency; no fix released yet."
```

The file is passed with `--config`, so it covers every lockfile in the checkout
(an `osv-scanner.toml` found on its own only covers lockfiles in its own
directory). `vulns` refuses an entry without a `reason` or an `ignoreUntil`
(exit 2). Once an entry's `ignoreUntil` passes, osv-scanner stops applying it
and the finding comes back.

**Database cache.** The OSV database lives in
`${XDG_CACHE_HOME:-$HOME/.cache}/ci-cd/osv` (passed to osv-scanner as
`OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY`), with a `last-download` stamp file. When
the last successful download is more than 24 h old, the scan runs with
`--offline-vulnerabilities --download-offline-databases` and refreshes the
stamp; otherwise it runs with `--offline` and makes no network calls (an
ecosystem with no local database yet is downloaded on first sight). If the
refresh fails and a database exists, it warns
`ci-cd: vulns: OSV database is <N>h old (refresh failed)` and scans offline. If
there is no database and the download fails, it warns
`ci-cd: vulns: skipped, no OSV database` and exits 0.

**Tool.** `osv-scanner` 2.x must be on `PATH`. A missing binary is a hard
error, never a silent pass. Install it with
`go install github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.6.0`, or take a
release binary from https://github.com/google/osv-scanner/releases.

**Machine-readable result.** With `--json <path>`, `vulns` also writes one
JSON result to `<path>` on **every** outcome, errors included; the text output
and exit codes are unchanged. A relative path is resolved from the caller's
current directory, not from `--working-directory`, and its parent directory
must exist (otherwise `vulns` exits 1 before scanning). `bin/ci gate` and
`bin/ci check` carry the same result in their record's `vulns` (see
[Checking One Commit](#checking-one-commit)). There, `fix_state` appears only on
findings whose fix state can decide the gate (see
[Fixing findings](#fixing-findings)).

```json
{
  "schema": "ci-cd-vulns/v1",
  "status": "findings",
  "fail_on": "high",
  "scanned_at": "2026-10-02T06:00:00.000Z",
  "db_refreshed": false,
  "db_age_hours": 3,
  "base": {
    "ref": "origin/HEAD",
    "commit": "5fbe7b0c1a2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f",
    "compared": true,
    "reason": null
  },
  "findings": [
    {
      "lockfile": "sub/package-lock.json",
      "package": "lodash",
      "version": "4.17.15",
      "ecosystem": "npm",
      "ids": ["GHSA-35jh-r3h4-6jhm", "CVE-2021-23337"],
      "max_severity": "8.1",
      "severity": "high",
      "status": "new",
      "at_fail_on": true,
      "blocking": true,
      "fixed": ["4.17.21"],
      "advisory_published": "2021-02-15T13:15:00Z"
    }
  ],
  "error": null
}
```

| `status`       | Meaning                                                                                                               | Exit |
| -------------- | --------------------------------------------------------------------------------------------------------------------- | ---- |
| `clean`        | No finding at or above the threshold (`findings` may list non-blocking ones)                                          | 0    |
| `findings`     | At least one finding at or above the threshold, `new` or `existing`; exit 1 only when one is `blocking`               | 0/1  |
| `no-lockfiles` | osv-scanner found nothing to scan                                                                                     | 0    |
| `skipped`      | No OSV database and the download failed; `error` says so                                                              | 0    |
| `error`        | osv-scanner missing, wrong version or failed; unparsable output; bad config or ignore file; `error` holds the message | 1/2  |

`fail_on` is the effective threshold (`null` if the run failed before settling
it). `db_refreshed` is `true` when this scan refreshed the OSV database.
`db_age_hours` is the age in whole hours of the database the scan used (`0`
right after a refresh, the stamp's age otherwise, as the "refresh failed"
warning reports it), or `null` when no database was used; a `clean` result
from a days-old database shows here. `base` says what the scan compared with:
`ref`, the merge-base `commit`, `compared`, and `reason` when `compared` is
`false` (`no findings to compare` when the branch had none, so no base was
scanned). Each finding carries the lockfile (relative to the working directory),
package, version, osv-scanner's `ecosystem`, the IDs the text output shows,
`max_severity` (the CVSS score string, or `null`), `severity` (the level above),
`status` (`new` or `existing`), `at_fail_on` (at or above the threshold),
`blocking` (`new` and at or above the threshold, or `overdue`, below),
`fixed` (known fixed versions) and `advisory_published` (the earliest OSV
`published` date of its advisories, or `null`). Non-blocking findings are
included with `blocking: false`.

For consumers: the exit code comes from `blocking` alone, so a scan of the base
branch itself exits 0 with `status: "findings"` when it has findings at or above
the threshold. `status` is relative to `fail_on`, which a repo's
`vulns.fail_on` can change, so a caller that needs one policy across repos
passes `--fail-on` or applies its own threshold to `findings[].severity`. Only
`clean` and `no-lockfiles` mean a scan ran and passed; `skipped` exits 0 but
scanned nothing.

Exit codes:

| Exit | Meaning                                                                            |
| ---- | ---------------------------------------------------------------------------------- |
| 0    | No `new` finding at or above the threshold; no lockfiles; or no database (skipped) |
| 1    | `new` findings at or above the threshold; osv-scanner missing or failed            |
| 2    | An `[[IgnoredVulns]]` entry is missing `reason` or `ignoreUntil`                   |

### Fixing findings

`--ages` says what can be done about each finding, and `--fix` does the part
that needs nobody. Both read the deployment config. Without either flag no
registry is called.

**Deployment config.** ci-cd holds no release age and no default. A deployment
names its own JSON file with `CI_CD_DEPLOYMENT_CONFIG`
(schema: `schema/ci-cd-deployment.schema.json`):

```json
{
  "release_age": { "file": "policy.json", "key": "releaseAge" },
  "gate_on_aged_fix": ["Go"]
}
```

`release_age.file` is relative to this config and `key` is a top-level key of
that JSON file, so the age can stay in a file the deployment already keeps. Its
value must read `<n> days`, for example `"7 days"`; anything else is an error.
`gate_on_aged_fix` lists OSV ecosystems the gate holds to the age (below).
`--ages` and `--fix` fail without a config. `bin/ci gate` without one behaves as
described above, so a contributor with no deployment is not stopped.

**`--ages`** adds `release_age_days` and `fix_state` to each finding, in the
text output and the JSON. The fix considered is the lowest `fixed` version above
the installed one, and its date comes from the registry: npm's
`time[<version>]`, PyPI's `upload_time_iso_8601` or the Go proxy's `.info`
`Time`.

| `fix_state` | Meaning                                                                                |
| ----------- | -------------------------------------------------------------------------------------- |
| `ready`     | A fix at least the age old                                                             |
| `young`     | A fix under the age                                                                    |
| `watching`  | No fix, and the advisory is under the age                                              |
| `decide`    | No fix, and the advisory is past the age                                               |
| `no-age`    | The lockfile's own age setting is missing or differs from the deployment's             |
| `unknown`   | The registry could not be asked, or the advisory has no date                           |
| `overdue`   | `ready` at or above the threshold, in a `gate_on_aged_fix` ecosystem; it blocks a scan |

The lockfile's own setting is only checked against the age, never used as it:
`npm config get min-release-age` (days), `pnpm config get minimumReleaseAge`
(minutes), both run in the lockfile's directory, or `exclude-newer` in the
nearest `uv.toml` up to the checkout, which must read `<n> days`. A lockfile with
no such setting, such as `yarn.lock`, is `no-age`. `go.mod` is never `no-age`,
because the `go` tool has no release age.

**Gate.** In a `gate_on_aged_fix` ecosystem, a finding at or above the threshold
with a fix at least the age old is `overdue` and blocks, `new` or `existing`. It
is the only case in which an `existing` finding blocks. No fix, a younger fix or
a failed lookup does not block one. A branch that removes a finding the base has
passes, so two branches that each fix one overdue finding do not hold each other
red; what a branch adds still blocks. The gate calls a registry only for such an
ecosystem with `existing` findings at or above the threshold, and never without a
deployment config. `blocking` in the JSON covers `overdue`, so `--ages` exits 1
on one too; a plain `bin/ci vulns` calls no registry and does not know of it.

**`--fix`** upgrades each `ready` finding at or above the threshold, one package
at a time, in the lockfile's directory:

| Lockfile            | Command                                       |
| ------------------- | --------------------------------------------- |
| `uv.lock`           | `uv lock --upgrade-package <pkg>`             |
| `pnpm-lock.yaml`    | `pnpm update <pkg> --lockfile-only --no-save` |
| `package-lock.json` | `npm update <pkg> --package-lock-only`        |

It changes lockfiles only, never a manifest, and never refreshes a whole lock.
The manager's own age setting still applies, so nothing younger gets through.
Every other finding is left alone, `overdue` ones included. `--lockfile <path>`,
relative to the working directory, limits the upgrades and the list to one
lockfile. Then it re-scans and lists each package:

```text
ci-cd: vulns: fixed <pkg> <old> → <new> (<lockfile>)
ci-cd: vulns: waiting <pkg> <fix_state>
ci-cd: vulns: failed <pkg>
ci-cd: vulns: <pkg> pinned in <manifest>
```

`pinned` means the manifest names the package and the upgrade left it at its
version. `failed` means the command failed or the finding is still there, for
example a transitive package held by its parent's range.

`--fix` exits 1 on `failed` or `pinned` and 0 otherwise, whatever the re-scan
would exit: an `existing` finding never fails a scan. `young`, `watching`,
`decide`, `no-age` and `unknown` findings do not fail it, and with nothing `ready`
it exits 0 and changes nothing.

`--fix --json <path>` writes the re-scan's report, with `fix_state` on its
findings, plus a `fixes` array of
`{ outcome, package, lockfile, from, to, manifest, fix_state }`, each with the
fields its `outcome` (`fixed`, `waiting`, `failed` or `pinned`) has.

## Toolchain Profiles

Toolchain profiles are configuration-driven defaults for common language
stacks. They keep command details out of application repos while still making
the selected commands inspectable with `bin/ci explain <action>`.

```json
{
  "version": 1,
  "project": {
    "name": "python-service"
  },
  "languages": ["python"],
  "use_toolchains": ["python:uv-ruff-pytest"],
  "targets": {
    "ci": {}
  },
  "actions": {}
}
```

Repos can define their own profile instead of using the built-in default:

```json
{
  "toolchains": {
    "python:team-standard": {
      "detect": {
        "files": ["pyproject.toml"]
      },
      "actions": {
        "lint": {
          "commands": ["uv run ruff check ."]
        },
        "test": {
          "commands": ["uv run pytest"]
        }
      }
    }
  },
  "use_toolchains": ["python:team-standard"]
}
```

If a selected default tool is unavailable, the runner fails. It does not
install tools implicitly or skip the action silently. The error names the
selected profile, the command it planned to run, and the available fixes:
install the default tool, add it to the project toolchain, select another
profile, or override the action in `.ci-cd.json`.

## Language Helpers

Language helpers are optional command builders. They never inspect the repo and
decide what to run by themselves; the consumer config must request each helper
step.

Node and TypeScript helpers run configured `npm`, `pnpm`, `yarn`, or `bun`
scripts:

```json
{
  "actions": {
    "lint": {
      "required_tools": ["pnpm"],
      "helpers": {
        "node": [{ "manager": "pnpm", "script": "lint" }]
      }
    }
  }
}
```

Python helpers run configured `uv`, `pip`, `ruff`, `mypy`, `pytest`, `python`,
or `python3` commands:

```json
{
  "actions": {
    "test": {
      "required_tools": ["pytest"],
      "helpers": {
        "python": [{ "tool": "pytest", "args": ["-q"] }]
      }
    }
  }
}
```

Go helpers run configured `go`, `gofmt`, `go vet`, or `staticcheck` commands:

```json
{
  "actions": {
    "test": {
      "required_tools": ["go"],
      "helpers": {
        "go": [{ "tool": "go", "args": ["test", "./..."] }]
      }
    }
  }
}
```

## Artifacts

Actions can declare artifact paths. After all action commands succeed, the
runner copies each artifact into `CI_ARTIFACTS_DIR`. Missing artifacts fail the
run unless the artifact is declared as optional:

```json
{
  "actions": {
    "test": {
      "commands": ["npm test -- --coverage"],
      "artifacts": [{ "path": "coverage/lcov.info", "optional": true }]
    }
  }
}
```

## Deploy And Stack

Deploy and stack actions are config-driven and target-scoped. The core runner
does not know how an application deploys; it validates the target and runs the
commands declared by the consumer repo.

```json
{
  "targets": {
    "local": {},
    "staging": {},
    "production": {}
  },
  "actions": {
    "deploy": {
      "target_required": true,
      "required_env": ["DEPLOY_TOKEN"],
      "commands": ["./scripts/deploy.sh \"$CI_TARGET\""]
    }
  }
}
```

Use dry-run commands in local and staging targets when introducing deployment
automation. Production safety checks belong in the consumer repo's configured
commands and environment requirements.

## Release

`release` is a standard action for tag-triggered release publishing. Consumer
repos still declare how to build or package their release artifacts, while the
runner owns the repeated hardening steps: stage artifacts, generate a CycloneDX
JSON SBOM with `syft`, sign assets with keyless Sigstore, and upload the full
asset set to the release.

Example config:

```json
{
  "version": 1,
  "project": {
    "name": "example-service"
  },
  "actions": {
    "release": {
      "commands": ["mkdir -p dist && tar -czf dist/example-service.tar.gz README.md"],
      "artifacts": [{ "path": "dist/example-service.tar.gz" }],
      "sbom_source": "."
    }
  }
}
```

The release action requires these tools on `PATH`:

- `syft`
- `cosign`
- `gh`

The caller must provide this generic environment:

- `CI_EVENT=tag`
- `CI_REF`, such as `refs/tags/v1.2.3`
- `CI_REF_NAME`, such as `v1.2.3`
- `CI_TAG`, such as `v1.2.3`
- `CI_COMMIT_SHA`
- `CI_ARTIFACTS_DIR`
- `CI_OIDC_TOKEN`, mapped by the shim when OIDC permissions are available

Set `CI_RELEASE_DRY_RUN=true` to print the `syft`, `cosign`, and `gh release
upload` commands without running them. This is useful for validating command
planning in a repo before cutting its first tag.

On a successful tag release, the runner:

1. Runs `actions.release.commands[]` in the configured working directory.
2. Copies `actions.release.artifacts[]` into `CI_ARTIFACTS_DIR`.
3. Runs `syft <sbom_source> -o cyclonedx-json=<project>-sbom.cdx.json`.
4. Runs `cosign sign-blob --yes` for every staged artifact and the SBOM.
5. Writes `<asset>.sig` and `<asset>.pem` beside each signed asset.
6. Runs `gh release upload "$CI_TAG" --clobber ...` for artifacts, SBOM,
   signatures, and certificates.

The runner uploads to an existing GitHub Release; it does not create one. A tag
push alone does not create a Release, and `gh release upload` will not create
one, so the shim must ensure the Release exists for `$CI_TAG` before invoking
the runner. The GitHub Actions example in
`examples/runners/github-actions/release.yml` does this with an idempotent
`gh release view ... || gh release create ...` step. The shim must also
authenticate `gh` (for example `GH_TOKEN: ${{ github.token }}`); the token is
not ambient on GitHub Actions.

The runner fails before release publishing when it is not invoked for
`CI_EVENT=tag`, when `CI_REF` does not match `refs/tags/$CI_TAG`, when
`CI_OIDC_TOKEN` is unavailable, when required tools are missing, when no release
artifacts are declared, or when a declared artifact path is missing.

Verification uses the certificate identity from the tag workflow. For a GitHub
Actions shim in `example-org/app` using `.github/workflows/release.yml`
and tag `v1.2.3`, the expected identity is:

```text
https://github.com/example-org/app/.github/workflows/release.yml@refs/tags/v1.2.3
```

Consumers can verify an artifact with:

```sh
cosign verify-blob dist/example-service.tar.gz \
  --signature dist/example-service.tar.gz.sig \
  --certificate dist/example-service.tar.gz.pem \
  --certificate-identity "https://github.com/example-org/app/.github/workflows/release.yml@refs/tags/v1.2.3" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

Verify the SBOM the same way by replacing the asset, signature, and certificate
paths with `<project>-sbom.cdx.json`, `<project>-sbom.cdx.json.sig`, and
`<project>-sbom.cdx.json.pem`.

## Thin Wrappers

Application repos can keep familiar local entrypoints, but those entrypoints
should delegate to `ci-cd`.

Example `package.json`:

```json
{
  "scripts": {
    "format": ".ci-cd/bin/ci run format",
    "lint": ".ci-cd/bin/ci run lint",
    "test": ".ci-cd/bin/ci run test",
    "build": ".ci-cd/bin/ci run build",
    "deploy:staging": ".ci-cd/bin/ci run deploy --target staging"
  }
}
```

Example `Makefile`:

```makefile
include .ci-cd/ci.mk
```

The wrapper should stay ergonomic; the workflow logic should live in `ci-cd`
and `.ci-cd.json`.

## CI Runner Shims

Hosted CI systems should only:

1. Check out the consumer repo.
2. Fetch or restore a pinned version of `ci-cd`.
3. Map provider-specific metadata into generic environment variables.
4. Invoke `bin/ci`.

Generic environment variables include:

- `CI_EVENT`
- `CI_BRANCH`
- `CI_REF`
- `CI_REF_NAME`
- `CI_TAG`
- `CI_COMMIT_SHA`
- `CI_PR_TITLE`
- `CI_ARTIFACTS_DIR`
- `CI_RELEASE_NAME`
- `CI_RELEASE_DRY_RUN`
- `CI_OIDC_TOKEN`
- `CI_TARGET`
- `CI_PLATFORM`

Core runner code should not require provider-specific variables such as
`GITHUB_*` or `GITLAB_*`. Those belong in example shims or repo-local CI files.

## Environment Contract

These variables are the generic contract between callers and configured
actions. Callers such as local shells, CI shims, agents, and orchestration tools
can provide them without the core runner knowing which system invoked it.

- `CI_ACTION`: the lifecycle action currently running, such as `format`,
  `lint`, `test`, `build`, `release`, `deploy`, or `stack`.
- `CI_TARGET`: the execution or deployment target, such as `local`, `ci`,
  `staging`, or `production`. Actions that affect an environment should require
  an explicit target.
- `CI_PLATFORM`: the runtime or build platform, such as `linux/amd64` or
  `linux/arm64`. Build, package, deploy, and stack actions can use this for
  architecture-specific behavior.
- `CI_EVENT`: the reason the runner was invoked, such as `local`, `push`,
  `pull_request`, `tag`, `schedule`, or `manual`. CI shims map provider-specific
  event names into this generic value.
- `CI_BRANCH`: the source branch or ref name being processed. Useful for branch
  policy checks, preview deployment naming, cache keys, and release gating.
- `CI_REF`: the full ref being processed, such as `refs/heads/main` or
  `refs/tags/v1.2.3`.
- `CI_REF_NAME`: the short ref name being processed, such as `main` or
  `v1.2.3`.
- `CI_TAG`: the tag name for release workflows. The release action requires
  this to match `CI_REF=refs/tags/$CI_TAG`.
- `CI_COMMIT_SHA`: the commit being built, tested, packaged, or deployed. Used
  for traceability, artifact names, image tags, release metadata, and deployment
  audit records.
- `CI_PR_TITLE`: the pull request title when the event has one. Useful for
  commit-message or release-note policy checks.
- `CI_RELEASE_NAME`: optional display name for release workflows. Defaults to
  `CI_TAG` when present.
- `CI_RELEASE_DRY_RUN`: when `true`, release workflows print the planned
  `syft`, `cosign`, and `gh release upload` commands without executing them.
- `CI_OIDC_TOKEN`: a caller-provided signal that keyless signing can request an
  OIDC token. CI shims should map this from their provider's OIDC environment
  after enabling identity-token permissions.
- `CI_ARTIFACTS_DIR`: a directory where actions can write output artifacts such
  as coverage reports, build bundles, logs, SBOMs, diagnostics, and deployment
  records. CI shims can map this directory to the provider's artifact upload
  mechanism.
- `CI_STATUS`: the current action result. Usually `success` or `failure`.
- `CI_FAILED_STEP`: the name or index of the command that failed. Set only
  after a failure.
- `CI_EXIT_CODE`: the exit code from the failed command. Set only after a
  failure.

## Relationship To `bl`

`bl` coordinates backlog stories, repo scope, worktrees, review, and cleanup.
It should be a consumer of this repo for lifecycle operations, not a second
place where lifecycle automation is implemented.

The intended flow is:

```text
human / agent / CI / bl
  -> repo config
  -> ci-cd runner
  -> shared language/platform/action implementation
  -> logs, status, artifacts
```

This keeps agent workflows and human workflows aligned: the same command path
formats, lints, tests, builds, and deploys the code regardless of who invoked
it.

## Non-Goals

- Do not create an organization- or product-specific app registry in this repo.
- Do not encode local workspace paths.
- Do not require GitHub Actions, GitLab CI, or any other single runner.
- Do not hide app-specific deploy details in shared scripts.
- Do not duplicate workflow logic across every repo's `package.json`,
  `Makefile`, and CI YAML.

## Versioning

Consumers should pin `ci-cd` according to the amount of change control their
pipeline needs:

- Use the moving major tag, such as `v1`, for normal CI consumers that want
  compatible runner updates without editing every repo.
- Use a full semver tag, such as `v1.0.0`, for reproducible or
  change-controlled pipelines.
- Use a commit SHA for maximum immutability, especially for production deploy
  and incident-response-sensitive pipelines.

The default runner shim policy is to clone `ci-cd` with `--branch v1`.
Production deploy pipelines and other high-risk workflows should prefer a full
semver tag or commit SHA when automatic compatible updates are not appropriate.

Release discipline:

- Validate the release commit first with `tests/run.sh`.
- Create the immutable full semver tag after validation passes.
- Advance the moving major tag only after the full semver tag has passed
  validation, and point it at the same commit.
- Never move a full semver tag.

Breaking runner-contract changes require a new major tag such as `v2`. This
includes incompatible changes to CLI flags, config schema semantics, generic
environment variables, action names, artifact behavior, or exit-code behavior.
