'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const { lstatSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');

const sha256 = text => createHash('sha256').update(text).digest('hex');
const load = () => import('../../scripts/release-orchestrator.mjs');
const releaseState = () => import('../../scripts/release-state.mjs');

async function temporary(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'savenest-orchestrator-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return directory;
}

async function write(root, relative, content = '') {
  const file = path.join(root, relative);
  await fs.mkdir(path.dirname(file), { recursive: true });
  await fs.writeFile(file, content);
}

async function repository(t, { version = '1.0.0' } = {}) {
  const root = await temporary(t);
  const publicKey = Buffer.alloc(32, 7).toString('base64');
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>42</string>
<key>SUPublicEDKey</key><string>${publicKey}</string>
</dict></plist>`;
  await write(root, 'package.json', JSON.stringify({
    name: 'fixture', version, main: 'electron/main.cjs',
    devDependencies: { electron: '1.2.3' }, dependencies: {}
  }, null, 2));
  await write(root, 'package-lock.json', JSON.stringify({
    name: 'fixture', version, lockfileVersion: 3,
    packages: { '': { name: 'fixture', version }, 'node_modules/electron': { version: '1.2.3' } }
  }, null, 2));
  await write(root, 'node_modules/electron/package.json', JSON.stringify({ name: 'electron', version: '1.2.3' }));
  await write(root, 'Resources/Info.plist', plist);
  await write(root, `Resources/ReleaseNotes/${version}.html`, '<h1>Notes</h1>');
  for (const file of ['Package.swift', 'Package.resolved', 'Resources/Electron.entitlements',
    'Resources/SaveNest.entitlements', 'scripts/build-app.sh', 'scripts/build-ui.mjs', 'scripts/build-services.mjs',
    'scripts/mcp-package.mjs', 'scripts/social-capture-package.mjs', 'electron/native/services.m',
    'scripts/make-icon.swift', 'scripts/package-electron.mjs', 'scripts/package-electron-universal.mjs',
    'scripts/check-electron-package.mjs', 'scripts/release-arch.mjs', 'electron/renderer/workspace-entry.js',
    'LICENSE', 'THIRD_PARTY_NOTICES.md']) {
    await write(root, file, `${file}\n`);
  }
  await write(root, 'Sources/SaveNest/App.swift', 'struct App {}\n');
  await write(root, 'Tests/SaveNestCoreTests/AppTests.swift', '// test input\n');
  await write(root, '.gitignore', 'build/\n.build/\ndist/\nelectron/renderer/workspace.js\n');
  execFileSync('git', ['init', '-q'], { cwd: root });
  execFileSync('git', ['-c', 'user.email=test@example.com', '-c', 'user.name=Test', 'add', '.'], { cwd: root });
  execFileSync('git', ['-c', 'user.email=test@example.com', '-c', 'user.name=Test', 'commit', '-qm', 'fixture'], { cwd: root });
  return root;
}

async function captureRepository(t) {
  const root = await temporary(t);
  await write(root, 'Package.swift', '// capture package\n');
  await write(root, 'Package.resolved', JSON.stringify({ pins: [], version: 3 }));
  await write(root, 'LICENSE', 'SaveNest Pro Capture component license\n'.repeat(3));
  await write(root, 'THIRD_PARTY_NOTICES.txt', 'Capture dependency notices\n'.repeat(3));
  await write(root, 'Sources/ProCapture/Capture.swift', 'let captureVersion = 1\n');
  execFileSync('git', ['init', '-q'], { cwd: root });
  execFileSync('git', ['-c', 'user.email=test@example.com', '-c', 'user.name=Test', 'add', '.'], { cwd: root });
  execFileSync('git', ['-c', 'user.email=test@example.com', '-c', 'user.name=Test', 'commit', '-qm', 'capture fixture'], { cwd: root });
  return root;
}

function baseEnv(work, extra = {}) {
  return { PATH: process.env.PATH, RELEASE_WORK_DIR: work, ...extra };
}

function fakeCommandRuntime({ onBuildUi, onCheck, spawnStage, calls = [] } = {}) {
  onBuildUi = onBuildUi || (async cwd => write(cwd, 'electron/renderer/workspace.js', 'bundle-v1'));
  const exec = async (command, args, options = {}) => {
    calls.push({ command, args, cwd: options.cwd });
    if (command === 'git') {
      return new Promise(resolve => {
        const { execFile } = require('node:child_process');
        execFile(command, args, { cwd: options.cwd, encoding: 'utf8' }, (error, stdout, stderr) =>
          resolve({ code: error ? 1 : 0, stdout: stdout || '', stderr: stderr || '' }));
      });
    }
    if (command === 'swift' && args[0] === '--version') return { code: 0, stdout: 'Swift version 6.0 (test)\n', stderr: '' };
    if (command === 'node' && args[0] === '--version') return { code: 0, stdout: 'v22.12.0\n', stderr: '' };
    if (command === 'npm' && args[0] === 'test') return { code: 0, stdout: '', stderr: '' };
    if (command === 'xcrun' && args[0] === 'notarytool') return { code: 0, stdout: '', stderr: '' };
    if (command === 'swift' && args.includes('SaveNestChecks')) return { code: 0, stdout: '', stderr: '' };
    if (command === 'node' && args[0] === 'scripts/build-ui.mjs') {
      if (onBuildUi) await onBuildUi(options.cwd);
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'swift' && args[0] === 'scripts/make-icon.swift') {
      await write(options.cwd, 'build/AppIcon.icns', 'icon');
      await write(options.cwd, 'build/reader-third-party-licenses.txt', 'licenses');
      return { code: 0, stdout: '', stderr: '' };
    }
    if (command === 'node' && args[0] === 'scripts/check-electron-package.mjs') {
      if (onCheck) return onCheck(args[1], args[2]);
      return { code: 0, stdout: JSON.stringify({ archive: args[1], architecture: args[2] }), stderr: '' };
    }
    throw new Error(`Unexpected command in fake runtime: ${command} ${args.join(' ')}`);
  };
  return { exec, spawnStage, calls };
}

function archSpawner({ output, fail = new Set(), order = [], barrier = null } = {}) {
  return async task => {
    order.push(`start:${task.architecture}`);
    if (barrier) await barrier(task.architecture);
    if (fail.has(task.architecture)) {
      order.push(`fail:${task.architecture}`);
      return { code: 1, signal: null };
    }
    const version = '1.0.0';
    const artifactDirectory = task.architecture === 'universal' ? 'universal' : task.architecture;
    try {
      const existing = JSON.parse(await fs.readFile(path.join(output, '.release-state', `${task.architecture}.json`), 'utf8'));
      if (existing.identity !== task.env.SAVENEST_RELEASE_IDENTITY) {
        order.push(`stale:${task.architecture}`);
        return { code: 1, signal: null };
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (task.architecture !== 'universal') {
      assert.equal(task.env.DISTRIBUTION, '1');
      assert.equal(task.env.RELEASE_REUSE_ASSETS, '1');
      assert.equal(task.env.CONFIGURATION, 'release');
    }
    if (task.architecture !== 'universal' && task.env.APP_PATH) {
      await write(path.join(task.env.APP_PATH, 'Contents/MacOS'), 'SaveNest', 'helper-binary');
      await write(path.join(task.env.APP_PATH, 'Contents'), 'Info.plist', 'helper-plist');
    }
    if (task.architecture === 'universal') {
      const file = `SaveNest-${version}-macOS-universal.zip`;
      const bytes = Buffer.from('universal-zip');
      await write(output, file, bytes);
      const artifact = { architecture: 'universal', file, url: `https://example.test/${file}`, sha256: sha256(bytes), size: bytes.length };
      await write(output, `universal/artifact.json`, JSON.stringify(artifact));
      await write(output, '.release-state/universal.json', JSON.stringify({
        schema: 1, identity: task.env.SAVENEST_RELEASE_IDENTITY, architecture: 'universal', version,
        status: 'completed', final: { file, sha256: artifact.sha256, size: artifact.size }
      }));
    } else {
      const file = `SaveNest-${version}-macOS-${task.architecture}.zip`;
      const bytes = Buffer.from(`${task.architecture}-zip`);
      await write(output, file, bytes);
      const artifact = { architecture: task.architecture, file, url: `https://example.test/${file}`, sha256: sha256(bytes), size: bytes.length };
      await write(output, `${artifactDirectory}/artifact.json`, JSON.stringify(artifact));
      await write(output, `.release-state/${task.architecture}.json`, JSON.stringify({
        schema: 1, identity: task.env.SAVENEST_RELEASE_IDENTITY, architecture: task.architecture, version,
        status: 'completed', final: { file, sha256: artifact.sha256, size: artifact.size }
      }));
    }
    order.push(`finish:${task.architecture}`);
    return { code: 0, signal: null };
  };
}

