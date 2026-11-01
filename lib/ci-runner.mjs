#!/usr/bin/env node
import {
  access,
  copyFile,
  cp,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  realpath,
  rm,
  stat,
  writeFile,
} from 'node:fs/promises';
import { constants } from 'node:fs';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { homedir, tmpdir } from 'node:os';

const SUPPORTED_VERSION = 1;
const STANDARD_ACTIONS = new Set([
  'format',
  'lint',
  'typecheck',
  'test',
  'build',
  'package',
  'deploy',
  'release',
  'stack',
]);
// The pre-push gate runs this fast subset of standard actions, in this order.
// `format` is excluded (it rewrites files; a gate checks, it does not mutate)
// and build/package/release/deploy/stack are excluded (too slow or the wrong
// stage for pre-push). `ci gate` runs the intersection of this set with the
// actions the repo *explicitly declares* in .ci-cd.json — never auto-detected
// toolchain actions — so a detected-but-unwired `npm run lint` can never break
// the gate. When the intersection is empty, the gate exits 0.
const GATE_ACTIONS = ['lint', 'typecheck', 'test'];
const VALID_LANGUAGES = new Set(['node', 'typescript', 'python', 'go']);
const ALLOWED_MANAGER = new Set(['npm', 'pnpm', 'yarn', 'bun']);
const ALLOWED_PYTHON_TOOLS = new Set(['uv', 'pip', 'ruff', 'mypy', 'pytest', 'python', 'python3']);
const ALLOWED_GO_TOOLS = new Set(['go', 'gofmt', 'go vet', 'staticcheck']);
const BUILT_IN_TOOLCHAINS = {
  'node:pnpm': {
    detect: { files: ['pnpm-lock.yaml'] },
    actions: {
      format: nodeScript('pnpm', 'format'),
      lint: nodeScript('pnpm', 'lint'),
      test: nodeScript('pnpm', 'test'),
      build: nodeScript('pnpm', 'build'),
    },
  },
  'node:yarn': {
    detect: { files: ['yarn.lock'] },
    actions: {
      format: nodeScript('yarn', 'format'),
      lint: nodeScript('yarn', 'lint'),
      test: nodeScript('yarn', 'test'),
      build: nodeScript('yarn', 'build'),
    },
  },
  'node:bun': {
    detect: { files: ['bun.lockb', 'bun.lock'] },
    actions: {
      format: nodeScript('bun', 'format'),
      lint: nodeScript('bun', 'lint'),
      test: nodeScript('bun', 'test'),
      build: nodeScript('bun', 'build'),
    },
  },
  'node:npm': {
    detect: { files: ['package.json'] },
    actions: {
      format: nodeScript('npm', 'format'),
      lint: nodeScript('npm', 'lint'),
      test: nodeScript('npm', 'test'),
      build: nodeScript('npm', 'build'),
    },
  },
  'python:uv-ruff-pytest': {
    detect: { files: ['uv.lock', 'pyproject.toml'] },
    actions: {
      format: commandAction('uv run ruff format .', ['uv']),
      lint: commandAction('uv run ruff check .', ['uv']),
      test: commandAction('uv run pytest', ['uv']),
    },
  },
  'go:standard': {
    detect: { files: ['go.mod'] },
    actions: {
      format: {
        required_tools: ['gofmt'],
        helpers: { go: [{ tool: 'gofmt', args: ['-w', '.'] }] },
      },
      lint: {
        required_tools: ['go'],
        helpers: { go: [{ tool: 'go', args: ['vet', './...'] }] },
      },
      test: {
        required_tools: ['go'],
        helpers: { go: [{ tool: 'go', args: ['test', './...'] }] },
      },
    },
  },
};

function usage() {
  return `Usage:
  bin/ci run <action> [--config <path>] [--target <name>] [--platform <name>] [--working-directory <path>]
  bin/ci gate [--config <path>] [--target <name>] [--platform <name>] [--working-directory <path>]
  bin/ci validate [--config <path>] [--target <name>] [--platform <name>] [--working-directory <path>]
  bin/ci list-actions [--config <path>] [--working-directory <path>]
  bin/ci explain <action> [--config <path>] [--target <name>] [--platform <name>] [--working-directory <path>]
  bin/ci vulns [--working-directory <path>] [--fail-on critical|high|medium|low] [--base <ref>] [--config <path>] [--json <path>]`;
}

class RunnerError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

function fail(message, exitCode = 1) {
  throw new RunnerError(message, exitCode);
}

function parseArgs(argv) {
  const [command, maybeAction, ...rest] = argv;
  if (!command || command === '-h' || command === '--help') {
    return { command: 'help', options: {} };
  }

  const needsAction = command === 'run' || command === 'explain';
  const action = needsAction ? maybeAction : undefined;
  const args = needsAction ? rest : [maybeAction, ...rest].filter(Boolean);
  const options = {
    config: '.ci-cd.json',
    workingDirectory: '.',
    target: process.env.CI_TARGET || '',
    platform: process.env.CI_PLATFORM || '',
  };

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--config') {
      options.config = requireValue(args, ++i, arg);
      options.configExplicit = true;
    } else if (arg === '--target') options.target = requireValue(args, ++i, arg);
    else if (arg === '--platform') options.platform = requireValue(args, ++i, arg);
    else if (arg === '--working-directory') options.workingDirectory = requireValue(args, ++i, arg);
    else if (arg === '--fail-on' && command === 'vulns') options.failOn = requireValue(args, ++i, arg);
    else if (arg === '--json' && command === 'vulns') options.json = requireValue(args, ++i, arg);
    else if (arg === '--base' && command === 'vulns') options.base = requireValue(args, ++i, arg);
    else fail(`Unknown option: ${arg}\n\n${usage()}`);
  }

  if (!['run', 'gate', 'validate', 'list-actions', 'explain', 'vulns', 'help'].includes(command)) {
    fail(`Unknown command: ${command}\n\n${usage()}`);
  }
  if (needsAction && !action) {
    fail(`Command '${command}' requires an action name.\n\n${usage()}`);
  }
  return { command, action, options };
}

function requireValue(args, index, option) {
  if (index >= args.length || args[index].startsWith('--')) {
    fail(`${option} requires a value.`);
  }
  return args[index];
}

async function loadConfig(options) {
  const baseDir = resolve(options.workingDirectory);
  const configPath = isAbsolute(options.config) ? options.config : resolve(baseDir, options.config);
  let raw;
  try {
    raw = await readFile(configPath, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') {
      fail(`Config file not found: ${configPath}. Pass --config or create .ci-cd.json at the consumer repo root.`);
    }
    throw error;
  }

  try {
    return { config: JSON.parse(raw), configPath, baseDir };
  } catch (error) {
    fail(`Malformed JSON in ${configPath}: ${error.message}`);
  }
}

