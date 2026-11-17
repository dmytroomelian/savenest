import { execFile, spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createWriteStream, existsSync } from 'node:fs';
import {
  cp, lstat, mkdir, open, readFile, readdir, rename, rm, symlink, writeFile
} from 'node:fs/promises';
import { homedir, hostname } from 'node:os';
import path from 'node:path';
import {
  ReleaseStateError, createCheckpoint, fileFacts, hashFile, pathExists,
  sha256Text, stableStringify, writeJsonAtomic
} from './release-state.mjs';

// Local release preparation only: snapshot the source, prepare shared assets
// once, build both architectures concurrently, then merge/validate universal.
// Publication is intentionally out of scope.

export const RELEASE_INPUT_ROOTS = ['Sources', 'Tests', 'Resources', 'electron', 'scripts', '.github/ISSUE_TEMPLATE'];
export const RELEASE_INPUT_FILES = [
  'Package.swift', 'Package.resolved', 'package.json', 'package-lock.json',
  'LICENSE', 'THIRD_PARTY_NOTICES.md'
];
const GENERATED_INPUTS = new Set([
  'electron/renderer/workspace.js'
]);
const EXCLUDED_SEGMENTS = new Set([
  '.git', '.build', '.swiftpm', 'node_modules', 'build', 'dist', 'output', 'experiments', '.DS_Store'
]);
const REQUIRED_RELEASE_FILES = [
  'Package.swift', 'Package.resolved', 'package.json', 'package-lock.json',
  'Resources/Info.plist', 'Resources/Electron.entitlements', 'Resources/SaveNest.entitlements',
  'scripts/build-app.sh', 'scripts/build-ui.mjs', 'scripts/build-services.mjs', 'scripts/make-icon.swift',
  'scripts/mcp-package.mjs', 'scripts/social-capture-package.mjs', 'electron/native/services.m',
  'scripts/package-electron.mjs', 'scripts/package-electron-universal.mjs',
  'scripts/check-electron-package.mjs', 'scripts/release-arch.mjs',
  'electron/renderer/workspace-entry.js', 'LICENSE', 'THIRD_PARTY_NOTICES.md'
];
const REQUIRED_TOOLS = ['swift', 'node', 'npm', 'xcrun', 'lipo', 'ditto', 'codesign', 'spctl', 'git'];
const ARCHITECTURES = ['arm64', 'x64'];
export const RELEASE_IDENTITY_SCHEMA = 1;

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, sorted(value[key])]));
  }
  return value;
}

export function defaultReleaseRoot(env = process.env) {
  if (env.RELEASE_WORK_DIR) return path.resolve(env.RELEASE_WORK_DIR);
  return path.join(homedir(), 'Library', 'Caches', 'SaveNest', 'release');
}

export function releaseOutputDirectory({ root, version, env = process.env }) {
  return path.resolve(env.RELEASE_OUTPUT_DIR || path.join(root, 'build', 'releases', 'electron', version));
}

export function plistValue(text, key) {
  const match = text.match(new RegExp(`<key>${key}</key>\\s*<(?:string|integer)>([^<]*)</(?:string|integer)>`));
  if (!match) throw new Error(`Resources/Info.plist is missing ${key}.`);
  return match[1];
}

function execCapture(command, args, options = {}) {
  const { allowFailure = false, timeoutMs = 5 * 60 * 1000, cwd, env } = options;
  return new Promise(resolve => {
    execFile(command, args, { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: timeoutMs, cwd, env },
      (error, stdout, stderr) => {
        const code = error ? (typeof error.code === 'number' ? error.code : 1) : 0;
        if (!allowFailure && code !== 0) {
          resolve({ code, stdout: stdout ?? '', stderr: stderr ?? '' });
          return;
        }
        resolve({ code, stdout: stdout ?? '', stderr: stderr ?? '' });
      });
  });
}

async function runCapture(runtime, command, args, options = {}) {
  const result = await runtime.exec(command, args, options);
  if (!options.allowFailure && result.code !== 0) {
    throw new ReleaseStateError(
      `${command} ${args.join(' ')} failed (${result.code}): ${(result.stderr || result.stdout || '').trim().slice(-1000)}`,
      'command-failed', { command, args, ...result });
  }
  return result;
}

function resolveExecutable(name, env = process.env) {
  if (name === 'node') return process.execPath;
  for (const directory of (env.PATH || '').split(path.delimiter)) {
    if (!directory) continue;
    const candidate = path.join(directory, name);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

function isExcluded(relative) {
  if (GENERATED_INPUTS.has(relative)) return true;
  return relative.split('/').some(segment => EXCLUDED_SEGMENTS.has(segment));
}

function insideReleaseInputs(relative) {
  return RELEASE_INPUT_FILES.includes(relative)
    || RELEASE_INPUT_ROOTS.some(directory => relative === directory || relative.startsWith(`${directory}/`));
}

async function walk(directory, relative = '') {
  const files = [];
  let entries;
  try { entries = await readdir(directory, { withFileTypes: true }); }
  catch (error) { if (error.code === 'ENOENT') return files; throw error; }
  for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const childRelative = relative ? `${relative}/${entry.name}` : entry.name;
    if (isExcluded(childRelative)) continue;
    const child = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walk(child, childRelative));
    else if (entry.isFile() || entry.isSymbolicLink()) files.push(childRelative);
  }
  return files;
}

async function gitList(root, runtime) {
  const result = await runCapture(runtime, 'git', ['-C', root, 'ls-files', '-co', '--exclude-standard', '-z']);
  return result.stdout.split('\0').filter(Boolean);
}

async function readSourceCommit(root, runtime) {
  const commit = (await runCapture(runtime, 'git', ['-C', root, 'rev-parse', 'HEAD'])).stdout.trim();
  const status = (await runCapture(runtime, 'git', ['-C', root, 'status', '--porcelain'])).stdout;
  const lines = status.split('\n').filter(Boolean);
  return { commit, dirty: lines.length > 0, dirtyFileCount: lines.length };
}

async function fileFact(root, relative) {
  const file = path.join(root, relative);
  let details;
  try { details = await lstat(file); }
  catch (error) {
    if (error.code === 'ENOENT') {
      throw new ReleaseStateError(`Release input ${relative} is missing. Refusing to snapshot an incomplete source tree.`, 'input-missing', { file: relative });
    }
    throw error;
  }
  if (details.isSymbolicLink()) {
    throw new ReleaseStateError(
      `Release input ${relative} is a symlink. Frozen releases cannot follow mutable links; replace it with a regular file.`,
      'input-symlink', { file: relative });
  }
  if (!details.isFile()) throw new ReleaseStateError(`Release input ${relative} is not a regular file.`, 'input-invalid', { file: relative });
  return { path: relative, ...await fileFacts(file) };
}

async function captureSnapshotEntries({ env, runtime }) {
  const packagePath = env.SAVENEST_PRO_CAPTURE_PACKAGE;
  if (!packagePath) return { entries: [], identity: null, supplied: null };
  const source = path.resolve(packagePath);
  const listed = (await runCapture(runtime, 'git', ['-C', source, 'ls-files', '-co', '--exclude-standard', '-z'])).stdout.split('\0').filter(Boolean);
  const entries = [];
  for (const relative of [...new Set(listed)].sort()) {
    const normalized = relative.replaceAll(path.sep, '/');
    if (isExcluded(normalized)) continue;
    entries.push({ ...await fileFact(source, normalized), path: `capture/source/${normalized}` });
  }
  for (const required of ['Package.swift', 'LICENSE', 'THIRD_PARTY_NOTICES.txt']) {
    if (!entries.some(entry => entry.path === `capture/source/${required}`)) {
      throw new ReleaseStateError(`Capture source ${source} is missing ${required}; cannot freeze or reuse it safely.`, 'capture-incomplete', { file: required });
    }
  }
  const provenance = await readSourceCommit(source, runtime);
  return {
    entries, supplied: 'source',
    identity: { mode: 'source', path: source, fingerprint: sha256Text(stableStringify(entries)),
      commit: provenance.commit, dirty: provenance.dirty, dirtyFileCount: provenance.dirtyFileCount }
  };
}