async function runFake({ root, work, output, spawn = archSpawner({ output }), env = {}, execOptions = {} }) {
  const { executeRelease } = await load();
  const runtime = fakeCommandRuntime({ ...execOptions, spawnStage: spawn });
  const environment = baseEnv(work, {
    SIGNING_IDENTITY: 'test-identity', NOTARY_PROFILE: 'test-profile',
    RELEASE_OUTPUT_DIR: output,
    ...env
  });
  return executeRelease({ root, env: environment, runtime, jobs: 2 });
}

test('plan is read-only, needs no credentials, and makes no build children', async t => {
  const root = await repository(t);
  const work = path.join(await temporary(t), 'work');
  let spawned = 0;
  const { executeRelease } = await load();
  const result = await executeRelease({
    root, plan: true,
    env: baseEnv(work, { RELEASE_OUTPUT_DIR: path.join(work, 'out') }),
    runtime: fakeCommandRuntime({ spawnStage: async () => { spawned++; return { code: 0 }; } })
  });
  assert.equal(result.plan, true);
  assert.equal(spawned, 0);
  assert.match(result.lines.join('\n'), /Read-only plan/);
  await assert.rejects(fs.access(work), error => error.code === 'ENOENT');
});

test('snapshot fingerprint includes dirty/untracked source and Tests, excludes generated outputs', async t => {
  const root = await repository(t);
  const work = await temporary(t);
  await write(root, 'Sources/SaveNest/New.swift', '// untracked but not ignored\n');
  await write(root, 'build/generated.txt', 'generated');
  await write(root, '.build/cache.txt', 'cache');
  await write(root, 'electron/renderer/workspace.js', 'generated bundle');
  const { collectSnapshotPlan, createSourceSnapshot } = await load();
  const plan = await collectSnapshotPlan({ root, env: baseEnv(work) });
  assert.ok(plan.entries.some(entry => entry.path === 'Sources/SaveNest/New.swift'));
  assert.ok(plan.entries.some(entry => entry.path === 'Tests/SaveNestCoreTests/AppTests.swift'));
  assert.ok(plan.entries.some(entry => entry.path === 'Package.swift'));
  assert.equal(plan.entries.some(entry => entry.path.startsWith('build/')), false);
  assert.equal(plan.entries.some(entry => entry.path.startsWith('.build/')), false);
  assert.equal(plan.entries.some(entry => entry.path === 'electron/renderer/workspace.js'), false);
  assert.equal(plan.provenance.dirty, true);

  const destination = path.join(work, 'snapshots', plan.fingerprint);
  await createSourceSnapshot({ root, destination, plan, env: baseEnv(work) });
  assert.ok((await fs.stat(path.join(destination, 'Tests/SaveNestCoreTests/AppTests.swift'))).isFile());
  assert.ok(lstatSync(path.join(destination, 'node_modules')).isSymbolicLink());
  await assert.rejects(fs.access(path.join(destination, 'build/generated.txt')));

  await fs.writeFile(path.join(root, 'Sources/SaveNest/New.swift'), '// changed\n');
  const changed = await collectSnapshotPlan({ root, env: baseEnv(work) });
  assert.notEqual(changed.fingerprint, plan.fingerprint);
  await assert.rejects(createSourceSnapshot({ root, destination, plan: changed, env: baseEnv(work) }),
    error => error.code === 'snapshot-mismatch');
});

