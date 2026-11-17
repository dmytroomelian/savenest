'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { mkdtemp, mkdir, readFile, readdir, rm, writeFile } = require('node:fs/promises');
const { tmpdir } = require('node:os');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

const VERSION = '1.2.3';
const COMMIT = 'a'.repeat(40);
const REPO = 'dmytroomelian/savenest';
const SCRIPT = path.resolve(__dirname, '../../scripts/publish-electron-release.mjs');
let loaded;
const load = () => loaded ||= import(pathToFileURL(SCRIPT).href);

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const digest = value => `sha256:${value}`;

async function makeFixture({ dirty = false, omitUniversal = false } = {}) {
  const root = await mkdtemp(path.join(tmpdir(), 'savenest-publish-'));
  const releaseDir = path.join(root, 'release');
  await mkdir(releaseDir, { recursive: true });
  const archives = {};
  const architectures = {};
  const tag = `v${VERSION}`;
  for (const architecture of ['arm64', 'x64', 'universal']) {
    if (omitUniversal && architecture === 'universal') continue;
    const bytes = Buffer.from(`fake immutable zip for ${VERSION} ${architecture}\n`);
    const file = `SaveNest-${VERSION}-macOS-${architecture}.zip`;
    const url = `https://github.com/${REPO}/releases/download/${tag}/${file}`;
    const artifact = { architecture, file, url, sha256: sha256(bytes), size: bytes.length };
    archives[architecture] = bytes;
    architectures[architecture] = artifact;
    await writeFile(path.join(releaseDir, file), bytes);
    await mkdir(path.join(releaseDir, architecture), { recursive: true });
    await writeFile(path.join(releaseDir, architecture, 'artifact.json'), `${JSON.stringify(artifact, null, 2)}\n`);
    if (architecture !== 'universal') {
      const feed = {
        currentRelease: VERSION,
        releases: [{
          version: VERSION,
          updateTo: {
            version: VERSION, url, name: `Savenest ${VERSION}`, notes: 'Fixture notes.',
            pub_date: '2026-11-17T00:00:00.000Z', sha256: artifact.sha256, size: artifact.size
          }
        }]
      };
      await writeFile(path.join(releaseDir, architecture, 'RELEASES.json'), `${JSON.stringify(feed, null, 2)}\n`);
    }
  }
  const manifest = {
    version: VERSION,
    build: 42,
    minimumSystemVersion: '14.0',
    source: {
      fingerprint: sha256(Buffer.from('fixture snapshot')),
      commit: COMMIT,
      dirty,
      dirtyFileCount: dirty ? 2 : 0,
      capturedAt: '2026-11-17T00:00:00.000Z',
      snapshot: '/fixture/snapshot',
      files: {}
    },
    mcp: false,
    toolchain: {},
    assets: {},
    architectures,
    checks: [],
    preparedAt: '2026-11-17T00:00:00.000Z',
    published: false
  };
  await writeFile(path.join(releaseDir, 'release.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  const notes = path.join(root, 'notes.md');
  await writeFile(notes, 'Release notes for the fixture.\n');
  const website = path.join(root, 'site');
  await mkdir(path.join(website, 'downloads'), { recursive: true });
  return { root, releaseDir, archives, architectures, manifest, notes, website, tag };
}

function makeRunner({ tagCommit = COMMIT } = {}) {
  const calls = [];
  return {
    calls,
    async run(stage, command, args = []) {
      calls.push({ stage, command, args: [...args] });
      if (command === 'git') {
        const ref = args[args.length - 1] || '';
        if (ref.startsWith('refs/tags/')) {
          return tagCommit
            ? { code: 0, stdout: `${tagCommit}\n`, stderr: '', signal: null }
            : { code: 1, stdout: '', stderr: '', signal: null };
        }
      }
      return { code: 0, stdout: '', stderr: '', signal: null };
    }
  };
}

const validator = manifest => async ({ architecture, facts }) => ({
  version: manifest.version, build: String(manifest.build), architecture,
  sha256: facts.sha256, checks: ['fixture package evidence']
});

function makeClient({ release = null, commit = COMMIT, onUpload, viewSequence = null } = {}) {
  let current = release ? structuredClone(release) : null;
  let viewIndex = 0;
  const calls = [];
  const nextView = () => viewSequence
    ? viewSequence[Math.min(viewIndex++, viewSequence.length - 1)]
    : current;
  return {
    calls,
    get current() { return current; },
    async view() {
      calls.push({ op: 'view' });
      const value = nextView();
      return value ? structuredClone(value) : null;
    },
    async createDraft({ tag, target, title, notesFile }) {
      calls.push({ op: 'createDraft', tag, target, title, notesFile });
      current = {
        tagName: tag, isDraft: true, targetCommitish: target,
        url: `https://github.com/${REPO}/releases/tag/${tag}`, assets: []
      };
    },
    async editDraft({ tag, title, notesFile }) {
      calls.push({ op: 'editDraft', tag, title, notesFile });
      if (!current) throw new Error('no draft to edit');
    },
    async upload({ tag, file, asset }) {
      calls.push({ op: 'upload', tag, file });
      if (onUpload) await onUpload({ tag, file, asset });
      current.assets.push({ name: path.basename(file), size: asset.size, digest: digest(asset.sha256) });
    },
    async promote({ tag, notesFile }) {
      calls.push({ op: 'promote', tag, notesFile });
      current.isDraft = false;
    },
    async resolveCommit(ref) {
      calls.push({ op: 'resolveCommit', ref });
      return commit;
    }
  };
}

function releaseAssets(manifest) {
  return Object.values(manifest.architectures).map(artifact => ({
    name: artifact.file, size: artifact.size, digest: digest(artifact.sha256)
  }));
}

function publicRelease(fixture, assets = releaseAssets(fixture.manifest)) {
  return {
    tagName: fixture.tag, isDraft: false, targetCommitish: COMMIT,
    url: `https://github.com/${REPO}/releases/tag/${fixture.tag}`, assets
  };
}

async function inventory(root) {
  const entries = [];
  async function visit(directory, relative) {
    for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const child = path.join(directory, entry.name);
      const childRelative = path.join(relative, entry.name);
      entries.push(`${entry.isDirectory() ? 'd' : 'f'}:${childRelative}`);
      if (entry.isDirectory()) await visit(child, childRelative);
    }
  }
  await visit(root, '');
  return entries;
}

function makeFetch(fixture, overrides = {}) {
  const calls = [];
  const bodies = new Map(Object.entries(fixture.architectures).map(([architecture, artifact]) => [
    artifact.url, overrides[architecture] || fixture.archives[architecture]
  ]));
  return {
    calls,
    async fetch(url) {
      calls.push(url);
      const bytes = bodies.get(url);
      if (!bytes) return { ok: false, status: 404, arrayBuffer: async () => new ArrayBuffer(0) };
      return {
        ok: true, status: 200,
        arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
      };
    }
  };
}

async function run(fixture, options, extra = {}) {
  const mod = await load();
  const runner = extra.runner || makeRunner();
  const lines = [];
  const result = await mod.runPublication(
    { repo: REPO, releaseDir: fixture.releaseDir, ...options },
    {
      runner,
      client: extra.client,
      fetchImpl: extra.fetch ? extra.fetch.fetch : undefined,
      validatePackage: extra.validatePackage || validator(fixture.manifest),
      log: line => lines.push(line),
      now: () => Date.parse('2026-11-17T00:00:00.000Z')
    }
  );
  return { result, runner, lines };
}

const stateFile = fixture => path.join(fixture.releaseDir, '.publish-state.json');
const assertMissing = async file => assert.rejects(readFile(file), error => error.code === 'ENOENT');

test('plan is read-only and lists all three artifacts and destinations', async () => {
  const fixture = await makeFixture();
  const client = makeClient();
  const { result, runner } = await run(fixture, { action: 'plan' }, { client });
  assert.equal(result.action, 'plan');
  assert.deepEqual(result.artifacts.map(artifact => artifact.architecture), ['arm64', 'x64', 'universal']);
  assert.equal(result.github.url, `https://github.com/${REPO}/releases/tag/${fixture.tag}`);
  assert.equal(client.calls.length, 0);
  assert.equal(runner.calls.filter(call => call.command === 'gh').length, 0);
  assert.equal((await readFile(path.join(fixture.releaseDir, 'release.json'), 'utf8')),
    `${JSON.stringify(fixture.manifest, null, 2)}\n`);
  await assertMissing(stateFile(fixture));
});

test('default production plan writes no files and skips the package checker', async () => {
  const fixture = await makeFixture();
  const before = await inventory(fixture.root);
  const mod = await load();
  let checkerCalls = 0;
  const result = await mod.runPublication(
    { action: 'plan', repo: REPO, releaseDir: fixture.releaseDir },
    { log: () => {}, validatePackage: async () => { checkerCalls++; throw new Error('plan must not run the checker'); } }
  );
  const after = await inventory(fixture.root);
  assert.equal(result.action, 'plan');
  assert.deepEqual(after, before);
  assert.equal(checkerCalls, 0);
  await assertMissing(path.join(fixture.releaseDir, '.publish-logs'));
  await assertMissing(stateFile(fixture));
});

test('a corrupt archive is rejected before any remote mutation', async () => {
  const fixture = await makeFixture();
  const archive = path.join(fixture.releaseDir, fixture.architectures.arm64.file);
  await writeFile(archive, Buffer.concat([fixture.archives.arm64, Buffer.from('tampered')]));
  const client = makeClient();
  await assert.rejects(
    run(fixture, { action: 'draft', notesFile: fixture.notes }, { client }),
    /sha256|size/
  );
  assert.equal(client.calls.length, 0);
  await assertMissing(stateFile(fixture));
});

test('a release without universal is rejected', async () => {
  const fixture = await makeFixture({ omitUniversal: true });
  await assert.rejects(
    run(fixture, { action: 'plan' }),
    /universal/i
  );
});

test('a missing universal archive is rejected', async () => {
  const fixture = await makeFixture();
  await rm(path.join(fixture.releaseDir, fixture.architectures.universal.file));
  await assert.rejects(
    run(fixture, { action: 'plan' }),
    /Missing universal/i
  );
});

test('dirty source may plan but blocks remote actions', async () => {
  const fixture = await makeFixture({ dirty: true });
  const plan = await run(fixture, { action: 'plan' });
  assert.match(plan.result.warnings.join(' '), /dirty/i);
  const client = makeClient();
  await assert.rejects(
    run(fixture, { action: 'draft', notesFile: fixture.notes }, { client }),
    /dirty source snapshot/i
  );
  assert.equal(client.calls.length, 0);
});

test('an existing public release is immutable', async () => {
  const fixture = await makeFixture();
  const assets = releaseAssets(fixture.manifest);
  assets[0] = { ...assets[0], digest: digest('0'.repeat(64)) };
  const client = makeClient({
    release: {
      tagName: fixture.tag, isDraft: false, targetCommitish: COMMIT,
      url: `https://github.com/${REPO}/releases/tag/${fixture.tag}`, assets
    }
  });
  await assert.rejects(
    run(fixture, { action: 'draft', notesFile: fixture.notes }, { client }),
    /immutable/i
  );
  assert.deepEqual(client.calls.filter(call => ['createDraft', 'editDraft', 'upload', 'promote'].includes(call.op)), []);
});

test('draft resume stops on an unverifiable checksum conflict', async () => {
  const fixture = await makeFixture();
  const assets = releaseAssets(fixture.manifest);
  const arm64Index = assets.findIndex(asset => asset.name === fixture.architectures.arm64.file);
  assets[arm64Index] = { ...assets[arm64Index], digest: digest('f'.repeat(64)) };
  const client = makeClient({
    release: {
      tagName: fixture.tag, isDraft: true, targetCommitish: COMMIT,
      url: `https://github.com/${REPO}/releases/tag/${fixture.tag}`, assets
    }
  });
  await assert.rejects(
    run(fixture, { action: 'draft', notesFile: fixture.notes }, { client }),
    /refusing to replace/i
  );
  assert.equal(client.calls.filter(call => call.op === 'upload').length, 0);
  assert.equal(client.calls.filter(call => call.op === 'editDraft').length, 0);
});

test('draft preflight rejects any present conflict even when another asset is missing', async () => {
  const fixture = await makeFixture();
  const assets = releaseAssets(fixture.manifest).filter(asset => asset.name !== fixture.architectures.arm64.file);
  const x64Index = assets.findIndex(asset => asset.name === fixture.architectures.x64.file);
  assets[x64Index] = { ...assets[x64Index], digest: digest('e'.repeat(64)) };
  const client = makeClient({
    release: {
      tagName: fixture.tag, isDraft: true, targetCommitish: COMMIT,
      url: `https://github.com/${REPO}/releases/tag/${fixture.tag}`, assets
    }
  });
  await assert.rejects(
    run(fixture, { action: 'draft', notesFile: fixture.notes }, { client }),
    /x64.*different sha256/s
  );
  assert.deepEqual(client.calls.filter(call => ['createDraft', 'editDraft', 'upload', 'promote'].includes(call.op)), []);
});

test('draft stops before mutation when the draft becomes public between reads', async () => {
  const fixture = await makeFixture();
  const draft = {
    tagName: fixture.tag, isDraft: true, targetCommitish: COMMIT,
    url: `https://github.com/${REPO}/releases/tag/${fixture.tag}`, assets: []
  };
  const client = makeClient({ viewSequence: [draft, publicRelease(fixture)] });
  await assert.rejects(
    run(fixture, { action: 'draft', notesFile: fixture.notes }, { client }),
    /no longer an open draft/i
  );
  assert.deepEqual(client.calls.filter(call => ['createDraft', 'editDraft', 'upload', 'promote'].includes(call.op)), []);
});

test('draft uploads missing artifacts and records resumable state', async () => {
  const fixture = await makeFixture();
  const client = makeClient();
  const { result } = await run(fixture, { action: 'draft', notesFile: fixture.notes }, { client });
  assert.equal(result.status, 'draft-ready');
  assert.equal(client.current.isDraft, true);
  assert.equal(client.calls.filter(call => call.op === 'upload').length, 3);
  const state = JSON.parse(await readFile(stateFile(fixture), 'utf8'));
  assert.equal(state.status, 'draft-ready');
  assert.equal(state.tag, fixture.tag);
  assert.deepEqual(Object.keys(state.uploads).sort(), ['arm64', 'universal', 'x64']);
  assert.ok(Object.values(state.uploads).every(upload => upload.status === 'uploaded'));
});

test('gh invocations use argv arrays, notes files, and no clobber', async () => {
  const fixture = await makeFixture();
  const runner = makeRunner();
  const mod = await load();
  const client = new mod.GhReleaseClient({ runner, repo: REPO });
  await client.createDraft({ tag: fixture.tag, target: COMMIT, title: 'Savenest', notesFile: '/tmp/notes.md' });
  await client.upload({ tag: fixture.tag, file: '/tmp/archive.zip' });
  await client.promote({ tag: fixture.tag, notesFile: '/tmp/notes.md' });
  const ghCalls = runner.calls.filter(call => call.command === 'gh');
  assert.equal(ghCalls.length, 3);
  assert.ok(ghCalls.every(call => Array.isArray(call.args)));
  assert.ok(ghCalls.every(call => !call.args.includes('--clobber')));
  assert.deepEqual(ghCalls[1].args, ['release', 'upload', fixture.tag, '/tmp/archive.zip', '--repo', REPO]);
  assert.ok(ghCalls[0].args.includes('--notes-file'));
  assert.ok(ghCalls[2].args.includes('--notes-file'));
});

test('public promotion is a separate call that never uploads', async () => {
  const fixture = await makeFixture();
  const client = makeClient({
    release: {
      tagName: fixture.tag, isDraft: true, targetCommitish: COMMIT,
      url: `https://github.com/${REPO}/releases/tag/${fixture.tag}`,
      assets: releaseAssets(fixture.manifest)
    }
  });
  const { result } = await run(fixture, { action: 'publish', notesFile: fixture.notes }, { client });
  assert.equal(result.status, 'published');
  assert.equal(client.current.isDraft, false);
  assert.equal(client.calls.filter(call => call.op === 'promote').length, 1);
  assert.equal(client.calls.filter(call => call.op === 'upload').length, 0);
});

test('public verification mismatch prevents feed writes', async () => {
  const fixture = await makeFixture();
  const fetch = makeFetch(fixture, { x64: Buffer.from('wrong public bytes\n') });
  const client = makeClient({ release: publicRelease(fixture) });
  await assert.rejects(
    run(fixture, { action: 'verify', websiteDir: fixture.website }, { fetch, client }),
    /No feed was staged/
  );
  for (const architecture of ['arm64', 'x64']) {
    await assertMissing(path.join(fixture.website, 'downloads/electron', architecture, 'RELEASES.json'));
  }
  await assertMissing(stateFile(fixture));
});

test('a missing website root gives a concrete instruction and writes nothing', async () => {
  const fixture = await makeFixture();
  const fetch = makeFetch(fixture);
  const client = makeClient({ release: publicRelease(fixture) });
  await assert.rejects(
    run(fixture, { action: 'verify', websiteDir: path.join(fixture.root, 'missing-site') }, { fetch, client }),
    /existing static-public-root.*downloads/i
  );
  assert.equal(fetch.calls.length, 0);
  await assertMissing(stateFile(fixture));
});

test('verification rejects a remote tag that differs from the manifest', async () => {
  const fixture = await makeFixture();
  const fetch = makeFetch(fixture);
  const client = makeClient({ release: publicRelease(fixture), commit: 'b'.repeat(40) });
  await assert.rejects(
    run(fixture, { action: 'verify', websiteDir: fixture.website }, { fetch, client }),
    /Remote tag .* points to/i
  );
  assert.equal(fetch.calls.length, 0);
  for (const architecture of ['arm64', 'x64']) {
    await assertMissing(path.join(fixture.website, 'downloads/electron', architecture, 'RELEASES.json'));
  }
});

test('successful public verification stages exact feeds atomically', async () => {
  const fixture = await makeFixture();
  const fetch = makeFetch(fixture);
  const client = makeClient({ release: publicRelease(fixture) });
  const { result } = await run(fixture, { action: 'verify', websiteDir: fixture.website }, { fetch, client });
  assert.equal(result.status, 'feeds-staged');
  assert.deepEqual(fetch.calls, Object.values(fixture.architectures).map(artifact => artifact.url));
  for (const architecture of ['arm64', 'x64']) {
    const source = JSON.parse(await readFile(path.join(fixture.releaseDir, architecture, 'RELEASES.json'), 'utf8'));
    const stagedPath = path.join(fixture.website, 'downloads/electron', architecture, 'RELEASES.json');
    const staged = JSON.parse(await readFile(stagedPath, 'utf8'));
    assert.deepEqual(staged, source);
    const leftovers = (await readdir(path.dirname(stagedPath))).filter(name => name.startsWith('.savenest-release-'));
    assert.deepEqual(leftovers, []);
  }
  const state = JSON.parse(await readFile(stateFile(fixture), 'utf8'));
  assert.equal(state.status, 'feeds-staged');
  assert.equal(state.tag, fixture.tag);
  assert.equal(state.feeds.root, fixture.website);
});