function validateConfig(config, { action, options, mode }) {
  const errors = [];
  if (!isObject(config)) errors.push('Config root must be an object.');
  if (config.version !== SUPPORTED_VERSION) {
    errors.push(
      `Unsupported schema version '${config.version ?? '(missing)'}'. Supported version is ${SUPPORTED_VERSION}.`,
    );
  }
  if (!isObject(config.project) || !nonEmptyString(config.project.name)) {
    errors.push('project.name is required and must be a non-empty string.');
  }
  if (config.languages !== undefined) {
    if (!Array.isArray(config.languages)) errors.push('languages must be an array.');
    else {
      for (const language of config.languages) {
        if (!nonEmptyString(language) || !VALID_LANGUAGES.has(language)) {
          errors.push(
            `Unsupported language '${String(language)}'. Supported languages: ${[...VALID_LANGUAGES].join(', ')}.`,
          );
        }
      }
    }
  }
  if (config.use_toolchains !== undefined && !arrayOfStrings(config.use_toolchains)) {
    errors.push('use_toolchains must be an array of strings.');
  }
  if (config.auto_detect_toolchains !== undefined && typeof config.auto_detect_toolchains !== 'boolean') {
    errors.push('auto_detect_toolchains must be a boolean.');
  }
  if (config.toolchains !== undefined) {
    validateToolchains(config.toolchains, errors);
  }
  if (config.actions === undefined) {
    if (!hasToolchainSource(config))
      errors.push(
        'actions is required when toolchain auto-detection is explicitly disabled (auto_detect_toolchains: false) and use_toolchains is not configured.',
      );
  } else if (!isObject(config.actions)) {
    errors.push('actions must be an object.');
  } else {
    for (const [name, spec] of Object.entries(config.actions)) {
      validateAction(name, spec, errors);
    }
  }
  if (config.targets !== undefined && !isObject(config.targets)) errors.push('targets must be an object when present.');
  if (config.platforms !== undefined && !Array.isArray(config.platforms) && !isObject(config.platforms)) {
    errors.push('platforms must be an array or object when present.');
  }
  errors.push(...vulnsConfigErrors(config.vulns));

  if (action && isObject(config.actions)) {
    if (!config.actions[action]) {
      errors.push(
        `Unknown action '${action}'. Known actions: ${Object.keys(config.actions).sort().join(', ') || '(none)'}.`,
      );
    }
    const spec = config.actions[action];
    if (spec) {
      if ((spec.target_required === true || action === 'deploy' || action === 'stack') && !options.target) {
        errors.push(`Action '${action}' requires --target or CI_TARGET.`);
      }
    }
  }
  if (options.target) {
    if (!isObject(config.targets) || !Object.hasOwn(config.targets, options.target)) {
      errors.push(`Unknown target '${options.target}'. Known targets: ${knownKeys(config.targets)}.`);
    }
  }
  if (options.platform) {
    if (!hasPlatform(config.platforms, options.platform)) {
      errors.push(`Unknown platform '${options.platform}'. Known platforms: ${knownPlatforms(config.platforms)}.`);
    }
  }

  if (mode !== 'list-actions' && errors.length > 0) {
    fail(`Config validation failed:\n- ${errors.join('\n- ')}`);
  }
  return errors;
}

function validateAction(name, spec, errors) {
  if (!nonEmptyString(name)) errors.push('Action names must be non-empty strings.');
  if (!isObject(spec)) {
    errors.push(`actions.${name} must be an object.`);
    return;
  }
  if (!STANDARD_ACTIONS.has(name) && spec.custom !== true) {
    errors.push(`actions.${name} is not a standard action. Set custom: true to declare custom actions.`);
  }
  if (spec.commands !== undefined && !Array.isArray(spec.commands))
    errors.push(`actions.${name}.commands must be an array.`);
  if (spec.commands) {
    for (const [index, command] of spec.commands.entries()) {
      if (typeof command === 'string') {
        if (!command.trim()) errors.push(`actions.${name}.commands[${index}] must not be empty.`);
      } else if (!isObject(command) || !nonEmptyString(command.command)) {
        errors.push(`actions.${name}.commands[${index}] must be a command string or an object with command.`);
      }
    }
  }
  if (spec.env !== undefined && !isObject(spec.env)) errors.push(`actions.${name}.env must be an object.`);
  if (spec.required_env !== undefined && !arrayOfStrings(spec.required_env))
    errors.push(`actions.${name}.required_env must be an array of strings.`);
  if (spec.required_tools !== undefined && !arrayOfStrings(spec.required_tools))
    errors.push(`actions.${name}.required_tools must be an array of strings.`);
  if (spec.artifacts !== undefined && !Array.isArray(spec.artifacts))
    errors.push(`actions.${name}.artifacts must be an array.`);
  if (spec.helpers !== undefined) validateHelpers(name, spec.helpers, errors);
}

function validateHelpers(action, helpers, errors) {
  if (!isObject(helpers)) {
    errors.push(`actions.${action}.helpers must be an object.`);
    return;
  }
  if (helpers.node !== undefined) {
    if (!Array.isArray(helpers.node)) errors.push(`actions.${action}.helpers.node must be an array.`);
    else {
      for (const [index, helper] of helpers.node.entries()) {
        if (!isObject(helper) || !nonEmptyString(helper.script)) {
          errors.push(`actions.${action}.helpers.node[${index}] requires script.`);
        }
        if (helper.manager !== undefined && !ALLOWED_MANAGER.has(helper.manager)) {
          errors.push(
            `actions.${action}.helpers.node[${index}].manager must be one of ${[...ALLOWED_MANAGER].join(', ')}.`,
          );
        }
      }
    }
  }
  if (helpers.python !== undefined) {
    if (!Array.isArray(helpers.python)) errors.push(`actions.${action}.helpers.python must be an array.`);
    else {
      for (const [index, helper] of helpers.python.entries()) {
        if (!isObject(helper) || !nonEmptyString(helper.tool) || !ALLOWED_PYTHON_TOOLS.has(helper.tool)) {
          errors.push(
            `actions.${action}.helpers.python[${index}].tool must be one of ${[...ALLOWED_PYTHON_TOOLS].join(', ')}.`,
          );
        }
      }
    }
  }
  if (helpers.go !== undefined) {
    if (!Array.isArray(helpers.go)) errors.push(`actions.${action}.helpers.go must be an array.`);
    else {
      for (const [index, helper] of helpers.go.entries()) {
        if (!isObject(helper) || !nonEmptyString(helper.tool) || !ALLOWED_GO_TOOLS.has(helper.tool)) {
          errors.push(
            `actions.${action}.helpers.go[${index}].tool must be one of ${[...ALLOWED_GO_TOOLS].join(', ')}.`,
          );
        }
      }
    }
  }
}

function validateToolchains(toolchains, errors) {
  if (!isObject(toolchains)) {
    errors.push('toolchains must be an object.');
    return;
  }
  for (const [name, spec] of Object.entries(toolchains)) {
    if (!nonEmptyString(name)) errors.push('toolchain names must be non-empty strings.');
    if (!isObject(spec)) {
      errors.push(`toolchains.${name} must be an object.`);
      continue;
    }
    if (spec.detect !== undefined) {
      if (!isObject(spec.detect)) errors.push(`toolchains.${name}.detect must be an object.`);
      else if (spec.detect.files !== undefined && !arrayOfStrings(spec.detect.files)) {
        errors.push(`toolchains.${name}.detect.files must be an array of strings.`);
      }
    }
    if (!isObject(spec.actions)) {
      errors.push(`toolchains.${name}.actions is required and must be an object.`);
      continue;
    }
    for (const [action, actionSpec] of Object.entries(spec.actions)) {
      validateAction(action, actionSpec, errors);
    }
  }
}