test('optional MCP binaries are part of the snapshot identity and missing notices are rejected', async t => {
  const root = await repository(t);
  const work = await temporary(t);
  const mcp = path.join(work, 'mcp');
  await write(mcp, 'savenest-mcp', 'binary-v1');
  await write(mcp, 'LICENSE', 'M'.repeat(80));
  await write(mcp, 'THIRD_PARTY_NOTICES.txt', 'N'.repeat(80));
  const { collectSnapshotPlan } = await load();
  const env = baseEnv(work, { SAVENEST_MCP_BINARY: path.join(mcp, 'savenest-mcp') });
  const first = await collectSnapshotPlan({ root, env });
  assert.ok(first.entries.some(entry => entry.path === 'mcp/binary/savenest-mcp'));
  await fs.writeFile(path.join(mcp, 'savenest-mcp'), 'binary-v2');
  const second = await collectSnapshotPlan({ root, env });
  assert.notEqual(second.fingerprint, first.fingerprint);
  await fs.rm(path.join(mcp, 'LICENSE'));
  await assert.rejects(collectSnapshotPlan({ root, env }), error => error.code === 'input-missing');
});

test('capture source is frozen, fingerprinted and independent of later edits', async t => {
  const root = await repository(t);
  const capture = await captureRepository(t);
  const work = await temporary(t);
  const { collectSnapshotPlan, createSourceSnapshot, swiftCacheDirectory } = await load();
  const env = baseEnv(work, { SAVENEST_PRO_CAPTURE_PACKAGE: capture });
  const plan = await collectSnapshotPlan({ root, env });
  assert.ok(plan.entries.some(entry => entry.path === 'capture/source/Sources/ProCapture/Capture.swift'));
  assert.equal(plan.capture.commit.length, 40);
  assert.equal(plan.capture.dirty, false);
  const destination = path.join(work, 'snapshots', plan.fingerprint);
  await createSourceSnapshot({ root, destination, plan, env });
  const frozen = path.join(destination, 'capture/source/Sources/ProCapture/Capture.swift');
  assert.equal(await fs.readFile(frozen, 'utf8'), 'let captureVersion = 1\n');

  await fs.writeFile(path.join(capture, 'Sources/ProCapture/Capture.swift'), 'let captureVersion = 2\n');
  await createSourceSnapshot({ root, destination, plan, env });
  assert.equal(await fs.readFile(frozen, 'utf8'), 'let captureVersion = 1\n');
  const changed = await collectSnapshotPlan({ root, env });
  assert.notEqual(changed.fingerprint, plan.fingerprint);
  assert.notEqual(swiftCacheDirectory({ releaseRoot: work, swiftVersion: 'Swift 6', architecture: 'arm64',
    configuration: 'release', packageResolved: 'lock', captureFingerprint: plan.capture.fingerprint }),
  swiftCacheDirectory({ releaseRoot: work, swiftVersion: 'Swift 6', architecture: 'arm64',
    configuration: 'release', packageResolved: 'lock', captureFingerprint: changed.capture.fingerprint }));

  await fs.writeFile(frozen, 'let captureVersion = 3\n');
  await assert.rejects(createSourceSnapshot({ root, destination, plan, env }),
    error => error.code === 'snapshot-mutated');
});