async function mcpSnapshotEntries({ root, env, runtime }) {
  const packagePath = env.SAVENEST_MCP_PACKAGE_PATH;
  const suppliedBinary = env.SAVENEST_MCP_BINARY;
  if (packagePath && suppliedBinary) {
    throw new ReleaseStateError('Set only SAVENEST_MCP_PACKAGE_PATH or SAVENEST_MCP_BINARY.', 'mcp-ambiguous');
  }
  if (!packagePath && !suppliedBinary) return { entries: [], identity: null, supplied: null };

  if (packagePath) {
    const source = path.resolve(packagePath);
    if (!(await pathExists(path.join(source, 'Package.resolved')))) {
      throw new ReleaseStateError(`MCP source ${source} has no Package.resolved; cannot freeze or reuse it safely.`, 'mcp-incomplete');
    }
    const files = await walk(source);
    const entries = [];
    for (const relative of files) {
      const fact = await fileFact(source, relative);
      entries.push({ ...fact, path: `mcp/source/${relative}` });
    }
    return {
      entries, supplied: 'source',
      identity: { mode: 'source', path: source, fingerprint: sha256Text(stableStringify(entries)) }
    };
  }

  const binary = path.resolve(suppliedBinary);
  const directory = path.dirname(binary);
  const names = { binary: path.basename(binary), license: 'LICENSE', thirdParty: 'THIRD_PARTY_NOTICES.txt' };
  const entries = [];
  for (const [role, name] of Object.entries(names)) {
    const fact = await fileFact(directory, name);
    entries.push({ ...fact, path: `mcp/binary/${name}`, role });
  }
  return {
    entries, supplied: 'binary',
    identity: { mode: 'binary', binaryName: path.basename(binary), path: binary,
      fingerprint: sha256Text(stableStringify(entries)) }
  };
}

export async function collectSnapshotPlan({ root, env = process.env, runtime = { exec: execCapture } }) {
  const listed = await gitList(root, runtime);
  const selected = [];
  for (const relative of [...new Set(listed)].sort()) {
    const normalized = relative.replaceAll(path.sep, '/');
    if (!insideReleaseInputs(normalized) || isExcluded(normalized)) continue;
    selected.push(await fileFact(root, normalized));
  }
  if (!selected.some(entry => entry.path === 'Package.swift')) {
    throw new ReleaseStateError(`No release inputs found under ${root}.`, 'source-empty');
  }
  const mcp = await mcpSnapshotEntries({ root, env, runtime });
  const capture = await captureSnapshotEntries({ env, runtime });
  const entries = [...selected, ...mcp.entries, ...capture.entries].sort((a, b) => a.path.localeCompare(b.path));
  const fingerprint = sha256Text(stableStringify(entries.map(({ path: file, sha256, size, link }) =>
    ({ path: file, sha256, size, ...(link ? { link } : {}) }))));
  const provenance = await readSourceCommit(root, runtime);
  if (capture.identity) provenance.capture = capture.identity;
  return { entries, fingerprint, provenance, mcp: mcp.identity, capture: capture.identity, inputCount: entries.length };
}

function safeRelative(relative) {
  if (relative.startsWith('/') || relative.split('/').includes('..')) {
    throw new ReleaseStateError(`Refusing unsafe snapshot path ${relative}.`, 'snapshot-path');
  }
  return relative;
}

async function verifySnapshotContents({ destination, manifest, plan }) {
  const planned = plan.entries;
  if (manifest) {
    if (stableStringify(manifest.entries) !== stableStringify(planned)) {
      throw new ReleaseStateError(
        `Refusing to reuse snapshot ${destination}: its recorded input list differs from the frozen source.`,
        'snapshot-mismatch', { snapshot: destination });
    }
  }
  for (const entry of planned) {
    const file = path.join(destination, safeRelative(entry.path));
    let details;
    try { details = await lstat(file); }
    catch (error) {
      if (error.code === 'ENOENT') {
        throw new ReleaseStateError(`Snapshot ${destination} is missing input ${entry.path}.`, 'snapshot-mutated', { file: entry.path });
      }
      throw error;
    }
    if (!details.isFile()) {
      throw new ReleaseStateError(`Snapshot input ${entry.path} is no longer a regular file.`, 'snapshot-mutated', { file: entry.path });
    }
    const facts = await fileFacts(file);
    if (facts.sha256 !== entry.sha256 || facts.size !== entry.size) {
      throw new ReleaseStateError(
        `Snapshot ${destination} no longer matches frozen input ${entry.path}. Refusing to package changed bytes.`,
        'snapshot-mutated', { file: entry.path });
    }
  }
  // Detect extra source files not captured by the frozen content fingerprint,
  // ignoring only generated assets and the explicit node_modules reuse link.
  const present = new Set();
  for (const rootName of RELEASE_INPUT_ROOTS) {
    for (const relative of await walk(path.join(destination, rootName), rootName)) {
      if (isExcluded(relative)) continue;
      present.add(relative);
    }
  }
  for (const mcpRoot of ['mcp/source', 'mcp/binary', 'capture/source']) {
    if (!planned.some(entry => entry.path.startsWith(`${mcpRoot}/`))) continue;
    for (const relative of await walk(path.join(destination, mcpRoot), mcpRoot)) present.add(relative);
  }
  for (const relative of RELEASE_INPUT_FILES) {
    if (await pathExists(path.join(destination, relative))) present.add(relative);
  }
  const expected = new Set(planned.map(entry => entry.path));
  const extra = [...present].filter(relative => !expected.has(relative));
  const missing = [...expected].filter(relative => !present.has(relative));
  if (extra.length || missing.length) {
    throw new ReleaseStateError(
      `Snapshot ${destination} input set changed (extra: ${extra.slice(0, 5).join(', ') || 'none'}; missing: ${missing.slice(0, 5).join(', ') || 'none'}).`,
      'snapshot-mutated', { snapshot: destination, extra, missing });
  }
}