async function resolveToolchains(config, baseDir) {
  const configuredToolchains = isObject(config.toolchains) ? config.toolchains : {};
  const availableToolchains = {
    ...BUILT_IN_TOOLCHAINS,
    ...configuredToolchains,
  };
  const selected = [];

  const configuredSelections = Array.isArray(config.use_toolchains) ? config.use_toolchains : [];
  for (const name of configuredSelections) {
    if (!availableToolchains[name]) {
      fail(
        `Unknown toolchain '${name}'. Known toolchains: ${Object.keys(availableToolchains).sort().join(', ') || '(none)'}.`,
      );
    }
    selected.push(name);
  }

  if (config.auto_detect_toolchains !== false) {
    for (const [name, spec] of Object.entries(BUILT_IN_TOOLCHAINS)) {
      if (!selected.includes(name) && (await detectsToolchain(spec, baseDir))) selected.push(name);
    }
    for (const [name, spec] of Object.entries(configuredToolchains)) {
      if (!selected.includes(name) && (await detectsToolchain(spec, baseDir))) selected.push(name);
    }
  }

  const actions = {};
  for (const name of selected) {
    for (const [action, spec] of Object.entries(availableToolchains[name].actions || {})) {
      if (!actions[action]) actions[action] = withToolchain(spec, name);
    }
  }
  const configuredActions = isObject(config.actions) ? config.actions : {};
  for (const [action, spec] of Object.entries(configuredActions)) {
    actions[action] = spec;
  }

  return { ...config, actions };
}

async function detectsToolchain(spec, baseDir) {
  const files = spec.detect?.files || [];
  if (files.length === 0) return false;
  for (const file of files) {
    try {
      await access(resolve(baseDir, file), constants.F_OK);
      return true;
    } catch {
      // Try the next detection file.
    }
  }
  return false;
}

function withToolchain(spec, name) {
  return { ...deepClone(spec), __toolchain: name };
}

async function validateRuntime(config, actionName, env, actionDir) {
  const spec = config.actions[actionName];
  const missingEnv = (spec.required_env || []).filter((name) => !env[name]);
  if (missingEnv.length > 0) {
    fail(`Action '${actionName}' requires missing environment variable(s): ${missingEnv.join(', ')}.`);
  }
  const requiredTools = new Set(spec.required_tools || []);
  if (actionName === 'release') {
    requiredTools.add('syft');
    requiredTools.add('cosign');
    requiredTools.add('gh');
  }
  for (const command of commandPlan(spec)) {
    const tool = firstCommandWord(command.command);
    if (tool && !isShellBuiltin(tool)) requiredTools.add(tool);
  }
  const missingTools = [];
  for (const tool of requiredTools) {
    if (!(await hasTool(tool, actionDir))) missingTools.push(tool);
  }
  if (missingTools.length > 0) {
    if (spec.skip_if_missing === true) {
      console.log(`ci-cd: skipping '${actionName}' because required tool(s) are missing: ${missingTools.join(', ')}`);
      return false;
    }
    if (spec.__toolchain) {
      fail(
        `Action '${actionName}' selected toolchain '${spec.__toolchain}' but required tool(s) are missing: ${missingTools.join(', ')}.\n` +
          `Selected default command(s): ${commandPlan(spec)
            .map((step) => step.command)
            .join(' && ')}\n` +
          `To fix: install the missing default tool(s), add them to this repo's dev toolchain, select a different toolchain with use_toolchains, or override actions.${actionName} in .ci-cd.json.`,
      );
    }
    fail(`Action '${actionName}' requires missing tool(s): ${missingTools.join(', ')}.`);
  }
  if (commandPlan(spec).length === 0 && actionName !== 'release') {
    if (spec.skip_if_missing === true) {
      console.log(`ci-cd: skipping '${actionName}' because it has no commands or helpers.`);
      return false;
    }
    fail(`Action '${actionName}' has no commands or helper steps.`);
  }
  return true;
}

function normalizeEnv(actionName, options, actionEnv = {}) {
  const env = { ...process.env };
  env.CI_ACTION = actionName;
  env.CI_EVENT = env.CI_EVENT || 'local';
  env.CI_BRANCH = env.CI_BRANCH || '';
  env.CI_REF = env.CI_REF || '';
  env.CI_REF_NAME = env.CI_REF_NAME || env.CI_BRANCH || '';
  env.CI_TAG = env.CI_TAG || '';
  env.CI_RELEASE_NAME = env.CI_RELEASE_NAME || env.CI_TAG || env.CI_REF_NAME || '';
  env.CI_RELEASE_DRY_RUN = env.CI_RELEASE_DRY_RUN || '';
  env.CI_OIDC_TOKEN = env.CI_OIDC_TOKEN || '';
  env.CI_COMMIT_SHA = env.CI_COMMIT_SHA || '';
  env.CI_PR_TITLE = env.CI_PR_TITLE || '';
  if (options.target) env.CI_TARGET = options.target;
  else env.CI_TARGET = env.CI_TARGET || '';
  if (options.platform) env.CI_PLATFORM = options.platform;
  else env.CI_PLATFORM = env.CI_PLATFORM || '';
  env.CI_ARTIFACTS_DIR = env.CI_ARTIFACTS_DIR || '';
  // pnpm refuses to purge node_modules without a TTY confirmation
  // (ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY), which hard-fails the pre-push
  // gate. pnpm gates that prompt on its own `ci` setting: with `ci` true it
  // rebuilds silently (`confirmModulesPurge && !ci` collapses to false) instead
  // of aborting. We flip that pnpm-scoped setting rather than the global `CI`
  // env var, whose blast radius is wide (test runners, prettier, and other tools
  // change behavior under `CI`); `pnpm_config_ci` is read only by pnpm. There is
  // no env var for `confirmModulesPurge` itself — pnpm 11 keeps it out of its
  // config schema, so only the CLI `--config.confirmModulesPurge` form sets it
  // and that cannot be injected centrally. The `pnpm_config_` prefix is
  // pnpm-specific, so npm never sees it and emits no unknown-config warning. In a
  // headless context (git hook / CI) let pnpm rebuild silently; when a human is
  // at a terminal, leave its prompt intact. Don't clobber a value the caller
  // already set, in either the lower- or upper-snake form pnpm accepts (guard on
  // undefined so an inherited process.env value or an action-declared env below
  // still wins).
  if (!process.stdin.isTTY && env.pnpm_config_ci === undefined && env.PNPM_CONFIG_CI === undefined) {
    env.pnpm_config_ci = 'true';
  }
  for (const [key, value] of Object.entries(actionEnv)) env[key] = String(value);
  return env;
}

function commandPlan(spec) {
  const plan = [];
  for (const command of spec.commands || []) {
    if (typeof command === 'string') plan.push({ command });
    else plan.push({ ...command });
  }
  const helpers = spec.helpers || {};
  for (const helper of helpers.node || []) {
    const manager = helper.manager || 'npm';
    const run = manager === 'yarn' ? 'yarn' : `${manager} run`;
    plan.push({
      name: `node:${helper.script}`,
      command: `${run} ${shellQuote(helper.script)}`,
    });
  }
  for (const helper of helpers.python || []) {
    const args = (helper.args || []).map(shellQuote).join(' ');
    plan.push({
      name: `python:${helper.tool}`,
      command: `${helper.tool}${args ? ` ${args}` : ''}`,
    });
  }
  for (const helper of helpers.go || []) {
    const args = (helper.args || []).map(shellQuote).join(' ');
    plan.push({
      name: `go:${helper.tool}`,
      command: `${helper.tool}${args ? ` ${args}` : ''}`,
    });
  }
  return plan;
}