test('release lock rejects contention and releases atomically', async t => {
  const directory = await temporary(t);
  const { acquireReleaseLock } = await load();
  const first = await acquireReleaseLock({ directory });
  await assert.rejects(acquireReleaseLock({ directory }), error => error.code === 'release-lock-held');
  await first.release();
  const second = await acquireReleaseLock({ directory });
  await second.release();
});

test('arch branches start together, universal waits, and completed peer output survives failure', async t => {
  const root = await repository(t);
  const work = await temporary(t);
  const output = path.join(work, 'out');
  const seen = [];
  let releaseBarrier;
  const bothStarted = new Promise(resolve => { releaseBarrier = resolve; });
  const started = new Set();
  const barrier = async architecture => {
    started.add(architecture);
    if (started.size === 2) releaseBarrier();
    await bothStarted;
  };
  const spawn = archSpawner({ output, order: seen, barrier });
  const result = await runFake({ root, work, output, spawn });
  assert.equal(Object.keys(result.artifacts).length, 3);
  assert.ok(seen.indexOf('start:arm64') < seen.indexOf('finish:arm64'));
  assert.ok(seen.indexOf('start:x64') < seen.indexOf('finish:x64'));
  const firstFinish = Math.min(seen.indexOf('finish:arm64'), seen.indexOf('finish:x64'));
  assert.ok(seen.indexOf('start:universal') > firstFinish);
  assert.ok(seen.indexOf('start:universal') > seen.indexOf('finish:arm64'));
  assert.ok(seen.indexOf('start:universal') > seen.indexOf('finish:x64'));

  const failingRoot = await repository(t);
  const failingWork = await temporary(t);
  const failingOutput = path.join(failingWork, 'out');
  const failing = archSpawner({ output: failingOutput, fail: new Set(['x64']) });
  await assert.rejects(runFake({ root: failingRoot, work: failingWork, output: failingOutput, spawn: failing }),
    error => error.code === 'arch-stage-failed');
  assert.ok((await fs.stat(path.join(failingOutput, 'SaveNest-1.0.0-macOS-arm64.zip'))).isFile());
  await assert.rejects(fs.access(path.join(failingOutput, 'SaveNest-1.0.0-macOS-universal.zip')));
});

