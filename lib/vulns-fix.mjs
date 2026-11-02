// Ecosystem knowledge behind `bin/ci vulns --ages` and `--fix`: the deployment
// config, each package manager's release-age setting, the registries that date a
// fix, and the one upgrade command per lock file. ci-runner.mjs owns the scan.
import { spawnSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { basename, dirname, join, relative, resolve } from 'node:path';

import { fail } from './runner-error.mjs';

export const DEPLOYMENT_CONFIG_ENV = 'CI_CD_DEPLOYMENT_CONFIG';

const DAY_MS = 24 * 60 * 60 * 1000;
const MINUTES_PER_DAY = 24 * 60;
const REGISTRY_TIMEOUT_MS = 10_000;
const VERSIONS = new Intl.Collator('en', { numeric: true });

function parseDays(value, where) {
  const match = /^(\d+) days$/.exec(typeof value === 'string' ? value : '');
  if (!match) fail(`vulns: ${where} must read '<n> days'; got ${JSON.stringify(value) ?? '(nothing)'}.`);
  return Number(match[1]);
}

async function readJson(path, what) {
  let raw;
  try {
    raw = await readFile(path, 'utf8');
  } catch (error) {
    fail(`vulns: cannot read ${what} ${path}: ${error.message}`);
  }
  try {
    return JSON.parse(raw);
  } catch (error) {
    fail(`vulns: malformed JSON in ${what} ${path}: ${error.message}`);
  }
}

// The deployment's config, or null when it names none. ci-cd holds no age: the
// value lives in a file the deployment owns, which the config points at.
export async function loadDeploymentConfig() {
  const named = process.env[DEPLOYMENT_CONFIG_ENV];
  if (!named) return null;
  const path = resolve(named);
  const config = await readJson(path, 'deployment config');
  const { file, key } = config?.release_age ?? {};
  const gateOnAgedFix = config?.gate_on_aged_fix ?? [];
  if (typeof file !== 'string' || !file || typeof key !== 'string' || !key) {
    fail(`vulns: ${path}: release_age needs a file and a key.`);
  }
  if (!Array.isArray(gateOnAgedFix) || !gateOnAgedFix.every((item) => typeof item === 'string')) {
    fail(`vulns: ${path}: gate_on_aged_fix must be an array of OSV ecosystem names.`);
  }
  const source = join(dirname(path), file);
  const holder = await readJson(source, 'release age file');
  return {
    releaseAgeDays: parseDays(holder?.[key], `${key} in ${source}`),
    gateOnAgedFix: new Set(gateOnAgedFix),
  };
}

function configGet(tool, name, dir) {
  const result = spawnSync(tool, ['config', 'get', name], { cwd: dir, encoding: 'utf8' });
  const value = Number((result.status === 0 && result.stdout.trim()) || Number.NaN);
  return Number.isFinite(value) ? value : undefined;
}

// Standard TOML through Python's tomllib; the caller keeps what it needs.
function readToml(path) {
  const script = 'import json,sys,tomllib; print(json.dumps(tomllib.load(open(sys.argv[1],"rb")),default=str))';
  const result = spawnSync('python3', ['-I', '-c', script, path], { encoding: 'utf8' });
  if (result.status !== 0) {
    fail(`vulns: cannot read ${path}: ${result.error?.message || result.stderr.trim() || '(no output)'}`);
  }
  return JSON.parse(result.stdout);
}

// The `exclude-newer` of the nearest uv.toml from `dir` up to the checkout.
async function uvSettingDays(dir, baseDir) {
  for (let current = dir; ; current = dirname(current)) {
    const path = join(current, 'uv.toml');
    try {
      await readFile(path);
    } catch {
      if (current === baseDir || relative(baseDir, current).startsWith('..')) return undefined;
      continue;
    }
    const value = readToml(path)['exclude-newer'];
    return value === undefined ? undefined : parseDays(value, `exclude-newer in ${path}`);
  }
}

async function packageJsonDependencies(dir) {
  try {
    const manifest = JSON.parse(await readFile(join(dir, 'package.json'), 'utf8'));
    return ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies'].flatMap((field) =>
      Object.keys(manifest[field] ?? {}),
    );
  } catch {
    return [];
  }
}