async function runAction(config, actionName, options, baseDir) {
  const spec = config.actions[actionName];
  const env = normalizeEnv(actionName, options, spec.env);
  const actionDir = resolve(baseDir, spec.working_directory || '.');
  if (actionName === 'release') requireTagReleaseEnv(env);
  const shouldRun = await validateRuntime(config, actionName, env, actionDir);
  if (!shouldRun) return 0;

  const steps = commandPlan(spec);
  const summary = [];
  console.log(
    `ci-cd: project=${config.project.name} action=${actionName} target=${env.CI_TARGET || '(none)'} platform=${env.CI_PLATFORM || '(none)'}`,
  );

  for (const [index, step] of steps.entries()) {
    const name = step.name || `command ${index + 1}`;
    console.log(`ci-cd: running ${name}: ${step.command}`);
    const code = await runShell(step.command, actionDir, env);
    summary.push({ name, code });
    if (code !== 0) {
      env.CI_STATUS = 'failure';
      env.CI_FAILED_STEP = name;
      env.CI_EXIT_CODE = String(code);
      printSummary(summary);
      return code;
    }
  }

  let stagedArtifacts = [];
  if (spec.artifacts?.length) {
    stagedArtifacts = await copyArtifacts(spec.artifacts, actionDir, env.CI_ARTIFACTS_DIR);
  }
  if (actionName === 'release') {
    await runReleaseFlow(config, spec, actionDir, env, stagedArtifacts);
  }
  env.CI_STATUS = 'success';
  printSummary(summary);
  return 0;
}

// Pre-push gate: run the fast subset of the actions the repo *declares* in
// .ci-cd.json. Keys off the declared config (not the toolchain-resolved
// effective config) so an auto-detected-but-unwired action — e.g. a `node:npm`
// `lint` mapped from a package.json with no `lint` script — can never break the
// gate. Declared actions still run against the effective config, where a
// declared spec has already overridden any same-named toolchain default. Runs
// GATE_ACTIONS in order, stops at the first failure, and exits 0 when the repo
// declares none of them.
async function runGate(declaredConfig, effectiveConfig, options, baseDir) {
  const declared = isObject(declaredConfig.actions) ? declaredConfig.actions : {};
  const gateActions = GATE_ACTIONS.filter((name) => Object.hasOwn(declared, name));
  // `vulns` is not an action: a top-level `vulns` block declares it, and it
  // runs after the declared actions, so a failing lint or test reports first.
  const gateVulns = isObject(declaredConfig.vulns);
  if (gateActions.length === 0 && !gateVulns) {
    console.log('ci-cd: no gate actions declared');
    return 0;
  }
  const steps = gateVulns ? [...gateActions, 'vulns'] : gateActions;
  console.log(`ci-cd: gate actions: ${steps.join(', ')}`);
  for (const actionName of gateActions) {
    const code = await runAction(effectiveConfig, actionName, options, baseDir);
    if (code !== 0) {
      console.error(`ci-cd: gate failed on '${actionName}' (${code})`);
      return code;
    }
  }
  if (gateVulns) {
    const code = await runVulns({
      baseDir,
      failOn: declaredConfig.vulns.fail_on || DEFAULT_VULNS_FAIL_ON,
    });
    if (code !== 0) {
      console.error(`ci-cd: gate failed on 'vulns' (${code})`);
      return code;
    }
  }
  console.log('ci-cd: gate passed');
  return 0;
}

// --- vulns: lockfile vulnerability scan (osv-scanner) -----------------------
//
// `bin/ci vulns` scans every lockfile under a checkout with osv-scanner against
// a locally cached OSV database and fails on new findings at or above a
// severity threshold: a finding the merge base already has is reported and does
// not block. It works with or without a .ci-cd.json so any checkout can be
// scanned; `bin/ci gate` runs the same code when the config declares a
// top-level `vulns` block.

const DEFAULT_VULNS_FAIL_ON = 'high';
// Where the merge base is taken from without --base, first that resolves. A
// `--single-branch` clone may have no origin/HEAD.
const VULNS_BASE_REFS = ['origin/HEAD', 'origin/main'];
// Ascending. A finding's level index >= the threshold's index blocks.
const SEVERITY_LEVELS = ['low', 'medium', 'high', 'critical'];
const OSV_INSTALL_HINT =
  'go install github.com/google/osv-scanner/v2/cmd/osv-scanner@v2.6.0, or a release binary from https://github.com/google/osv-scanner/releases';
const OSV_DB_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const OSV_STAMP_FILE = 'last-download';
const OSV_IGNORE_FILE = 'osv-scanner.toml';
// osv-scanner reports both a failed download and a missing local ecosystem
// database (in offline mode) under this prefix, exiting 127.
const OSV_FETCH_FAILED = /unable to fetch OSV database/;
const OSV_OFFLINE = ['--offline'];
const OSV_REFRESH = ['--offline-vulnerabilities', '--download-offline-databases'];

function vulnsConfigErrors(vulns) {
  if (vulns === undefined) return [];
  if (!isObject(vulns)) return ['vulns must be an object when present.'];
  if (vulns.fail_on !== undefined && !SEVERITY_LEVELS.includes(vulns.fail_on)) {
    return [`vulns.fail_on must be one of ${SEVERITY_LEVELS.join(', ')}; got '${String(vulns.fail_on)}'.`];
  }
  return [];
}

// With --json, every outcome (errors included) is also written as one
// ci-cd-vulns/v1 result, for callers that must tell "vulnerable" from "scan
// broken". The text output and exit codes do not change.
async function vulnsCommand(options) {
  if (options.json === undefined) return vulnsScan(options);
  // Relative to the caller's directory, not --working-directory.
  const jsonPath = resolve(options.json);
  let parentIsDir = false;
  try {
    parentIsDir = (await stat(dirname(jsonPath))).isDirectory();
  } catch {
    // Reported below.
  }
  if (!parentIsDir) {
    fail(`vulns: --json: parent directory does not exist: ${dirname(jsonPath)}`);
  }
  const result = {
    schema: 'ci-cd-vulns/v1',
    status: 'error',
    fail_on: null,
    scanned_at: new Date().toISOString(),
    db_refreshed: false,
    db_age_hours: null,
    base: {
      ref: null,
      commit: null,
      compared: false,
      reason: 'no findings to compare',
    },
    findings: [],
    error: null,
  };
  const write = () => writeFile(jsonPath, `${JSON.stringify(result, null, 2)}\n`);
  try {
    const code = await vulnsScan(options, result);
    await write();
    return code;
  } catch (error) {
    result.status = 'error';
    result.error = error.message;
    await write();
    throw error;
  }
}