test('resume skips only verified same-source stages and prepares shared assets once', async t => {
  const root = await repository(t);
  const work = await temporary(t);
  const output = path.join(work, 'out');
  let builds = 0;
  let spawned = 0;
  const spawn = async task => { spawned++; return archSpawner({ output })(task); };
  const execOptions = { onBuildUi: async cwd => {
    builds++;
    await write(cwd, 'electron/renderer/workspace.js', 'bundle-v1');
  } };
  await runFake({ root, work, output, spawn, execOptions });
  assert.equal(builds, 1);
  assert.equal(spawned, 3);
  const second = await runFake({ root, work, output, spawn, execOptions });
  assert.equal(spawned, 3, 'verified completed stages must not be rebuilt');
  assert.equal(builds, 1, 'shared UI assets are generated once');
  assert.equal(second.artifacts.arm64.file, 'SaveNest-1.0.0-macOS-arm64.zip');

  await fs.writeFile(path.join(root, 'Sources/SaveNest/App.swift'), 'struct App { let changed = true }\n');
  let thirdSpawned = 0;
  const thirdSpawn = async task => { thirdSpawned++; return archSpawner({ output })(task); };
  await assert.rejects(runFake({ root, work, output, spawn: thirdSpawn, execOptions }), error =>
    error.code === 'arch-stage-failed' || error.code === 'stale-state');
  assert.ok(thirdSpawned > 0, 'changed source must not reuse the old completed stages');
});