// What the project itself asks for, from uv.lock: its names are normalized and
// pyproject.toml's are requirement strings.
function uvDependencies(dir) {
  const own = readToml(join(dir, 'uv.lock')).package?.filter((pkg) => pkg.source?.virtual || pkg.source?.editable);
  return (own ?? []).flatMap((pkg) =>
    [
      pkg.dependencies ?? [],
      ...Object.values(pkg['optional-dependencies'] ?? {}),
      ...Object.values(pkg['dev-dependencies'] ?? {}),
    ]
      .flat()
      .map((dependency) => dependency.name),
  );
}

// One lane per lock file osv-scanner names. `settingDays` is what the package
// manager itself enforces, in days. `go.mod` has no setting and no upgrade: the
// go tool has no release age, and Go fixes arrive some other way.
const LANES = {
  'package-lock.json': {
    settingDays: (dir) => configGet('npm', 'min-release-age', dir),
    upgrade: (name) => ['npm', ['update', name, '--package-lock-only']],
    manifest: 'package.json',
    directDependencies: packageJsonDependencies,
  },
  'pnpm-lock.yaml': {
    settingDays: (dir) => {
      const minutes = configGet('pnpm', 'minimumReleaseAge', dir);
      return minutes === undefined ? undefined : minutes / MINUTES_PER_DAY;
    },
    // Without --no-save, pnpm rewrites the range in package.json.
    upgrade: (name) => ['pnpm', ['update', name, '--lockfile-only', '--no-save']],
    manifest: 'package.json',
    directDependencies: packageJsonDependencies,
  },
  'uv.lock': {
    settingDays: uvSettingDays,
    upgrade: (name) => ['uv', ['lock', '--upgrade-package', name]],
    manifest: 'pyproject.toml',
    directDependencies: uvDependencies,
  },
  'go.mod': {},
};

function laneOf(lockfile) {
  return LANES[basename(lockfile)];
}

async function getJson(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(REGISTRY_TIMEOUT_MS) });
  if (!response.ok) throw new Error(`${url}: ${response.status}`);
  return response.json();
}

// Each answers the date a version was published. OSV's Go versions carry no `v`.
const REGISTRIES = {
  npm: async (name, version) => {
    const packument = await getJson(`https://registry.npmjs.org/${encodeURIComponent(name).replace('%40', '@')}`);
    return packument.time?.[version];
  },
  PyPI: async (name, version) => {
    const release = await getJson(
      `https://pypi.org/pypi/${encodeURIComponent(name)}/${encodeURIComponent(version)}/json`,
    );
    return release.urls?.map((file) => file.upload_time_iso_8601).sort()[0];
  },
  Go: async (name, version) => {
    const module = name.replace(/[A-Z]/g, (letter) => `!${letter.toLowerCase()}`);
    return (await getJson(`https://proxy.golang.org/${module}/@v/v${version}.info`)).Time;
  },
};

// Milliseconds, or null when the registry could not say. A failed lookup is
// `unknown`, so it never turns into an answer.
async function publishedAt(ecosystem, name, version) {
  try {
    const date = Date.parse(await REGISTRIES[ecosystem]?.(name, version));
    return Number.isNaN(date) ? null : date;
  } catch {
    return null;
  }
}

function lowestFix(fixed, installed) {
  return fixed.filter((version) => VERSIONS.compare(version, installed) > 0).sort(VERSIONS.compare)[0] ?? null;
}

export function fixState({ settingMatches, hasFix, fixDate, advisoryPublished, ageDays, overdue, now }) {
  if (!settingMatches) return 'no-age';
  const aged = (date) => now - date >= ageDays * DAY_MS;
  if (!hasFix) {
    const published = Date.parse(advisoryPublished);
    if (Number.isNaN(published)) return 'unknown';
    return aged(published) ? 'decide' : 'watching';
  }
  if (fixDate === null) return 'unknown';
  if (!aged(fixDate)) return 'young';
  return overdue ? 'overdue' : 'ready';
}

// Returns (finding, atFailOn) => fix_state. Answers are kept, so the re-scan of
// `--fix` asks no registry a second time.
export function createFixStates(deployment, baseDir) {
  const settings = new Map();
  const dates = new Map();
  const remember = async (cache, key, ask) => {
    if (!cache.has(key)) cache.set(key, await ask());
    return cache.get(key);
  };
  return async (finding, atFailOn) => {
    const lane = laneOf(finding.path);
    const dir = dirname(join(baseDir, finding.path));
    let settingMatches = lane !== undefined;
    if (lane?.settingDays) {
      const days = await remember(settings, finding.path, () => lane.settingDays(dir, baseDir));
      settingMatches = days === deployment.releaseAgeDays;
    }
    const fix = lowestFix(finding.fixed, finding.version);
    const key = JSON.stringify([finding.ecosystem, finding.name, fix]);
    const needsDate = settingMatches && fix !== null;
    return fixState({
      settingMatches,
      hasFix: fix !== null,
      fixDate: needsDate ? await remember(dates, key, () => publishedAt(finding.ecosystem, finding.name, fix)) : null,
      advisoryPublished: finding.advisoryPublished,
      ageDays: deployment.releaseAgeDays,
      overdue: atFailOn && deployment.gateOnAgedFix.has(finding.ecosystem),
      now: Date.now(),
    });
  };
}