async function vulnsScan(options, result) {
  const baseDir = resolve(options.workingDirectory);
  const configPath = isAbsolute(options.config) ? options.config : resolve(baseDir, options.config);
  let failOn = DEFAULT_VULNS_FAIL_ON;
  let raw;
  try {
    raw = await readFile(configPath, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    // No config is fine (any checkout can be scanned) unless one was asked for.
    if (options.configExplicit) fail(`Config file not found: ${configPath}.`);
  }
  if (raw !== undefined) {
    let config;
    try {
      config = JSON.parse(raw);
    } catch (error) {
      fail(`Malformed JSON in ${configPath}: ${error.message}`);
    }
    const vulns = isObject(config) ? config.vulns : undefined;
    const errors = vulnsConfigErrors(vulns);
    if (errors.length > 0) fail(`Config validation failed:\n- ${errors.join('\n- ')}`);
    if (vulns?.fail_on) failOn = vulns.fail_on;
  }
  if (options.failOn !== undefined) {
    if (!SEVERITY_LEVELS.includes(options.failOn)) {
      fail(`--fail-on must be one of ${SEVERITY_LEVELS.join(', ')}; got '${options.failOn}'.`);
    }
    failOn = options.failOn;
  }
  return runVulns({ baseDir, failOn, baseRef: options.base, result });
}

// `result`, when given, is filled in as a ci-cd-vulns/v1 result (see
// vulnsCommand).
async function runVulns({ baseDir, failOn, baseRef, result: outcome = {} }) {
  outcome.fail_on = failOn;
  let isDir = false;
  try {
    isDir = (await stat(baseDir)).isDirectory();
  } catch {
    // Reported below.
  }
  if (!isDir) fail(`vulns: not a directory: ${baseDir}`);
  await requireOsvScanner(baseDir);

  const ignoreFile = join(baseDir, OSV_IGNORE_FILE);
  const hasIgnoreFile = await fileExists(ignoreFile);
  if (hasIgnoreFile) await checkIgnoreFile(ignoreFile, baseDir);

  const cacheDir = osvCacheDir();
  await mkdir(cacheDir, { recursive: true });
  const stampPath = join(cacheDir, OSV_STAMP_FILE);
  const env = {
    ...process.env,
    OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY: cacheDir,
  };
  // One ignore file for the whole checkout: a per-directory osv-scanner.toml
  // only covers lockfiles in its own directory; --config covers every one.
  const baseArgs = ['scan', 'source', '-r', '--format', 'json', ...(hasIgnoreFile ? ['--config', ignoreFile] : [])];
  const scan = (dir, mode) => runOsv([...baseArgs, ...mode, dir], dir, env);
  const isFetchFailure = (result) => result.status === 127 && OSV_FETCH_FAILED.test(result.stderr);
  const stampAge = await fileAgeMs(stampPath);
  // Age of the database the scan used, as the stale-database warning reports it.
  let dbAgeMs = stampAge;

  const refreshScan = async (dir) => {
    const refreshed = scan(dir, OSV_REFRESH);
    if (!isFetchFailure(refreshed)) {
      if (refreshed.status === 0 || refreshed.status === 1) {
        await writeFile(stampPath, `${new Date().toISOString()}\n`);
        outcome.db_refreshed = true;
        dbAgeMs = 0;
      }
      return refreshed;
    }
    const dbAge = await newestOsvDbAgeMs(cacheDir);
    if (dbAge === null) return null;
    const age = Number.isFinite(stampAge) ? stampAge : dbAge;
    dbAgeMs = age;
    console.warn(`ci-cd: vulns: OSV database is ${Math.floor(age / 3600000)}h old (refresh failed)`);
    const offline = scan(dir, OSV_OFFLINE);
    // The cached database lacks an ecosystem this checkout needs.
    return isFetchFailure(offline) ? null : offline;
  };
  // A fresh stamp but no local database for an ecosystem seen for the first
  // time: download it.
  const offlineScan = async (dir) => {
    const offline = scan(dir, OSV_OFFLINE);
    return isFetchFailure(offline) ? refreshScan(dir) : offline;
  };

  const refresh = stampAge > OSV_DB_MAX_AGE_MS;
  console.log(
    `ci-cd: vulns: scanning ${baseDir} (fail on ${failOn}; ${refresh ? 'refreshing OSV database' : 'offline'})`,
  );
  const result = await (refresh ? refreshScan(baseDir) : offlineScan(baseDir));
  if (result !== null && Number.isFinite(dbAgeMs)) outcome.db_age_hours = Math.floor(dbAgeMs / 3600000);
  if (result === null) {
    console.warn('ci-cd: vulns: skipped, no OSV database');
    outcome.status = 'skipped';
    outcome.error = 'no OSV database';
    return 0;
  }
  if (result.status === 128) {
    console.log('ci-cd: vulns: no lockfiles found');
    outcome.status = 'no-lockfiles';
    return 0;
  }
  const branch = osvResultFindings(result, baseDir);
  let onBase = [];
  if (branch.length > 0) {
    const scanBase = async (dir) => {
      const scanned = await offlineScan(dir);
      if (scanned === null) fail('no OSV database for the base scan');
      // The base had no lockfiles, so everything on the branch is new.
      return scanned.status === 128 ? [] : osvResultFindings(scanned, dir);
    };
    const base = {
      ref: baseRef ?? null,
      commit: null,
      compared: false,
      reason: null,
    };
    outcome.base = base;
    try {
      onBase = await baseFindings(baseDir, base, scanBase);
      base.compared = true;
      console.log(`ci-cd: vulns: compared with ${base.ref} (${base.commit})`);
    } catch (error) {
      base.reason = error.message;
      console.warn(`ci-cd: vulns: cannot compare with the base, every finding counts as new: ${error.message}`);
    }
  }
  const findings = classifyFindings(branch, onBase);
  const threshold = SEVERITY_LEVELS.indexOf(failOn);
  const atFailOn = (finding) => finding.rank >= threshold;
  const isBlocking = (finding) => finding.status === 'new' && atFailOn(finding);
  const blocking = findings.filter(isBlocking);
  const reported = findings.filter((f) => f.status === 'new' && !atFailOn(f));
  const existing = findings.filter((f) => f.status === 'existing');
  outcome.findings = findings.map((finding) => ({
    lockfile: finding.path,
    package: finding.name,
    version: finding.version,
    ecosystem: finding.ecosystem,
    ids: finding.ids,
    max_severity: finding.maxSeverity,
    severity: finding.level,
    status: finding.status,
    blocking: isBlocking(finding),
    fixed: finding.fixed,
    advisory_published: finding.advisoryPublished,
  }));
  outcome.status = findings.some(atFailOn) ? 'findings' : 'clean';

  if (blocking.length > 0) {
    console.log(`ci-cd: vulns: ${blocking.length} new finding(s) at or above ${failOn}:`);
    for (const finding of blocking) console.log(`  ${formatFinding(finding)}`);
  }
  if (reported.length > 0) {
    console.log(`ci-cd: vulns: reported, not blocking (below ${failOn}):`);
    for (const finding of reported) console.log(`  ${formatFinding(finding)}`);
  }
  if (existing.length > 0) {
    console.log('ci-cd: vulns: existing, already on the base, not blocking:');
    for (const finding of existing) console.log(`  ${formatFinding(finding)}`);
  }
  if (findings.length > 0) {
    console.log(`ci-cd: vulns: ${findings.length - existing.length} new, ${existing.length} existing`);
  }
  if (blocking.length > 0) {
    console.error(
      `ci-cd: vulns: failed: ${blocking.length} new finding(s) at or above ${failOn}. Upgrade the package, or accept the finding in ${OSV_IGNORE_FILE} ([[IgnoredVulns]] with id, reason and ignoreUntil).`,
    );
    return 1;
  }
  console.log(`ci-cd: vulns: no new findings at or above ${failOn}`);
  return 0;
}

// The findings of the merge base with `base.ref`, unpacked to a temporary
// directory: `git archive` from `baseDir` keeps a subdirectory scan a
// subdirectory. Fills in `base`; throws when the base cannot be compared.
async function baseFindings(baseDir, base, scanBase) {
  if (!git(baseDir, ['rev-parse', '--is-inside-work-tree']).ok) fail('not a git checkout');
  const candidates = base.ref ? [base.ref] : VULNS_BASE_REFS;
  base.ref = candidates.find((ref) => git(baseDir, ['rev-parse', '--verify', '--quiet', `${ref}^{commit}`]).ok) ?? null;
  if (base.ref === null) fail(`no base ref: ${candidates.join(', ')} not found`);
  const mergeBase = git(baseDir, ['merge-base', 'HEAD', base.ref]);
  if (!mergeBase.ok) fail(`no merge base between HEAD and ${base.ref}`);
  base.commit = mergeBase.stdout;

  const tempDir = await realpath(await mkdtemp(join(tmpdir(), 'ci-cd-vulns-')));
  try {
    const archive = join(tempDir, 'base.tar');
    const tree = join(tempDir, 'tree');
    await mkdir(tree);
    const archived = git(baseDir, ['archive', '--format=tar', '-o', archive, base.commit]);
    if (!archived.ok) fail(`git archive of ${base.commit} failed: ${archived.stderr}`);
    const unpacked = spawnSync('tar', ['-xf', archive, '-C', tree], {
      encoding: 'utf8',
    });
    if (unpacked.status !== 0) {
      fail(`could not unpack the base: ${unpacked.error?.message || unpacked.stderr.trim() || '(no output)'}`);
    }
    // osv-scanner would pick the base's own file up when the branch has none.
    // The branch's ignore file is the only one that applies, on both sides.
    await rm(join(tree, OSV_IGNORE_FILE), { force: true });
    return await scanBase(tree);
  } finally {
    await rm(tempDir, { recursive: true, force: true });
  }
}

// Git run from `cwd`. A hook's GIT_DIR and friends point at the pushing repo
// from its root, so they would misread any other directory.
function git(cwd, args) {
  const { GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, ...env } = process.env;
  const result = spawnSync('git', args, { cwd, env, encoding: 'utf8' });
  return {
    ok: result.status === 0,
    stdout: (result.stdout || '').trim(),
    stderr: (result.stderr || '').trim() || result.error?.message || '(no output)',
  };
}

function osvResultFindings(result, dir) {
  if (result.status !== 0 && result.status !== 1) {
    fail(`vulns: osv-scanner failed (${result.status ?? 'signal'}):\n${result.stderr.trim() || '(no output)'}`);
  }
  let report;
  try {
    report = result.stdout.trim() ? JSON.parse(result.stdout) : {};
  } catch (error) {
    fail(`vulns: could not parse osv-scanner JSON output: ${error.message}`);
  }
  return osvFindings(report, dir);
}

// A finding is `existing` when the base has its lock file and package and they
// share an id. The version is not part of it: moving between two versions under
// one advisory adds no exposure, and ids can group differently per version.
function classifyFindings(branch, base) {
  const key = (finding) => JSON.stringify([finding.path, finding.name]);
  const baseIds = new Map();
  for (const finding of base) {
    const ids = baseIds.get(key(finding)) ?? new Set();
    for (const id of finding.ids) ids.add(id);
    baseIds.set(key(finding), ids);
  }
  return branch.map((finding) => {
    const ids = baseIds.get(key(finding));
    return {
      ...finding,
      status: finding.ids.some((id) => ids?.has(id)) ? 'existing' : 'new',
    };
  });
}

async function requireOsvScanner(cwd) {
  if (!(await hasTool('osv-scanner', cwd))) {
    fail(`vulns: osv-scanner is not on PATH. Install it: ${OSV_INSTALL_HINT}.`);
  }
  const version = spawnSync('osv-scanner', ['--version'], {
    cwd,
    encoding: 'utf8',
  });
  const output = `${version.stdout || ''}${version.stderr || ''}`;
  const match = /version:\s*v?(\d+)\.\d+/.exec(output);
  if (!match || match[1] !== '2') {
    fail(
      `vulns: osv-scanner 2.x is required; 'osv-scanner --version' reported: ${output.trim().split('\n')[0] || '(nothing)'}. Install it: ${OSV_INSTALL_HINT}.`,
    );
  }
}

function runOsv(args, cwd, env) {
  const result = spawnSync('osv-scanner', args, {
    cwd,
    env,
    encoding: 'utf8',
    maxBuffer: 1024 * 1024 * 1024,
  });
  if (result.error) fail(`vulns: could not run osv-scanner: ${result.error.message}`);
  return {
    status: result.status,
    stdout: result.stdout || '',
    stderr: result.stderr || '',
  };
}

function osvCacheDir() {
  return join(process.env.XDG_CACHE_HOME || join(homedir(), '.cache'), 'ci-cd', 'osv');
}

async function fileExists(path) {
  try {
    await access(path, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

// Age in ms of a file's mtime; Infinity when it does not exist.
async function fileAgeMs(path) {
  try {
    return Date.now() - (await stat(path)).mtimeMs;
  } catch {
    return Number.POSITIVE_INFINITY;
  }
}

// osv-scanner keeps one <ecosystem>/all.zip per ecosystem under the cache.
async function newestOsvDbAgeMs(cacheDir) {
  let newest = null;
  for (const file of await sortedFiles(cacheDir)) {
    if (basename(file) !== 'all.zip') continue;
    const age = await fileAgeMs(file);
    if (newest === null || age < newest) newest = age;
  }
  return newest;
}

// Every accepted finding must say why and until when, so it comes back for
// review. osv-scanner itself accepts entries without either.
async function checkIgnoreFile(path, baseDir) {
  const entries = parseIgnoredVulns(await readFile(path, 'utf8'));
  const problems = [];
  for (const entry of entries) {
    const missing = ['reason', 'ignoreUntil'].filter((key) => !nonEmptyTomlValue(entry.keys[key]));
    if (missing.length > 0) {
      problems.push(`line ${entry.line} (id ${entry.keys.id || '(missing)'}): missing ${missing.join(', ')}`);
    }
  }
  if (problems.length > 0) {
    fail(
      `vulns: ${relative(baseDir, path)}: every [[IgnoredVulns]] entry needs a reason and an ignoreUntil date:\n- ${problems.join('\n- ')}`,
      2,
    );
  }
}

// Minimal reader for the [[IgnoredVulns]] tables of an osv-scanner.toml: one
// `key = value` per line, which is the shape osv-scanner documents.
function parseIgnoredVulns(text) {
  const entries = [];
  let current = null;
  for (const [index, rawLine] of text.split(/\r?\n/).entries()) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('[')) {
      current = /^\[\[\s*IgnoredVulns\s*\]\]/.test(line) ? { line: index + 1, keys: {} } : null;
      if (current) entries.push(current);
      continue;
    }
    if (!current) continue;
    const match = /^("?)([A-Za-z0-9_-]+)\1\s*=\s*(.*)$/.exec(line);
    if (match) current.keys[match[2]] = unquoteToml(match[3]);
  }
  return entries;
}

function unquoteToml(value) {
  const text = value.trim();
  const quoted = /^"((?:[^"\\]|\\.)*)"|^'([^']*)'/.exec(text);
  if (quoted) return quoted[1] ?? quoted[2];
  return text.replace(/\s+#.*$/, '');
}

function nonEmptyTomlValue(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function osvFindings(report, baseDir) {
  const findings = [];
  for (const result of Array.isArray(report.results) ? report.results : []) {
    const sourcePath = result.source?.path || '(unknown source)';
    const shownPath = isAbsolute(sourcePath) ? relative(baseDir, sourcePath) || sourcePath : sourcePath;
    for (const pkg of result.packages || []) {
      const name = pkg.package?.name || '(unknown package)';
      const version = pkg.package?.version || '(unknown version)';
      for (const group of pkg.groups || []) {
        const ids = [...new Set([...(group.ids || []), ...(group.aliases || [])])];
        const severity = osvSeverity(group.max_severity);
        const maxSeverity = String(group.max_severity ?? '').trim();
        findings.push({
          path: shownPath,
          name,
          version,
          ecosystem: pkg.package?.ecosystem ?? null,
          ids,
          maxSeverity: maxSeverity || null,
          ...severity,
          fixed: osvFixedVersions(pkg, group.ids || [], name),
          advisoryPublished: osvEarliestPublished(pkg, group.ids || []),
        });
      }
    }
  }
  return findings;
}

// max_severity is a CVSS base-score string. No score counts as high, so it
// fails the default gate until it is triaged into the ignore file.
function osvSeverity(maxSeverity) {
  const text = String(maxSeverity ?? '').trim();
  const score = text ? Number(text) : Number.NaN;
  if (!Number.isFinite(score)) return { level: 'high', rank: 2, score: 'no score' };
  let level = 'none';
  if (score >= 9) level = 'critical';
  else if (score >= 7) level = 'high';
  else if (score >= 4) level = 'medium';
  else if (score > 0) level = 'low';
  return { level, rank: SEVERITY_LEVELS.indexOf(level), score: `CVSS ${text}` };
}

function osvFixedVersions(pkg, ids, name) {
  const fixed = new Set();
  for (const vuln of pkg.vulnerabilities || []) {
    if (!ids.includes(vuln.id)) continue;
    for (const affected of vuln.affected || []) {
      if (affected.package?.name !== name) continue;
      for (const range of affected.ranges || []) {
        for (const event of range.events || []) {
          if (event.fixed) fixed.add(event.fixed);
        }
      }
    }
  }
  return [...fixed];
}

// The earliest OSV `published` among a group's advisories, or null.
function osvEarliestPublished(pkg, ids) {
  const dates = (pkg.vulnerabilities || [])
    .filter((vuln) => ids.includes(vuln.id) && !Number.isNaN(Date.parse(vuln.published)))
    .map((vuln) => vuln.published);
  return (
    dates.reduce((earliest, date) => (Date.parse(date) < Date.parse(earliest) ? date : earliest), dates[0]) ?? null
  );
}

function formatFinding(finding) {
  return [
    `${finding.path}:`,
    `${finding.name}@${finding.version}`,
    finding.ids.join(' ') || '(no id)',
    `severity=${finding.level} (${finding.score})`,
    `fixed=${finding.fixed.join(', ') || 'unknown'}`,
    `advisory=${finding.advisoryPublished?.slice(0, 10) ?? 'unknown'}`,
  ].join(' ');
}

function runShell(command, cwd, env) {
  return new Promise((resolveCode) => {
    const child = spawn(command, { cwd, env, shell: true, stdio: 'inherit' });
    child.on('close', (code) => resolveCode(code ?? 1));
    child.on('error', () => resolveCode(1));
  });
}

async function copyArtifacts(artifacts, actionDir, artifactsDir) {
  if (!artifactsDir) fail('Action declared artifacts, but CI_ARTIFACTS_DIR is not set.');
  await mkdir(artifactsDir, { recursive: true });
  const copied = [];
  for (const artifact of artifacts) {
    const item = typeof artifact === 'string' ? { path: artifact } : artifact;
    if (!isObject(item) || !nonEmptyString(item.path)) fail('Each artifact must be a path string or object with path.');
    const src = resolve(actionDir, item.path);
    try {
      await access(src, constants.F_OK);
    } catch {
      if (item.optional === true) continue;
      fail(`Declared artifact is missing after successful action: ${item.path}`);
    }
    const dest = join(artifactsDir, item.name || basename(src));
    const srcStat = await stat(src);
    if (srcStat.isDirectory()) await cp(src, dest, { recursive: true, force: true });
    else await copyFile(src, dest);
    console.log(`ci-cd: artifact ${item.path} -> ${dest}`);
    copied.push(dest);
  }
  return copied;
}

async function runReleaseFlow(config, spec, actionDir, env, stagedArtifacts) {
  if (!env.CI_ARTIFACTS_DIR) fail('Release action requires CI_ARTIFACTS_DIR so release assets can be staged.');
  if (stagedArtifacts.length === 0)
    fail(
      'Release action produced no release artifacts. Declare actions.release.artifacts with at least one existing file.',
    );

  const dryRun = env.CI_RELEASE_DRY_RUN === 'true' || env.CI_RELEASE_DRY_RUN === '1';
  const sbomPath = join(env.CI_ARTIFACTS_DIR, `${safeAssetStem(config.project.name)}-sbom.cdx.json`);
  const sbomSource = resolve(actionDir, spec.sbom_source || '.');
  await runTool('syft', [sbomSource, '-o', `cyclonedx-json=${sbomPath}`], actionDir, env, dryRun);
  if (!dryRun) {
    try {
      await access(sbomPath, constants.F_OK);
    } catch {
      fail(`Release SBOM was not created by syft: ${sbomPath}`);
    }
  }
  console.log(`ci-cd: release sbom -> ${sbomPath}`);

  const releaseAssets = [...(await expandReleaseAssets(stagedArtifacts)), sbomPath];
  const generatedAssets = [];
  for (const asset of releaseAssets) {
    const signature = `${asset}.sig`;
    const certificate = `${asset}.pem`;
    await runTool(
      'cosign',
      ['sign-blob', '--yes', '--output-signature', signature, '--output-certificate', certificate, asset],
      actionDir,
      env,
      dryRun,
    );
    generatedAssets.push(signature, certificate);
    console.log(`ci-cd: release signature -> ${signature}`);
    console.log(`ci-cd: release certificate -> ${certificate}`);
  }

  const uploadAssets = [...releaseAssets, ...generatedAssets];
  await runTool('gh', ['release', 'upload', env.CI_TAG, '--clobber', ...uploadAssets], actionDir, env, dryRun);
  console.log(`ci-cd: release uploaded ${uploadAssets.length} asset(s) to ${env.CI_TAG}`);
}

function requireTagReleaseEnv(env) {
  if (env.CI_EVENT !== 'tag') {
    fail(
      `Release action must run on a tag event. Set CI_EVENT=tag in the release shim; got '${env.CI_EVENT || '(missing)'}'.`,
    );
  }
  if (!env.CI_TAG) {
    fail('Release action requires CI_TAG, such as v1.2.3, mapped from the provider tag ref.');
  }
  const ref = env.CI_REF || (env.CI_REF_NAME ? `refs/tags/${env.CI_REF_NAME}` : '');
  if (!ref) {
    fail(
      `Release action requires CI_REF (refs/tags/${env.CI_TAG}) or CI_REF_NAME (${env.CI_TAG}) so the tag ref can be verified against CI_TAG.`,
    );
  }
  if (ref !== `refs/tags/${env.CI_TAG}`) {
    fail(`Release action requires CI_REF to match CI_TAG as refs/tags/${env.CI_TAG}; got '${ref}'.`);
  }
  if (!env.CI_OIDC_TOKEN) {
    fail(
      'Release action requires CI_OIDC_TOKEN from the caller so keyless Sigstore signing can request an OIDC identity token.',
    );
  }
}

async function expandReleaseAssets(paths) {
  const assets = [];
  for (const assetPath of paths) {
    const assetStat = await stat(assetPath);
    if (assetStat.isDirectory()) {
      for (const child of await sortedFiles(assetPath)) assets.push(child);
    } else {
      assets.push(assetPath);
    }
  }
  return assets;
}

async function sortedFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const fullPath = join(dir, entry.name);
    if (entry.isDirectory()) files.push(...(await sortedFiles(fullPath)));
    else if (entry.isFile()) files.push(fullPath);
  }
  return files.sort((left, right) => relative(dir, left).localeCompare(relative(dir, right)));
}