export async function createSourceSnapshot({ root, destination, plan, env = process.env }) {
  const readManifest = async () => {
    try { return JSON.parse(await readFile(path.join(destination, 'snapshot.json'), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  };
  const existing = await readManifest();
  if (existing) {
    if (existing.fingerprint !== plan.fingerprint) {
      throw new ReleaseStateError(
        `Refusing to reuse snapshot ${destination}: its fingerprint differs from the frozen source.`,
        'snapshot-mismatch', { snapshot: destination });
    }
    await verifySnapshotContents({ destination, manifest: existing, plan });
    return { directory: destination, manifest: existing, reused: true };
  }
  if (await pathExists(destination)) {
    throw new ReleaseStateError(
      `Refusing to reuse ${destination}: it exists without snapshot provenance. Move it aside only after confirming it is obsolete.`,
      'snapshot-without-provenance', { snapshot: destination });
  }
  await mkdir(path.dirname(destination), { recursive: true });
  const temporary = `${destination}.tmp-${process.pid}-${randomUUID().slice(0, 8)}`;
  await rm(temporary, { recursive: true, force: true });
  await mkdir(temporary, { recursive: true });
  try {
    for (const entry of plan.entries) {
      const relative = safeRelative(entry.path);
      const target = path.join(temporary, relative);
      await mkdir(path.dirname(target), { recursive: true });
      if (entry.path.startsWith('mcp/source/')) {
        const sourceRoot = path.resolve(env.SAVENEST_MCP_PACKAGE_PATH || '');
        await cp(path.join(sourceRoot, entry.path.slice('mcp/source/'.length)), target, { verbatimSymlinks: true });
      } else if (entry.path.startsWith('mcp/binary/')) {
        const sourceRoot = path.dirname(path.resolve(env.SAVENEST_MCP_BINARY || ''));
        await cp(path.join(sourceRoot, path.basename(entry.path)), target, { verbatimSymlinks: true });
      } else if (entry.path.startsWith('capture/source/')) {
        const sourceRoot = path.resolve(env.SAVENEST_PRO_CAPTURE_PACKAGE || '');
        await cp(path.join(sourceRoot, entry.path.slice('capture/source/'.length)), target, { verbatimSymlinks: true });
      } else {
        await cp(path.join(root, entry.path), target);
      }
    }
    await verifySnapshotContents({ destination: temporary, manifest: null, plan });
    const nodeModules = path.join(root, 'node_modules');
    if (await pathExists(nodeModules)) {
      await symlink(path.relative(temporary, nodeModules), path.join(temporary, 'node_modules'), 'dir');
    }
    const manifest = {
      schema: 1, fingerprint: plan.fingerprint, capturedAt: new Date().toISOString(),
      commit: plan.provenance.commit, dirty: plan.provenance.dirty, dirtyFileCount: plan.provenance.dirtyFileCount,
      mcp: plan.mcp ? { mode: plan.mcp.mode, fingerprint: plan.mcp.fingerprint,
      ...(plan.mcp.binaryName ? { binaryName: plan.mcp.binaryName } : {}) } : null,
      capture: plan.capture ? { mode: plan.capture.mode, fingerprint: plan.capture.fingerprint,
        commit: plan.capture.commit, dirty: plan.capture.dirty } : null, entries: plan.entries
    };
    await writeJsonAtomic(path.join(temporary, 'snapshot.json'), manifest);
    await rename(temporary, destination);
    return { directory: destination, manifest, reused: false };
  } catch (error) {
    await rm(temporary, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

export function computeReleaseIdentity({ version, build, sourceFingerprint, electronVersion, signingIdentity, captureFingerprint = '', configuration = 'release' }) {
  return sha256Text(stableStringify({
    schema: RELEASE_IDENTITY_SCHEMA, version, build, sourceFingerprint, electronVersion,
    captureFingerprint, signingIdentity: sha256Text(signingIdentity || ''), configuration
  }));
}

export async function preflightRelease({ root, env = process.env, runtime = { exec: execCapture }, plan = false }) {
  const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  const plistText = await readFile(path.join(root, 'Resources/Info.plist'), 'utf8');
  const version = plistValue(plistText, 'CFBundleShortVersionString');
  const build = plistValue(plistText, 'CFBundleVersion');
  const publicKey = plistValue(plistText, 'SUPublicEDKey');
  if (manifest.version !== version) throw new Error(`package.json version ${manifest.version} does not match Resources/Info.plist ${version}.`);
  if (!/^[1-9]\d*$/.test(build)) throw new Error('The native build number must be a positive integer for Sparkle version ordering.');
  if (Buffer.from(publicKey, 'base64').length !== 32) throw new Error('The Sparkle Ed25519 public key must contain 32 bytes.');
  const notes = path.join(root, 'Resources/ReleaseNotes', `${version}.html`);
  if (!(await pathExists(notes))) throw new Error(`Add release notes at Resources/ReleaseNotes/${version}.html before building a release.`);
  for (const relative of REQUIRED_RELEASE_FILES) {
    if (!(await pathExists(path.join(root, relative)))) throw new Error(`Required release input ${relative} is missing.`);
  }
  const lock = JSON.parse(await readFile(path.join(root, 'package-lock.json'), 'utf8'));
  const pinnedElectron = lock.packages?.['node_modules/electron']?.version || lock.dependencies?.electron?.version;
  if (pinnedElectron !== manifest.devDependencies?.electron) {
    throw new Error(`package-lock.json pins Electron ${pinnedElectron}, package.json requires ${manifest.devDependencies?.electron}.`);
  }
  const lockVersions = [lock.version, lock.packages?.['']?.version].filter(Boolean);
  if (!lockVersions.length || lockVersions.some(value => value !== manifest.version)) {
    throw new Error(`package-lock.json version ${lockVersions.join(', ') || '(missing)'} does not match package.json ${manifest.version}.`);
  }
  for (const [name, pinned] of Object.entries({ ...manifest.dependencies, ...manifest.devDependencies })) {
    let installed;
    try { installed = JSON.parse(await readFile(path.join(root, 'node_modules', name, 'package.json'), 'utf8')).version; }
    catch { throw new Error(`Installed dependency ${name} is missing; run npm ci before preparing a release.`); }
    if (installed !== pinned) throw new Error(`Installed ${name} ${installed} does not match pinned ${pinned}. Run npm ci.`);
  }
  const nodeVersion = process.versions.node;
  const [major, minor] = nodeVersion.split('.').map(Number);
  if (major < 22 || (major === 22 && minor < 12)) throw new Error(`Node ${nodeVersion} is older than engines.node >=22.12.0.`);
  const tools = Object.fromEntries(REQUIRED_TOOLS.map(name => [name, resolveExecutable(name, env)]));
  const missingTools = Object.entries(tools).filter(([, file]) => !file).map(([name]) => name);
  if (!plan && missingTools.length) throw new Error(`Required release tools are missing from PATH: ${missingTools.join(', ')}.`);
  const credentialsRequired = !plan;
  if (credentialsRequired) {
    if (!env.SIGNING_IDENTITY || env.SIGNING_IDENTITY === '-') throw new Error('Set SIGNING_IDENTITY to a Developer ID identity.');
    if (!env.NOTARY_PROFILE) throw new Error('Set NOTARY_PROFILE to an existing notarytool keychain profile.');
  }
  return { manifest, version, build, publicKey, tools, missingTools, nodeVersion, credentialsRequired };
}

export async function runToolVersions({ env = process.env, runtime = { exec: execCapture } }) {
  const swift = (await runCapture(runtime, 'swift', ['--version'])).stdout.split('\n')[0].trim();
  const node = (await runCapture(runtime, 'node', ['--version'])).stdout.trim();
  return { swift, node };
}

export function swiftCacheDirectory({ releaseRoot, swiftVersion, architecture, configuration, packageResolved, captureFingerprint = '' }) {
  const key = sha256Text(stableStringify({ swiftVersion, architecture, configuration, packageResolved, captureFingerprint }));
  return path.join(releaseRoot, 'caches', 'swift', architecture, key);
}

export async function acquireReleaseLock({
  directory, now = () => Date.now(), staleAfterMs = 6 * 60 * 60 * 1000,
  recoverStale = false, pid = process.pid, host = hostname()
}) {
  await mkdir(directory, { recursive: true });
  const file = path.join(directory, 'release.lock');
  const token = randomUUID();
  const payload = JSON.stringify({ token, pid, host, acquiredAt: new Date(now()).toISOString() });
  const tryAcquire = async () => {
    try {
      const handle = await open(file, 'wx', 0o600);
      try { await handle.writeFile(payload + '\n'); } finally { await handle.close(); }
      return true;
    } catch (error) {
      if (error.code === 'EEXIST') return false;
      throw error;
    }
  };
  if (!(await tryAcquire())) {
    let current = null;
    try { current = JSON.parse(await readFile(file, 'utf8')); } catch { /* unreadable lock */ }
    const age = current?.acquiredAt ? now() - Date.parse(current.acquiredAt) : Infinity;
    const sameHost = current?.host === host;
    const alive = sameHost && Number.isInteger(current?.pid) && isProcessAlive(current.pid);
    const stale = sameHost ? !alive : age > staleAfterMs;
    if (!stale || !recoverStale) {
      throw new ReleaseStateError(
        `Another release preparation holds ${file}${current?.pid ? ` (pid ${current.pid}, ${new Date(current.acquiredAt).toISOString()})` : ''}. ` +
        `Wait for it to finish. If it was interrupted, rerun with RELEASE_RECOVER_LOCK=1 only after confirming no release process is active.`,
        'release-lock-held', { lock: file, owner: current });
    }
    await rm(file, { force: true });
    if (!(await tryAcquire())) {
      throw new ReleaseStateError(`Release lock ${file} was reacquired by another process.`, 'release-lock-held', { lock: file });
    }
  }
  return {
    file,
    async release() {
      let current = null;
      try { current = JSON.parse(await readFile(file, 'utf8')); } catch { return; }
      if (current.token !== token) {
        throw new ReleaseStateError(`Refusing to release ${file}: it belongs to another invocation.`, 'release-lock-owner');
      }
      await rm(file, { force: true });
    }
  };
}

function isProcessAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) { return error.code === 'EPERM'; }
}

export function spawnChildStage({ command, args, cwd, env, stdoutPath, stderrPath }) {
  return new Promise(async resolve => {
    await mkdir(path.dirname(stdoutPath), { recursive: true });
    await mkdir(path.dirname(stderrPath), { recursive: true });
    const stdout = createWriteStream(stdoutPath);
    const stderr = createWriteStream(stderrPath);
    let settled = false;
    const finish = result => {
      if (settled) return;
      settled = true;
      stdout.end();
      stderr.end();
      resolve(result);
    };
    let child;
    try { child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'] }); }
    catch (error) { finish({ code: 1, signal: null, error }); return; }
    child.stdout.pipe(stdout);
    child.stderr.pipe(stderr);
    child.on('error', error => finish({ code: 1, signal: null, error }));
    child.on('close', (code, signal) => finish({ code: code ?? 1, signal: signal ?? null }));
  });
}

export async function runArchStages({
  tasks, jobs = 2, spawnStage, onStart = async () => {}, onSettled = async () => {}
}) {
  const queue = [...tasks];
  const results = [];
  const worker = async () => {
    while (queue.length) {
      const task = queue.shift();
      try { await onStart(task); }
      catch (error) {
        results.push({ task, result: { code: 1, signal: null, error } });
        continue;
      }
      let result;
      try { result = await spawnStage(task.task); }
      catch (error) { result = { code: 1, signal: null, error }; }
      try { await onSettled({ task, result }); }
      catch (error) { result = { ...result, error: result.error || error }; }
      results.push({ task, result });
    }
  };
  const workers = Array.from({ length: Math.min(Math.max(1, jobs), queue.length || 1) }, worker);
  await Promise.all(workers);
  return results.sort((a, b) => ARCHITECTURES.indexOf(a.task.architecture) - ARCHITECTURES.indexOf(b.task.architecture));
}

async function hashDirectoryCompat(directory) {
  // release-state's hashDirectory is reused indirectly through packager identity;
  // record the same recursive content shape for helper resume checks.
  const { hashDirectory } = await import('./release-state.mjs');
  return hashDirectory(directory);
}

async function recordPreparedArtifacts({ stageState, helper, mcpDirectory }) {
  const facts = {};
  if (helper && await pathExists(path.join(helper, 'Contents/Info.plist'))) {
    facts.helper = { path: helper, sha256: await hashDirectoryCompat(helper) };
  }
  if (mcpDirectory) {
    const binary = path.join(mcpDirectory, 'savenest-mcp');
    const license = path.join(mcpDirectory, 'LICENSE');
    const thirdParty = path.join(mcpDirectory, 'THIRD_PARTY_NOTICES.txt');
    if (await pathExists(binary) && await pathExists(license) && await pathExists(thirdParty)) {
      facts.mcp = {
        directory: mcpDirectory, binary,
        binarySha256: await hashFile(binary),
        licenseSha256: await hashFile(license),
        thirdPartySha256: await hashFile(thirdParty)
      };
    }
  }
  await stageState.update(state => { state.prepared = { ...(state.prepared || {}), ...facts }; });
  return facts;
}

async function verifyPreparedResume({
  stageState, pending, sourceFingerprint, identity, helper, mcpDirectory, canonicalCheckpoint
}) {
  const state = await stageState.read();
  let prepared = state?.sourceFingerprint === sourceFingerprint && state?.identity === identity
    ? state?.prepared : null;
  if (!prepared && pending && canonicalCheckpoint) {
    // A process can be interrupted after the packager recorded its canonical
    // checkpoint but before stage bookkeeping survived. Recover the prepared
    // inputs only when their hashes match the canonical signed-input identity.
    const canonical = await canonicalCheckpoint.read();
    const inputs = canonical?.identity === identity ? canonical.inputs?.source : null;
    if (inputs?.helper) {
      if (!(await pathExists(path.join(helper, 'Contents/Info.plist')))) {
        throw new ReleaseStateError(
          `The signed helper ${helper} for a pending release is missing. Refusing to rebuild and mix signatures.`,
          'helper-missing', { helper });
      }
      const current = await hashDirectoryCompat(helper);
      if (current !== inputs.helper) {
        throw new ReleaseStateError(
          `The helper ${helper} does not match the pending release's signed input hash. Refusing to mix signatures.`,
          'helper-changed', { helper });
      }
      prepared = { helper: { path: helper, sha256: current } };
    }
    if (inputs?.files?.mcpBinary) {
      const binary = path.join(mcpDirectory, 'savenest-mcp');
      const license = path.join(mcpDirectory, 'LICENSE');
      const thirdParty = path.join(mcpDirectory, 'THIRD_PARTY_NOTICES.txt');
      if (!(await pathExists(binary)) || !(await pathExists(license)) || !(await pathExists(thirdParty))) {
        throw new ReleaseStateError(
          `Prepared MCP inputs for a pending release are missing in ${mcpDirectory}. Refusing to rebuild signed inputs.`,
          'mcp-missing', { directory: mcpDirectory });
      }
      const facts = {
        directory: mcpDirectory, binary,
        binarySha256: await hashFile(binary),
        licenseSha256: await hashFile(license),
        thirdPartySha256: await hashFile(thirdParty)
      };
      if (facts.binarySha256 !== inputs.files.mcpBinary || facts.licenseSha256 !== inputs.files.mcpLicense
        || facts.thirdPartySha256 !== inputs.files.mcpThirdParty) {
        throw new ReleaseStateError(
          `Prepared MCP inputs in ${mcpDirectory} do not match the pending release's signed hashes.`,
          'mcp-changed', { directory: mcpDirectory });
      }
      prepared = { ...(prepared || {}), mcp: facts };
    }
    if (prepared) await stageState.update(current => { current.prepared = prepared; });
  }
  if (!prepared) return { helperReusable: false, mcp: null };
  let helperReusable = false;
  if (prepared.helper) {
    if (!(await pathExists(path.join(prepared.helper.path, 'Contents/Info.plist')))) {
      if (pending) {
        throw new ReleaseStateError(
          `The signed helper ${prepared.helper.path} for a pending release is missing. Refusing to rebuild and mix signatures; restore the workspace or start a new release version.`,
          'helper-missing', { helper: prepared.helper.path });
      }
    } else {
      const current = await hashDirectoryCompat(prepared.helper.path);
      if (current !== prepared.helper.sha256) {
        throw new ReleaseStateError(
          `The prepared helper ${prepared.helper.path} changed after it was signed. Refusing to reuse or silently rebuild it.`,
          'helper-changed', { helper: prepared.helper.path });
      }
      helperReusable = true;
    }
  }
  if (prepared.mcp) {
    const missing = [];
    if (!(await pathExists(prepared.mcp.binary))) missing.push(prepared.mcp.binary);
    if (!(await pathExists(path.join(prepared.mcp.directory, 'LICENSE')))) missing.push('LICENSE');
    if (!(await pathExists(path.join(prepared.mcp.directory, 'THIRD_PARTY_NOTICES.txt')))) missing.push('THIRD_PARTY_NOTICES.txt');
    if (missing.length) {
      if (pending) {
        throw new ReleaseStateError(
          `Prepared MCP inputs for a pending release are missing (${missing.join(', ')}). Refusing to rebuild signed inputs.`,
          'mcp-missing', { missing });
      }
      return { helperReusable, mcp: null };
    }
    const facts = {
      binarySha256: await hashFile(prepared.mcp.binary),
      licenseSha256: await hashFile(path.join(prepared.mcp.directory, 'LICENSE')),
      thirdPartySha256: await hashFile(path.join(prepared.mcp.directory, 'THIRD_PARTY_NOTICES.txt'))
    };
    if (facts.binarySha256 !== prepared.mcp.binarySha256 || facts.licenseSha256 !== prepared.mcp.licenseSha256
      || facts.thirdPartySha256 !== prepared.mcp.thirdPartySha256) {
      throw new ReleaseStateError(
        `Prepared MCP inputs in ${prepared.mcp.directory} changed after they were packaged. Refusing to mix builds.`,
        'mcp-changed', { directory: prepared.mcp.directory });
    }
    return { helperReusable, mcp: prepared.mcp };
  }
  return { helperReusable, mcp: null };
}

export async function archStageIsVerified({
  stageState, canonicalCheckpoint, archive, expectedIdentity, sourceFingerprint, architecture
}) {
  if (!stageState || stageState.status !== 'completed') return false;
  if (stageState.sourceFingerprint !== sourceFingerprint || stageState.identity !== expectedIdentity) return false;
  if (stageState.architecture !== architecture) return false;
  if (!(await pathExists(archive))) return false;
  const facts = await fileFacts(archive);
  if (!stageState.archive || stageState.archive.file !== path.basename(archive)
    || stageState.archive.sha256 !== facts.sha256 || stageState.archive.size !== facts.size) return false;
  const canonical = await canonicalCheckpoint.read();
  if (!canonical || canonical.identity !== expectedIdentity || canonical.status !== 'completed') return false;
  if (canonical.architecture !== architecture) return false;
  if (!canonical.final || canonical.final.file !== path.basename(archive)
    || canonical.final.sha256 !== facts.sha256 || canonical.final.size !== facts.size) return false;
  return true;
}

export async function stageIsPending(canonicalCheckpoint, expectedIdentity) {
  const state = await canonicalCheckpoint.read();
  if (!state || state.identity !== expectedIdentity) return false;
  return Boolean(state.notary?.id || state.submission || state.submitAttempt);
}

export async function prepareSharedAssets({ snapshot, runtime }) {
  const root = snapshot.directory;
  const started = Date.now();
  await runCapture(runtime, 'node', ['scripts/build-ui.mjs'], { cwd: root });
  await runCapture(runtime, 'swift', ['scripts/make-icon.swift'], { cwd: root });
  for (const relative of ['electron/renderer/workspace.js', 'build/AppIcon.icns', 'build/reader-third-party-licenses.txt']) {
    if (!(await pathExists(path.join(root, relative)))) {
      throw new ReleaseStateError(`Shared release asset ${relative} was not produced.`, 'asset-missing', { asset: relative });
    }
  }
  return {
    durationMs: Date.now() - started,
    workspaceJsSha256: await hashFile(path.join(root, 'electron/renderer/workspace.js')),
    iconSha256: await hashFile(path.join(root, 'build/AppIcon.icns')),
    readerLicensesSha256: await hashFile(path.join(root, 'build/reader-third-party-licenses.txt'))
  };
}

async function verifySharedAssets({ snapshot, assets }) {
  const root = snapshot.directory;
  const current = {
    workspaceJsSha256: await hashFile(path.join(root, 'electron/renderer/workspace.js')),
    iconSha256: await hashFile(path.join(root, 'build/AppIcon.icns')),
    readerLicensesSha256: await hashFile(path.join(root, 'build/reader-third-party-licenses.txt'))
  };
  for (const key of Object.keys(current)) {
    if (current[key] !== assets[key]) {
      throw new ReleaseStateError(
        `Prepared shared asset ${key} differs from the frozen snapshot record. Refusing to mix generated UI/license content.`,
        'asset-changed', { asset: key });
    }
  }
}

async function validateArchive({ snapshot, outputDirectory, architecture, runtime }) {
  const filename = `SaveNest-${JSON.parse(await readFile(path.join(snapshot.directory, 'package.json'), 'utf8')).version}-macOS-${architecture}.zip`;
  const archive = path.join(outputDirectory, filename);
  const result = await runCapture(runtime, 'node', ['scripts/check-electron-package.mjs', archive, architecture], { cwd: snapshot.directory });
  const jsonStart = result.stdout.indexOf('{');
  let details = null;
  if (jsonStart >= 0) {
    try { details = JSON.parse(result.stdout.slice(jsonStart)); } catch { details = null; }
  }
  return { archive, filename, details };
}

async function readArtifact(outputDirectory, architecture) {
  const file = path.join(outputDirectory, architecture, 'artifact.json');
  try { return JSON.parse(await readFile(file, 'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT') {
      throw new ReleaseStateError(`Missing ${file} after packaging ${architecture}.`, 'artifact-missing', { file });
    }
    throw error;
  }
}

async function writeManifest({ outputDirectory, pkg, preflight, plan, artifacts, checks, toolchain, assets }) {
  const file = path.join(outputDirectory, 'release.json');
  let existing = null;
  if (await pathExists(file)) {
    try { existing = JSON.parse(await readFile(file, 'utf8')); } catch { existing = null; }
    if (!existing?.source?.fingerprint) {
      throw new ReleaseStateError(
        `Refusing to overwrite ${file}: it has no frozen-source provenance. Move it aside only after confirming it is obsolete.`,
        'manifest-without-provenance', { file });
    }
    if (existing.published === true) {
      throw new ReleaseStateError(`Refusing to overwrite published release manifest ${file}.`, 'manifest-published', { file });
    }
    if (existing.source.fingerprint !== plan.fingerprint || existing.version !== pkg.version) {
      throw new ReleaseStateError(
        `Refusing to overwrite ${file}: its source/version provenance differs from this run.`,
        'manifest-source-mismatch', { file });
    }
    if (existing.source.commit !== plan.provenance.commit) {
      throw new ReleaseStateError(
        `Refusing to overwrite ${file}: its captured commit ${existing.source.commit} differs from ${plan.provenance.commit}.`,
        'manifest-source-mismatch', { file });
    }
    if (existing.assets && Object.entries(existing.assets).some(([key, value]) => assets[key] !== value)) {
      throw new ReleaseStateError(
        `Refusing to overwrite ${file}: generated UI/license assets differ from the recorded snapshot content.`,
        'asset-changed', { file });
    }
    for (const [architecture, artifact] of Object.entries(existing.architectures || {})) {
      const archive = path.join(outputDirectory, artifact.file || `SaveNest-${pkg.version}-macOS-${architecture}.zip`);
      const facts = await fileFacts(archive);
      if (facts.sha256 !== artifact.sha256 || facts.size !== artifact.size) {
        throw new ReleaseStateError(`Refusing to overwrite ${file}: existing ${architecture} archive no longer matches it.`,
          'manifest-artifact-mismatch', { file, architecture });
      }
    }
  }
  const release = {
    version: pkg.version,
    build: preflight.build,
    minimumSystemVersion: '14.0',
    source: {
      fingerprint: plan.fingerprint,
      commit: existing?.source?.commit || plan.provenance.commit,
      dirty: existing?.source?.dirty ?? plan.provenance.dirty,
      dirtyFileCount: existing?.source?.dirtyFileCount ?? plan.provenance.dirtyFileCount,
      capturedAt: existing?.source?.capturedAt || plan.provenance.capturedAt || new Date().toISOString(),
      capture: plan.provenance.capture ? { fingerprint: plan.provenance.capture.fingerprint,
        commit: plan.provenance.capture.commit, dirty: plan.provenance.capture.dirty } : null,
      snapshot: `snapshots/${plan.fingerprint}`,
      files: plan.inputCount
    },
    mcp: plan.mcp ? { mode: plan.mcp.mode, fingerprint: plan.mcp.fingerprint,
      ...(plan.mcp.binaryName ? { binaryName: plan.mcp.binaryName } : {}) } : null,
    capture: plan.capture ? { mode: plan.capture.mode, fingerprint: plan.capture.fingerprint,
      commit: plan.capture.commit, dirty: plan.capture.dirty } : null,
    toolchain,
    assets,
    architectures: artifacts,
    checks,
    preparedAt: new Date().toISOString(),
    published: false
  };
  await writeJsonAtomic(file, release);
  return release;
}

function describePlan({ pkg, preflight, plan, releaseRoot, workspace, outputDirectory, env }) {
  const configured = env.SAVENEST_MCP_PACKAGE_PATH ? 'source' : env.SAVENEST_MCP_BINARY ? 'binary' : 'none';
  return [
    `Release plan for ${pkg.version} (native build ${preflight.build})`,
    `Source fingerprint: ${plan.fingerprint}`,
    `Source provenance: ${plan.provenance.commit}${plan.provenance.dirty ? ` (dirty, ${plan.provenance.dirtyFileCount} changed paths)` : ' (clean)'}`,
    `Snapshot: ${path.join(workspace, 'snapshots', plan.fingerprint)} (${plan.inputCount} inputs)`,
    `MCP input: ${configured}`,
    `Capture input: ${plan.capture ? `${plan.capture.commit}${plan.capture.dirty ? ' (dirty)' : ''}` : 'none'}`,
    `Release output: ${outputDirectory}`,
    `Persistent Swift caches: ${path.join(releaseRoot, 'caches', 'swift', '<arch>', '<toolchain-key>')}`,
    `Stages: snapshot -> shared assets -> fast checks -> arm64 + x64 (jobs=${env.RELEASE_JOBS || 2}) -> archive checks -> universal -> final archive checks -> manifest`,
    `Credentials: ${preflight.credentialsRequired ? 'required for this execution' : 'not required for --plan; real runs require SIGNING_IDENTITY and NOTARY_PROFILE'}`,
    `Missing tools (plan only): ${preflight.missingTools.join(', ') || 'none'}`,
    'Read-only plan: no files, locks, caches, credentials, signing, network, or child build processes were used.'
  ];
}

export async function executeRelease({ root = process.cwd(), env = process.env, plan = false, jobs = 2, runtime = {} } = {}) {
  const resolved = {
    exec: runtime.exec || execCapture,
    spawnStage: runtime.spawnStage || spawnChildStage,
    now: runtime.now || (() => Date.now()),
    log: runtime.log || (message => console.log(message))
  };
  const pkg = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  const preflight = await preflightRelease({ root, env, runtime: resolved, plan });
  const releaseRoot = defaultReleaseRoot(env);
  const workspace = path.join(releaseRoot, pkg.version);
  const outputDirectory = releaseOutputDirectory({ root, version: pkg.version, env });
  const planInfo = await collectSnapshotPlan({ root, env, runtime: resolved });
  planInfo.snapshotPath = path.join(workspace, 'snapshots', planInfo.fingerprint);
  planInfo.provenance.capturedAt = new Date().toISOString();
  if (plan) {
    const lines = describePlan({ pkg, preflight, plan: planInfo, releaseRoot, workspace, outputDirectory, env });
    resolved.log(lines.join('\n'));
    return { plan: true, source: planInfo, outputDirectory, lines };
  }

  const lock = await acquireReleaseLock({
    directory: releaseRoot,
    now: resolved.now,
    recoverStale: env.RELEASE_RECOVER_LOCK === '1'
  });
  const runCheckpoint = createCheckpoint({ file: path.join(workspace, 'state', 'run.json') });
  const startedAt = resolved.now();
  const timings = {};
  try {
    await mkdir(workspace, { recursive: true });
    const previousRun = await runCheckpoint.read();
    const sameSource = previousRun?.source?.fingerprint === planInfo.fingerprint;
    await runCheckpoint.write({
      schema: 1, version: pkg.version, build: preflight.build,
      source: planInfo.provenance && { ...planInfo.provenance, fingerprint: planInfo.fingerprint, snapshotPath: planInfo.snapshotPath },
      status: 'running', startedAt: new Date(startedAt).toISOString(), timings: sameSource ? previousRun.timings || {} : {}
    });
    const stage = async (name, action) => {
      const begin = resolved.now();
      try {
        const value = await action();
        timings[name] = resolved.now() - begin;
        await runCheckpoint.update(state => {
          state.timings = { ...(state.timings || {}), [name]: timings[name] };
          state.status = 'running';
        });
        return value;
      } catch (error) {
        timings[name] = resolved.now() - begin;
        await runCheckpoint.update(state => {
          state.timings = { ...(state.timings || {}), [name]: timings[name] };
          state.status = 'failed';
          state.lastFailure = { stage: name, at: new Date().toISOString(), message: String(error.message || error).slice(-2000) };
        });
        throw error;
      }
    };

    const toolchain = await stage('toolchain', () => runToolVersions({ env, runtime: resolved }));
    await stage('credentials', () =>
      runCapture(resolved, 'xcrun', ['notarytool', 'history', '--keychain-profile', env.NOTARY_PROFILE], { timeoutMs: 60 * 1000 }));

    const snapshot = await stage('snapshot', async () => {
      if (sameSource && previousRun?.status !== 'completed' && !(await pathExists(planInfo.snapshotPath))
        && (await stageHasPendingWork({ outputDirectory, identity: null }))) {
        throw new ReleaseStateError(
          `Snapshot ${planInfo.snapshotPath} is missing but pending package state exists. Refusing to recreate possibly different signed inputs.`,
          'snapshot-missing-pending');
      }
      return createSourceSnapshot({ root, destination: planInfo.snapshotPath, plan: planInfo, env });
    });

    const assets = await stage('shared-assets', async () => {
      const hasAssets = await pathExists(path.join(snapshot.directory, 'electron/renderer/workspace.js'));
      const recorded = sameSource ? previousRun?.assets : null;
      if (recorded && hasAssets) {
        await verifySharedAssets({ snapshot, assets: recorded });
        return recorded;
      }
      if (hasAssets && await pathExists(path.join(snapshot.directory, 'build/AppIcon.icns'))
        && await pathExists(path.join(snapshot.directory, 'build/reader-third-party-licenses.txt'))) {
        // The retained snapshot already contains the exact generated content;
        // reuse its hashes instead of regenerating after an interrupted run.
        const retained = {
          workspaceJsSha256: await hashFile(path.join(snapshot.directory, 'electron/renderer/workspace.js')),
          iconSha256: await hashFile(path.join(snapshot.directory, 'build/AppIcon.icns')),
          readerLicensesSha256: await hashFile(path.join(snapshot.directory, 'build/reader-third-party-licenses.txt'))
        };
        await runCheckpoint.update(state => { state.assets = retained; });
        return retained;
      }
      const prepared = await prepareSharedAssets({ snapshot, runtime: resolved });
      await runCheckpoint.update(state => { state.assets = prepared; });
      return prepared;
    });

    const identity = computeReleaseIdentity({
      version: pkg.version, build: preflight.build, sourceFingerprint: planInfo.fingerprint,
      electronVersion: pkg.devDependencies.electron, signingIdentity: env.SIGNING_IDENTITY,
      captureFingerprint: planInfo.capture?.fingerprint || ''
    });
    await runCheckpoint.update(state => { state.identity = identity; state.toolchain = toolchain; state.assets = assets; state.status = 'running'; });

    const packageResolved = await hashFile(path.join(snapshot.directory, 'Package.resolved'));
    await stage('fast-checks', () =>
      runCapture(resolved, 'npm', ['test'], { cwd: snapshot.directory, timeoutMs: 15 * 60 * 1000 }));
    const checksScratch = swiftCacheDirectory({
      releaseRoot, swiftVersion: toolchain.swift, architecture: 'checks',
      configuration: 'debug', packageResolved, captureFingerprint: planInfo.capture?.fingerprint || ''
    });
    await stage('swift-checks', () => runCapture(resolved, 'swift',
      ['run', '-c', 'debug', '--disable-automatic-resolution', '--scratch-path', checksScratch,
        '--package-path', snapshot.directory, 'SaveNestChecks'],
      { cwd: snapshot.directory, timeoutMs: 20 * 60 * 1000 }));
    const archTasks = [];
    for (const architecture of ARCHITECTURES) {
      const helper = path.join(workspace, 'helpers', architecture, 'SaveNest.app');
      const packageWork = path.join(workspace, 'packages', architecture);
      const stageCheckpoint = createCheckpoint({ file: path.join(workspace, 'state', `${architecture}.json`) });
      const releaseDirectory = outputDirectory;
      const filename = `SaveNest-${pkg.version}-macOS-${architecture}.zip`;
      const archive = path.join(releaseDirectory, filename);
      const canonicalCheckpoint = createCheckpoint({ file: path.join(releaseDirectory, '.release-state', `${architecture}.json`) });
      const stageState = await stageCheckpoint.read();
      const pending = await stageIsPending(canonicalCheckpoint, identity);
      if (await archStageIsVerified({
        stageState, canonicalCheckpoint, archive, expectedIdentity: identity,
        sourceFingerprint: planInfo.fingerprint, architecture
      })) {
        resolved.log(`Reusing verified ${architecture} archive (${filename}).`);
        continue;
      }
      const prepared = await verifyPreparedResume({
        stageState: stageCheckpoint, pending, sourceFingerprint: planInfo.fingerprint, identity,
        helper, mcpDirectory: path.join(packageWork, `mcp-${architecture}`), canonicalCheckpoint
      });
      const scratch = swiftCacheDirectory({
        releaseRoot, swiftVersion: toolchain.swift, architecture,
        configuration: 'release', packageResolved, captureFingerprint: planInfo.capture?.fingerprint || ''
      });
      const stageEnv = {
        ...env,
        CONFIGURATION: 'release', DISTRIBUTION: '1', ELECTRON_HELPER: '1', APP_PATH: helper, HELPER_APP_PATH: helper,
        TARGET_ARCH: architecture === 'x64' ? 'x86_64' : 'arm64', ELECTRON_ARCH: architecture,
        SWIFT_SCRATCH_PATH: scratch, PACKAGE_WORK_DIR: packageWork,
        RELEASE_OUTPUT_DIR: releaseDirectory, SAVENEST_RELEASE_IDENTITY: identity,
        RELEASE_REUSE_HELPER: prepared.helperReusable ? '1' : '0',
        RELEASE_REUSE_ASSETS: '1',
        RELEASE_SOURCE_SNAPSHOT: snapshot.directory
      };
      if (planInfo.capture) stageEnv.SAVENEST_PRO_CAPTURE_PACKAGE = path.join(snapshot.directory, 'capture/source');
      if (prepared.mcp) {
        stageEnv.SAVENEST_MCP_BINARY = prepared.mcp.binary;
        delete stageEnv.SAVENEST_MCP_PACKAGE_PATH;
      } else if (planInfo.mcp?.mode === 'source') {
        stageEnv.SAVENEST_MCP_PACKAGE_PATH = path.join(snapshot.directory, 'mcp/source');
        delete stageEnv.SAVENEST_MCP_BINARY;
      } else if (planInfo.mcp?.mode === 'binary') {
        stageEnv.SAVENEST_MCP_BINARY = path.join(snapshot.directory, 'mcp/binary', planInfo.mcp.binaryName);
        delete stageEnv.SAVENEST_MCP_PACKAGE_PATH;
      }
      const logDirectory = path.join(workspace, 'logs', architecture);
      archTasks.push({
        architecture, helper, packageWork, scratch, archive, filename, stageCheckpoint, canonicalCheckpoint,
        task: {
          architecture,
          command: process.execPath,
          args: ['scripts/release-arch.mjs'],
          cwd: snapshot.directory,
          env: stageEnv,
          stdoutPath: path.join(logDirectory, 'stage.stdout.log'),
          stderrPath: path.join(logDirectory, 'stage.stderr.log')
        }
      });
    }

    const archResults = await runArchStages({
      tasks: archTasks, jobs,
      spawnStage: resolved.spawnStage,
      onStart: async task => {
        await task.stageCheckpoint.write({
          schema: 1, stage: task.architecture, architecture: task.architecture, identity,
          sourceFingerprint: planInfo.fingerprint, status: 'running',
          startedAt: new Date(resolved.now()).toISOString(),
          archive: { file: task.filename }
        });
      },
      onSettled: async ({ task, result }) => {
        let prepared = {};
        try {
          prepared = await recordPreparedArtifacts({
            stageState: task.stageCheckpoint, helper: task.helper,
            mcpDirectory: path.join(task.packageWork, `mcp-${task.architecture}`)
          });
        } catch (error) {
          prepared = { recordingError: String(error.message || error) };
        }
        const ok = result.code === 0 && !result.error;
        let archive = null;
        if (ok && await pathExists(task.archive)) archive = { file: task.filename, ...await fileFacts(task.archive) };
        await task.stageCheckpoint.update(state => {
          state.status = ok && archive ? 'completed' : 'failed';
          state.finishedAt = new Date(resolved.now()).toISOString();
          state.exitCode = result.code;
          state.signal = result.signal ?? null;
          state.prepared = { ...(state.prepared || {}), ...prepared };
          if (archive) state.archive = archive;
          if (!ok) state.lastFailure = {
            at: state.finishedAt, exitCode: result.code, log: task.task.stderrPath,
            message: result.error ? String(result.error.message || result.error) : null
          };
        });
      }
    });

    const failures = archResults.filter(({ result }) => result.code !== 0 || result.error);
    const stageTimes = {};
    for (const { task } of archResults) {
      const state = await task.stageCheckpoint.read();
      if (state?.startedAt && state?.finishedAt) {
        stageTimes[task.architecture] = Date.parse(state.finishedAt) - Date.parse(state.startedAt);
      }
    }
    await runCheckpoint.update(state => { state.stageTimings = { ...(state.stageTimings || {}), ...stageTimes }; });
    if (failures.length) {
      const summary = failures.map(({ task, result }) =>
        `${task.architecture} exited ${result.code}${result.signal ? ` (${result.signal})` : ''}: ${task.task.stderrPath}`).join('; ');
      await runCheckpoint.update(state => {
        state.status = 'failed';
        state.lastFailure = { stage: 'architectures', at: new Date().toISOString(), message: summary };
      });
      throw new ReleaseStateError(
        `Release stage failed. Completed outputs were retained. ${summary}`,
        'arch-stage-failed', { failures: failures.map(({ task, result }) => ({ architecture: task.architecture, code: result.code, signal: result.signal })) });
    }

    const artifactChecks = {};
    const archArtifacts = {};
    for (const architecture of ARCHITECTURES) {
      const filename = `SaveNest-${pkg.version}-macOS-${architecture}.zip`;
      const checked = await stage(`verify-${architecture}`, () => validateArchive({ snapshot, outputDirectory, architecture, runtime: resolved }));
      const artifact = await readArtifact(outputDirectory, architecture);
      const facts = await fileFacts(path.join(outputDirectory, filename));
      if (artifact.sha256 !== facts.sha256 || artifact.size !== facts.size) {
        throw new ReleaseStateError(`Artifact metadata for ${architecture} does not match ${filename}.`, 'artifact-mismatch');
      }
      artifactChecks[architecture] = checked.details || { archive: checked.archive, architecture };
      archArtifacts[architecture] = artifact;
    }

    const universalIdentity = sha256Text(stableStringify({
      release: identity,
      archives: Object.fromEntries(Object.entries(archArtifacts).map(([name, artifact]) =>
        [name, { file: artifact.file, sha256: artifact.sha256, size: artifact.size }]))
    }));
    const universalStage = createCheckpoint({ file: path.join(workspace, 'state', 'universal.json') });
    const universalFilename = `SaveNest-${pkg.version}-macOS-universal.zip`;
    const universalArchive = path.join(outputDirectory, universalFilename);
    const universalCanonical = createCheckpoint({ file: path.join(outputDirectory, '.release-state', 'universal.json') });
    const universalState = await universalStage.read();
    if (!(await archStageIsVerified({
      stageState: universalState, canonicalCheckpoint: universalCanonical, archive: universalArchive,
      expectedIdentity: universalIdentity,
      sourceFingerprint: planInfo.fingerprint, architecture: 'universal'
    }))) {
      const pending = await stageIsPending(universalCanonical, universalIdentity);
      if (pending && !(await pathExists(universalArchive))) {
        const state = await universalCanonical.read();
        if (!state.submission || !(await pathExists(path.join(outputDirectory, `.notarize-universal.zip`)))) {
          throw new ReleaseStateError(
            'Universal notarization is pending but its submitted ZIP is missing. Refusing to rebuild different bytes.',
            'universal-submission-missing');
        }
      }
      const universalEnv = {
        ...env, RELEASE_OUTPUT_DIR: outputDirectory, SAVENEST_RELEASE_IDENTITY: universalIdentity,
        RELEASE_SOURCE_SNAPSHOT: snapshot.directory
      };
      const universalLogs = path.join(workspace, 'logs', 'universal');
      await universalStage.write({
        schema: 1, stage: 'universal', architecture: 'universal', identity: universalIdentity,
        sourceFingerprint: planInfo.fingerprint, status: 'running',
        startedAt: new Date(resolved.now()).toISOString(), archive: { file: universalFilename }
      });
      const result = await stage('universal', () => resolved.spawnStage({
        architecture: 'universal',
        command: process.execPath,
        args: ['scripts/package-electron-universal.mjs', outputDirectory],
        cwd: snapshot.directory,
        env: universalEnv,
        stdoutPath: path.join(universalLogs, 'stage.stdout.log'),
        stderrPath: path.join(universalLogs, 'stage.stderr.log')
      }));
      const ok = result.code === 0 && !result.error;
      let archiveFacts = null;
      if (ok && await pathExists(universalArchive)) archiveFacts = { file: universalFilename, ...await fileFacts(universalArchive) };
      await universalStage.update(state => {
        state.status = ok && archiveFacts ? 'completed' : 'failed';
        state.finishedAt = new Date(resolved.now()).toISOString();
        state.exitCode = result.code;
        if (archiveFacts) state.archive = archiveFacts;
        if (!ok) state.lastFailure = { at: state.finishedAt, exitCode: result.code, log: path.join(universalLogs, 'stage.stderr.log') };
      });
      if (!ok) {
        throw new ReleaseStateError(
          `Universal packaging failed (exit ${result.code}). arm64/x64 archives were retained; logs: ${universalLogs}`,
          'universal-failed', { exitCode: result.code });
      }
    } else {
      resolved.log(`Reusing verified universal archive (${universalFilename}).`);
    }

    const universalCheck = await stage('verify-universal', () =>
      validateArchive({ snapshot, outputDirectory, architecture: 'universal', runtime: resolved }));
    artifactChecks.universal = universalCheck.details || { archive: universalCheck.archive, architecture: 'universal' };
    const universalArtifact = await readArtifact(outputDirectory, 'universal');
    const universalFacts = await fileFacts(universalArchive);
    if (universalArtifact.sha256 !== universalFacts.sha256 || universalArtifact.size !== universalFacts.size) {
      throw new ReleaseStateError('Universal artifact metadata does not match the final archive.', 'artifact-mismatch');
    }
    archArtifacts.universal = universalArtifact;

    await stage('manifest', async () => {
      const release = await writeManifest({
        outputDirectory, pkg, preflight, plan: { ...planInfo, snapshotPath: snapshot.directory },
        artifacts: archArtifacts, checks: artifactChecks, toolchain, assets
      });
      await writeFile(path.join(outputDirectory, 'local-staging-path.txt'), snapshot.directory + '\n', { mode: 0o600 });
      await runCheckpoint.update(state => {
        state.status = 'completed';
        state.finishedAt = new Date().toISOString();
        state.manifest = path.join(outputDirectory, 'release.json');
        state.artifacts = Object.fromEntries(Object.entries(archArtifacts).map(([name, artifact]) =>
          [name, { file: artifact.file, sha256: artifact.sha256, size: artifact.size }]));
        state.timings = { ...(state.timings || {}), ...timings };
      });
      return release;
    });

    const elapsed = resolved.now() - startedAt;
    const timingLines = Object.entries({ ...timings, ...stageTimes })
      .filter(([, duration]) => typeof duration === 'number')
      .map(([name, duration]) => `  ${name}: ${(duration / 1000).toFixed(1)}s`);
    resolved.log([
      `Release prepared in ${(elapsed / 1000).toFixed(1)}s.`,
      'Stage timings:', ...timingLines,
      `Artifacts: ${Object.keys(archArtifacts).join(', ')} under ${outputDirectory}.`,
      `Snapshot retained at ${snapshot.directory}. Nothing was signed out of band or published.`
    ].join('\n'));
    return { artifacts: archArtifacts, checks: artifactChecks, outputDirectory, snapshot: snapshot.directory, identity, timings: { ...timings, ...stageTimes } };
  } finally {
    await lock.release().catch(() => {});
  }
}

async function stageHasPendingWork({ outputDirectory, identity }) {
  for (const architecture of ['arm64', 'x64', 'universal']) {
    const checkpoint = createCheckpoint({ file: path.join(outputDirectory, '.release-state', `${architecture}.json`) });
    const state = await checkpoint.read().catch(() => null);
    if (state && (!identity || state.identity === identity) && (state.notary?.id || state.submission)) return true;
  }
  return false;
}

export async function main(argv = process.argv.slice(2), env = process.env) {
  const plan = argv.includes('--plan') || argv.includes('--dry-run');
  if (!plan && (!env.SAVENEST_PRO_CAPTURE_PACKAGE || !(env.SAVENEST_MCP_PACKAGE_PATH || env.SAVENEST_MCP_BINARY))) {
    throw new Error('Official releases require the reviewed Pro capture and MCP components. Public builds use npm run build.');
  }
  const jobsFlag = argv.find(argument => argument.startsWith('--jobs='));
  const jobs = Number(jobsFlag ? jobsFlag.split('=')[1] : env.RELEASE_JOBS || 2);
  if (!Number.isInteger(jobs) || jobs < 1) throw new Error('--jobs must be a positive integer.');
  return executeRelease({ root: process.cwd(), env, plan, jobs });
}