// Splits a scan's findings: `targets`, one per lock file and package, are what
// `--fix` upgrades; `waiting` is the rest of the scope, left alone. Works on the
// ci-cd-vulns/v1 findings.
export function planFixes(findings, atFailOn) {
  const targets = new Map();
  const waiting = new Map();
  for (const finding of findings) {
    const key = JSON.stringify([finding.lockfile, finding.package]);
    if (finding.fix_state === 'ready' && atFailOn(finding) && laneOf(finding.lockfile)?.upgrade) {
      const target = targets.get(key) ?? {
        lockfile: finding.lockfile,
        package: finding.package,
        versions: new Set(),
        ids: new Set(),
      };
      target.versions.add(finding.version);
      for (const id of finding.ids) target.ids.add(id);
      targets.set(key, target);
    } else {
      waiting.set(JSON.stringify([key, finding.fix_state]), {
        lockfile: finding.lockfile,
        package: finding.package,
        fix_state: finding.fix_state,
      });
    }
  }
  // A package being upgraded has one outcome, whatever its lesser advisories say.
  const isTarget = (item) => targets.has(JSON.stringify([item.lockfile, item.package]));
  return { targets: [...targets.values()], waiting: [...waiting.values()].filter((item) => !isTarget(item)) };
}

// Runs one target's upgrade. Only the lock file changes: no manifest, no refresh
// of anything but this package. The manager's own age setting still applies.
export function runUpgrade(target, baseDir) {
  const [tool, args] = laneOf(target.lockfile).upgrade(target.package);
  const cwd = dirname(join(baseDir, target.lockfile));
  console.log(`ci-cd: vulns: upgrading ${target.package} in ${target.lockfile}: ${tool} ${args.join(' ')}`);
  const result = spawnSync(tool, args, { cwd, encoding: 'utf8' });
  if (result.status === 0) return true;
  const output = `${result.stdout || ''}${result.stderr || ''}`.trim() || result.error?.message || '(no output)';
  console.error(`ci-cd: vulns: ${tool} failed (${result.status ?? 'not run'}):\n${output}`);
  return false;
}

const normalizedName = (name) => name.toLowerCase().replace(/[-_.]+/g, '-');

// What became of a target, judged by the re-scan: `after` holds its findings and
// `installed` the versions of every package per lock file.
export async function settleFix(target, upgraded, after, installed, baseDir) {
  const { lockfile, package: name } = target;
  const from = [...target.versions].join(', ');
  if (!upgraded) return { outcome: 'failed', package: name, lockfile, from };
  const left = after.filter(
    (finding) =>
      finding.lockfile === lockfile && finding.package === name && finding.ids.some((id) => target.ids.has(id)),
  );
  if (left.length === 0) {
    const versions = (installed.get(JSON.stringify([lockfile, name])) ?? []).filter((v) => !target.versions.has(v));
    return { outcome: 'fixed', package: name, lockfile, from, to: versions.join(', ') || '(removed)' };
  }
  const lane = laneOf(lockfile);
  const direct = await lane.directDependencies(dirname(join(baseDir, lockfile)));
  const held = left.some((finding) => target.versions.has(finding.version));
  if (held && direct.some((dependency) => normalizedName(dependency) === normalizedName(name))) {
    return { outcome: 'pinned', package: name, lockfile, from, manifest: lane.manifest };
  }
  return { outcome: 'failed', package: name, lockfile, from };
}

export function formatFix(fix) {
  if (fix.outcome === 'fixed') return `fixed ${fix.package} ${fix.from} → ${fix.to} (${fix.lockfile})`;
  if (fix.outcome === 'waiting') return `waiting ${fix.package} ${fix.fix_state}`;
  if (fix.outcome === 'pinned') return `${fix.package} pinned in ${fix.manifest}`;
  return `failed ${fix.package}`;
}