function runTool(tool, args, cwd, env, dryRun) {
  const rendered = [tool, ...args].map(shellQuote).join(' ');
  if (dryRun) {
    console.log(`ci-cd: dry-run ${rendered}`);
    return Promise.resolve(0);
  }
  return new Promise((resolveCode, reject) => {
    const child = spawn(tool, args, { cwd, env, stdio: 'inherit' });
    child.on('close', (code) => {
      if (code === 0) resolveCode(0);
      else reject(new RunnerError(`Release command failed (${code}): ${rendered}`, code || 1));
    });
    child.on('error', () => reject(new RunnerError(`Release command failed to start: ${rendered}`)));
  });
}

function safeAssetStem(value) {
  return (
    String(value)
      .replace(/[^A-Za-z0-9._-]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'project'
  );
}

function printSummary(summary) {
  console.log('ci-cd: phase summary');
  for (const step of summary) {
    console.log(`ci-cd: ${step.code === 0 ? 'ok' : 'fail'} ${step.name} (${step.code})`);
  }
}

function explain(config, actionName) {
  const spec = config.actions[actionName];
  console.log(`${actionName}`);
  console.log(`  working_directory: ${spec.working_directory || '.'}`);
  console.log(`  required_tools: ${(spec.required_tools || []).join(', ') || '(none)'}`);
  console.log(`  required_env: ${(spec.required_env || []).join(', ') || '(none)'}`);
  console.log('  commands:');
  for (const [index, step] of commandPlan(spec).entries()) {
    console.log(`    ${index + 1}. ${step.command}`);
  }
  if (actionName === 'release') {
    console.log('  release flow:');
    console.log('    1. stage actions.release.artifacts into CI_ARTIFACTS_DIR');
    console.log('    2. run syft to create <project>-sbom.cdx.json');
    console.log('    3. run cosign sign-blob --yes for each artifact and the SBOM');
    console.log('    4. run gh release upload <CI_TAG> --clobber with all assets');
  }
}

function listActions(config) {
  for (const name of Object.keys(config.actions || {}).sort()) console.log(name);
}

async function hasTool(tool, cwd) {
  const result = spawnSync('sh', ['-c', `command -v ${shellQuote(tool)} >/dev/null 2>&1`], { cwd });
  return result.status === 0;
}

function isShellBuiltin(tool) {
  return ['cd', 'echo', 'printf', 'test', '[', 'true', 'false', 'export', 'set', 'unset', 'mkdir'].includes(tool);
}

function firstCommandWord(command) {
  const trimmed = command.trim();
  if (!trimmed) return '';
  for (const word of leadingShellWords(trimmed)) {
    if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(word)) continue;
    return word.includes('/') ? word : word.split('/').pop();
  }
  return '';
}