test('pending notarization refuses to rebuild a missing signed helper', async t => {
  const root = await repository(t);
  const work = await temporary(t);
  const output = path.join(work, 'out');
  await runFake({ root, work, output, spawn: archSpawner({ output }) });
  const helper = path.join(work, '1.0.0', 'helpers', 'arm64', 'SaveNest.app');
  assert.ok((await fs.stat(helper)).isDirectory());
  await fs.rm(helper, { recursive: true, force: true });
  await fs.rm(path.join(output, 'SaveNest-1.0.0-macOS-arm64.zip'));
  const stateFile = path.join(output, '.release-state', 'arm64.json');
  const state = JSON.parse(await fs.readFile(stateFile, 'utf8'));
  await fs.writeFile(stateFile, JSON.stringify({
    ...state, status: 'submitted', notary: { id: 'sub-1', status: 'Accepted' },
    submission: { file: '.notarize-arm64.zip', sha256: 'a'.repeat(64), size: 1 }
  }));
  let spawned = 0;
  await assert.rejects(runFake({ root, work, output, spawn: async task => { spawned++; return archSpawner({ output })(task); } }),
    error => error.code === 'helper-missing');
  assert.equal(spawned, 0);
});

test('snapshot rejects symlinks, stale copies, and retained-byte tampering', async t => {
  const root = await repository(t);
  const work = await temporary(t);
  const { collectSnapshotPlan, createSourceSnapshot } = await load();
  const link = path.join(root, 'Sources/SaveNest/Link.swift');
  await fs.symlink('App.swift', link);
  await assert.rejects(collectSnapshotPlan({ root, env: baseEnv(work) }), error => error.code === 'input-symlink');
  await fs.unlink(link);

  const plan = await collectSnapshotPlan({ root, env: baseEnv(work) });
  const destination = path.join(work, 'snapshots', plan.fingerprint);
  await createSourceSnapshot({ root, destination, plan, env: baseEnv(work) });
  const app = path.join(destination, 'Sources/SaveNest/App.swift');
  assert.equal(await fs.readFile(app, 'utf8'), 'struct App {}\n');

  await fs.writeFile(path.join(root, 'Sources/SaveNest/App.swift'), 'struct App { let later = true }\n');
  assert.equal(await fs.readFile(app, 'utf8'), 'struct App {}\n', 'original source changes must not mutate the snapshot');
  await fs.writeFile(app, 'tampered\n');
  await assert.rejects(createSourceSnapshot({ root, destination, plan, env: baseEnv(work) }),
    error => error.code === 'snapshot-mutated');

  const otherRoot = await repository(t);
  const stale = await collectSnapshotPlan({ root: otherRoot, env: baseEnv(work) });
  await fs.writeFile(path.join(otherRoot, 'Sources/SaveNest/App.swift'), 'changed before copy\n');
  await assert.rejects(createSourceSnapshot({ root: otherRoot,
    destination: path.join(work, 'snapshots', stale.fingerprint), plan: stale, env: baseEnv(work) }),
  error => error.code === 'snapshot-mutated');
});

test('stage bookkeeping failure waits for the peer branch before reporting', async t => {
  const { runArchStages } = await load();
  let peerFinished = false;
  let releasePeer;
  const gate = new Promise(resolve => { releasePeer = resolve; });
  const tasks = [
    { architecture: 'arm64', task: { architecture: 'arm64' } },
    { architecture: 'x64', task: { architecture: 'x64' } }
  ];
  const results = await runArchStages({
    tasks, jobs: 2,
    spawnStage: async task => {
      if (task.architecture === 'arm64') return { code: 1, signal: null };
      await gate;
      peerFinished = true;
      return { code: 0, signal: null };
    },
    onSettled: async ({ task }) => {
      if (task.architecture === 'arm64') {
        releasePeer();
        throw new Error('recording failed');
      }
    }
  });
  assert.equal(peerFinished, true);
  const arm = results.find(entry => entry.task.architecture === 'arm64');
  assert.match(String(arm.result.error), /recording failed/);
  assert.equal(results.find(entry => entry.task.architecture === 'x64').result.code, 0);
});