function leadingShellWords(command) {
  const words = [];
  let word = '';
  let quote = '';
  let escaped = false;
  for (const char of command) {
    if (escaped) {
      word += char;
      escaped = false;
      continue;
    }
    if (char === '\\') {
      escaped = true;
      continue;
    }
    if (quote) {
      if (char === quote) quote = '';
      else word += char;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (/\s/.test(char)) {
      if (word) {
        words.push(word);
        if (!/^[A-Za-z_][A-Za-z0-9_]*=/.test(word)) return words;
        word = '';
      }
      continue;
    }
    if (!/[A-Za-z0-9_./=:@%+,-]/.test(char)) break;
    word += char;
  }
  if (word) words.push(word);
  return words;
}

function shellQuote(value) {
  const text = String(value);
  if (/^[A-Za-z0-9_./:@%+=,-]+$/.test(text)) return text;
  return `'${text.replaceAll("'", "'\\''")}'`;
}

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function nonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function arrayOfStrings(value) {
  return Array.isArray(value) && value.every(nonEmptyString);
}

function knownKeys(value) {
  return isObject(value) ? Object.keys(value).sort().join(', ') || '(none)' : '(none)';
}

function hasPlatform(platforms, platform) {
  if (Array.isArray(platforms)) return platforms.includes(platform);
  if (isObject(platforms)) return Object.hasOwn(platforms, platform);
  return false;
}

function knownPlatforms(platforms) {
  if (Array.isArray(platforms)) return platforms.join(', ') || '(none)';
  if (isObject(platforms)) return Object.keys(platforms).sort().join(', ') || '(none)';
  return '(none)';
}

function hasToolchainSource(config) {
  return Array.isArray(config.use_toolchains) || config.auto_detect_toolchains !== false;
}

function knownActionVocabulary(config) {
  const vocabulary = new Set(STANDARD_ACTIONS);
  if (isObject(config.actions)) {
    for (const name of Object.keys(config.actions)) vocabulary.add(name);
  }
  const availableToolchains = {
    ...BUILT_IN_TOOLCHAINS,
    ...(isObject(config.toolchains) ? config.toolchains : {}),
  };
  for (const toolchain of Object.values(availableToolchains)) {
    if (!isObject(toolchain) || !isObject(toolchain.actions)) continue;
    for (const name of Object.keys(toolchain.actions)) vocabulary.add(name);
  }
  return vocabulary;
}

function nodeScript(manager, script) {
  return {
    required_tools: [manager],
    helpers: { node: [{ manager, script }] },
  };
}

function commandAction(command, requiredTools) {
  return { required_tools: requiredTools, commands: [command] };
}

function deepClone(value) {
  return JSON.parse(JSON.stringify(value));
}

async function main() {
  const parsed = parseArgs(process.argv.slice(2));
  if (parsed.command === 'help') {
    console.log(usage());
    return 0;
  }
  if (parsed.command === 'vulns') return vulnsCommand(parsed.options);

  const { config, configPath, baseDir } = await loadConfig(parsed.options);
  validateConfig(config, {
    action: undefined,
    options: parsed.options,
    mode: 'validate',
  });
  const effectiveConfig = await resolveToolchains(config, baseDir);
  const actionResolved = Boolean(parsed.action && effectiveConfig.actions[parsed.action]);
  validateConfig(effectiveConfig, {
    action: actionResolved ? parsed.action : undefined,
    options: parsed.options,
    mode: parsed.command,
  });
  if (parsed.action && !actionResolved) {
    if (!knownActionVocabulary(config).has(parsed.action)) {
      fail(
        `Unknown action '${parsed.action}'. Known actions: ${Object.keys(effectiveConfig.actions).sort().join(', ') || '(none)'}.`,
      );
    }
    console.error(`ci-cd: no ${parsed.action} targets found`);
    return 0;
  }

  if (parsed.command === 'validate') {
    console.log(`ci-cd: config valid: ${configPath}`);
    return 0;
  }
  if (parsed.command === 'list-actions') {
    listActions(effectiveConfig);
    return 0;
  }
  if (parsed.command === 'explain') {
    explain(effectiveConfig, parsed.action);
    return 0;
  }
  if (parsed.command === 'gate') return runGate(config, effectiveConfig, parsed.options, baseDir);
  if (parsed.command === 'run') return runAction(effectiveConfig, parsed.action, parsed.options, baseDir);
  return 0;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((error) => {
    if (error instanceof RunnerError) {
      console.error(`ci-cd: ${error.message}`);
      process.exitCode = error.exitCode;
    } else {
      console.error(error);
      process.exitCode = 1;
    }
  });
