import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  ReleaseStateError, createCheckpoint, createCommandRunner, fileFacts,
  pathExists, stableStringify, writeJsonAtomic
} from './release-state.mjs';

// Publication-only tooling. It never builds, signs, notarizes, commits, tags,
// deploys, or replaces an asset. Every remote mutation is explicit and uses
// argv arrays through the existing gh CLI. Tests inject fake clients.

export const DEFAULT_REPOSITORY = 'dmytroomelian/savenest';
export const ARCHITECTURES = ['arm64', 'x64', 'universal'];
export const PUBLICATION_STATE_SCHEMA = 1;
const VERSION_PATTERN = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
const SHA256_PATTERN = /^[0-9a-f]{64}$/;
const COMMIT_PATTERN = /^[0-9a-f]{7,64}$/;

const USAGE = `Usage: npm run release:publish -- [--plan|--draft|--publish|--verify] [options]

  --plan                 Read-only publication plan (default).
  --draft                Create or update the GitHub draft, upload missing assets.
  --publish              Promote an existing complete draft to public. Separate invocation.
  --verify               Download the exact public ZIP URLs, check sha256/size, then
                         stage arm64/x64 RELEASES.json when --website-dir is supplied.
  --release-dir <dir>    Release directory containing release.json
                         (default: the single build/releases/electron/<version> entry).
  --website-dir <dir>    Existing static-public-root containing downloads/. Never deployed.
  --notes-file <file>    Release notes passed to gh with --notes-file.
  --title <text>         Release title (default: Savenest <version>).
  --repo <owner/name>    GitHub repository (default: ${DEFAULT_REPOSITORY}).
  --help                 Show this text.`;

function fail(code, message, details = {}) {
  throw new ReleaseStateError(message, code, details);
}

// Plan is strictly read-only: no log directory, state file, temp files, or
// package extraction. Git is still consulted through argv arrays.
function createNoDiskRunner() {
  return {
    async run(stage, command, args = [], options = {}) {
      return new Promise(resolve => {
        execFile(command, args, {
          encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
          ...(options.timeoutMs ? { timeout: options.timeoutMs } : {})
        }, (error, stdout, stderr) => resolve({
          code: error ? (typeof error.code === 'number' ? error.code : 1) : 0,
          stdout: stdout ?? '', stderr: stderr ?? '', signal: error?.signal ?? null
        }));
      });
    }
  };
}

function sha256Bytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex');
}

function isDirectory(info) {
  return Boolean(info && info.isDirectory());
}

function normalizeCommit(value) {
  return String(value || '').trim().toLowerCase();
}

function parseJsonObject(text) {
  const start = String(text || '').indexOf('{');
  const end = String(text || '').lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try { return JSON.parse(String(text).slice(start, end + 1)); }
  catch { return null; }
}

export function parseArguments(argv) {
  const options = {
    action: 'plan', releaseDir: null, websiteDir: null, notesFile: null,
    title: null, repo: DEFAULT_REPOSITORY, help: false
  };
  let actionSet = false;
  const setAction = action => {
    if (actionSet && options.action !== action) fail('usage', `Choose only one action; received --${options.action} and --${action}.`);
    options.action = action;
    actionSet = true;
  };
  for (let index = 0; index < argv.length; index++) {
    let flag = argv[index];
    let inlineValue;
    if (flag.startsWith('--') && flag.includes('=')) {
      inlineValue = flag.slice(flag.indexOf('=') + 1);
      flag = flag.slice(0, flag.indexOf('='));
    }
    const take = () => {
      if (inlineValue !== undefined) return inlineValue;
      const value = argv[++index];
      if (!value || value.startsWith('--')) fail('usage', `${flag} requires a value.\n\n${USAGE}`);
      return value;
    };
    switch (flag) {
      case '--plan': setAction('plan'); break;
      case '--draft': setAction('draft'); break;
      case '--publish': setAction('publish'); break;
      case '--verify': setAction('verify'); break;
      case '--release-dir': options.releaseDir = take(); break;
      case '--website-dir': options.websiteDir = take(); break;
      case '--notes-file': options.notesFile = take(); break;
      case '--title': options.title = take(); break;
      case '--repo': options.repo = take(); break;
      case '--help': options.help = true; break;
      default: fail('usage', `Unknown argument ${flag}.\n\n${USAGE}`);
    }
  }
  if (!/^[^/\s]+\/[^/\s]+$/.test(options.repo)) fail('usage', `--repo must be owner/name, received ${options.repo}.`);
  return options;
}

async function resolveReleaseDir(explicit) {
  if (explicit) return path.resolve(explicit);
  const root = path.resolve('build/releases/electron');
  let entries;
  try { entries = await readdir(root, { withFileTypes: true }); }
  catch (error) {
    if (error.code === 'ENOENT') fail('release-dir-required', `No ${root}. Pass --release-dir <build/releases/electron/<version>>.`);
    throw error;
  }
  const candidates = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const directory = path.join(root, entry.name);
    if (await pathExists(path.join(directory, 'release.json'))) candidates.push(directory);
  }
  if (candidates.length === 1) return candidates[0];
  fail('release-dir-required',
    `Expected exactly one release directory under ${root}, found ${candidates.length}. ` +
    'Pass --release-dir <build/releases/electron/<version>> explicitly.');
}

function expectedArtifact(version, architecture, repo) {
  const file = `SaveNest-${version}-macOS-${architecture}.zip`;
  return {
    architecture, file, tag: `v${version}`,
    url: `https://github.com/${repo}/releases/download/v${version}/${file}`
  };
}

function validateManifest(manifest, { repo }) {
  if (!manifest || typeof manifest !== 'object') fail('manifest-invalid', 'release.json must contain an object.');
  if (!VERSION_PATTERN.test(manifest.version)) fail('manifest-invalid', `release.json has an invalid version: ${manifest.version}`);
  if (!/^[1-9]\d*$/.test(String(manifest.build))) fail('manifest-invalid', `release.json has an invalid build: ${manifest.build}`);
  const source = manifest.source;
  if (!source || !SHA256_PATTERN.test(String(source.fingerprint))) fail('manifest-invalid', 'release.json source.fingerprint must be a sha256.');
  if (!COMMIT_PATTERN.test(normalizeCommit(source.commit))) fail('manifest-invalid', 'release.json source.commit must be a git commit.');
  if (typeof source.dirty !== 'boolean') fail('manifest-invalid', 'release.json source.dirty must be a boolean.');
  if (!manifest.architectures || typeof manifest.architectures !== 'object') fail('manifest-invalid', 'release.json is missing architectures.');
  const assets = {};
  for (const architecture of ARCHITECTURES) {
    const artifact = manifest.architectures[architecture];
    if (!artifact) fail('incomplete-release', `release.json is missing the required ${architecture} artifact. Universal is mandatory.`);
    const expected = expectedArtifact(manifest.version, architecture, repo);
    if (artifact.architecture !== architecture) fail('manifest-invalid', `${architecture} artifact.architecture is ${artifact.architecture}.`);
    if (artifact.file !== expected.file) fail('manifest-invalid', `${architecture} file must be ${expected.file}, found ${artifact.file}.`);
    if (artifact.url !== expected.url) fail('manifest-invalid', `${architecture} URL must be ${expected.url}, found ${artifact.url}.`);
    if (!SHA256_PATTERN.test(String(artifact.sha256))) fail('manifest-invalid', `${architecture} sha256 is invalid.`);
    if (!Number.isSafeInteger(artifact.size) || artifact.size <= 0) fail('manifest-invalid', `${architecture} size is invalid.`);
    assets[architecture] = { ...expected, sha256: artifact.sha256, size: artifact.size };
  }
  return { tag: `v${manifest.version}`, assets };
}

async function verifyArchiveMetadata({ directory, manifest, assets, architecture }) {
  const file = path.join(directory, architecture, 'artifact.json');
  if (!(await pathExists(file))) return;
  let metadata;
  try { metadata = JSON.parse(await readFile(file, 'utf8')); }
  catch (error) { fail('artifact-metadata-invalid', `${file} is not valid JSON: ${error.message}`); }
  const expected = assets[architecture];
  const problems = [];
  if (metadata.architecture !== architecture) problems.push('architecture');
  if (metadata.file !== expected.file) problems.push('file');
  if (metadata.url !== expected.url) problems.push('url');
  if (metadata.sha256 !== expected.sha256) problems.push('sha256');
  if (metadata.size !== expected.size) problems.push('size');
  if (problems.length) fail('artifact-metadata-mismatch', `${file} does not match the release manifest: ${problems.join(', ')}.`);
}

async function verifyArchives({ directory, manifest, assets }) {
  const verified = {};
  const seen = new Set();
  for (const architecture of ARCHITECTURES) {
    const expected = assets[architecture];
    const archive = path.join(directory, expected.file);
    if (path.basename(expected.file) !== expected.file) fail('manifest-invalid', `Unsafe artifact name: ${expected.file}`);
    if (seen.has(archive)) fail('manifest-invalid', `Architecture ${architecture} reuses another artifact path.`);
    seen.add(archive);
    let facts;
    try { facts = await fileFacts(archive); }
    catch (error) {
      if (error.code === 'ENOENT') {
        fail('artifact-missing', `Missing ${architecture} archive ${archive}. Refusing an incomplete release; do not rebuild or rename existing assets.`);
      }
      throw error;
    }
    if (facts.sha256 !== expected.sha256) {
      fail('archive-hash-mismatch', `${architecture} archive sha256 ${facts.sha256} does not match release.json ${expected.sha256}.`);
    }
    if (facts.size !== expected.size) {
      fail('archive-size-mismatch', `${architecture} archive size ${facts.size} does not match release.json ${expected.size}.`);
    }
    await verifyArchiveMetadata({ directory, manifest, assets, architecture });
    verified[architecture] = { ...expected, path: archive, sha256: facts.sha256, size: facts.size };
  }
  return verified;
}

async function checkSource({ manifest, tag, action, runner }) {
  const source = manifest.source;
  const commit = normalizeCommit(source.commit);
  if (action !== 'plan' && source.dirty) {
    fail('dirty-provenance',
      `release.json records a dirty source snapshot (${source.dirtyFileCount ?? 'unknown'} files). ` +
      'Remote draft, publish, verification, and feed staging require committed source provenance. ' +
      `Rebuild from commit ${commit}; this tool will not commit, tag, or rewrite the manifest.`);
  }
  const result = await runner.run('git-tag-commit', 'git',
    ['rev-parse', '--verify', '--quiet', `refs/tags/${tag}^{commit}`], { allowFailure: true });
  const tagCommit = result.code === 0 ? normalizeCommit(result.stdout) : null;
  if (tagCommit && tagCommit !== commit) {
    fail('tag-source-mismatch',
      `Tag ${tag} points to ${tagCommit}, but release.json source is ${commit}. ` +
      'Refusing to publish or retag automatically; reconcile the tag with the manifest.');
  }
  return {
    commit, fingerprint: source.fingerprint, dirty: source.dirty,
    dirtyFileCount: Number(source.dirtyFileCount ?? 0),
    snapshot: source.snapshot ?? null, tag, tagCommit, tagExists: Boolean(tagCommit)
  };
}

async function runPackageCheck({ runner, manifest, assets, architecture }) {
  const checker = fileURLToPath(new URL('./check-electron-package.mjs', import.meta.url));
  const artifact = assets[architecture];
  const result = await runner.run(`package-check-${architecture}`, process.execPath,
    [checker, artifact.path, architecture], { timeoutMs: 30 * 60 * 1000 });
  const payload = parseJsonObject(result.stdout);
  if (!payload) fail('package-evidence-missing', `check-electron-package.mjs returned no JSON evidence for ${architecture}.`);
  return payload;
}

async function verifyPackageEvidence({ runner, manifest, assets, validatePackage }) {
  for (const architecture of ARCHITECTURES) {
    const artifact = assets[architecture];
    const evidence = validatePackage
      ? await validatePackage({ architecture, archive: artifact.path, facts: artifact, manifest })
      : await runPackageCheck({ runner, manifest, assets, architecture });
    const problems = [];
    if (evidence?.version !== manifest.version) problems.push('version');
    if (String(evidence?.build) !== String(manifest.build)) problems.push('build');
    if (evidence?.architecture !== architecture) problems.push('architecture');
    if (evidence?.sha256 !== artifact.sha256) problems.push('sha256');
    if (evidence?.archive && path.resolve(evidence.archive) !== path.resolve(artifact.path)) problems.push('archive');
    if (!Array.isArray(evidence?.checks) || !evidence.checks.length) problems.push('checks');
    if (problems.length) {
      fail('package-evidence-mismatch',
        `Package validation evidence for ${architecture} does not match release.json: ${problems.join(', ')}.`);
    }
  }
}

function assetIdentity(assets) {
  return Object.fromEntries(ARCHITECTURES.map(architecture => [architecture, {
    file: assets[architecture].file, url: assets[architecture].url,
    sha256: assets[architecture].sha256, size: assets[architecture].size
  }]));
}

function assertPublicationState(state, { manifest, tag, repo, assets, stateFile }) {
  if (!state) return;
  const problems = [];
  if (state.version !== manifest.version) problems.push('version');
  if (state.tag !== tag) problems.push('tag');
  if (state.repo !== repo) problems.push('repository');
  if (state.sourceCommit !== normalizeCommit(manifest.source.commit)) problems.push('source commit');
  if (state.sourceFingerprint !== manifest.source.fingerprint) problems.push('source fingerprint');
  if (stableStringify(state.assets) !== stableStringify(assetIdentity(assets))) problems.push('assets');
  if (problems.length) {
    fail('publication-state-mismatch',
      `Existing publication state ${stateFile} belongs to a different ${problems.join(', ')}. ` +
      'Move it aside only after confirming the old publication is obsolete; it is never overwritten silently.');
  }
}

function stateIdentity({ manifest, tag, repo, assets, now }) {
  return {
    version: manifest.version, tag, repo,
    sourceCommit: normalizeCommit(manifest.source.commit),
    sourceFingerprint: manifest.source.fingerprint,
    assets: assetIdentity(assets), createdAt: new Date(now()).toISOString()
  };
}

async function updateState(ctx, mutator) {
  return ctx.checkpoint.update(state => {
    const identity = stateIdentity(ctx);
    if (state.createdAt) delete identity.createdAt;
    Object.assign(state, identity);
    mutator(state);
  });
}

async function resolveNotes({ options, manifest }) {
  const candidate = options.notesFile
    ? path.resolve(options.notesFile)
    : path.resolve('Resources/ReleaseNotes', `${manifest.version}.md`);
  try {
    const [text, details] = await Promise.all([readFile(candidate, 'utf8'), stat(candidate)]);
    if (!text.trim()) fail('notes-empty', `Release notes ${candidate} are empty.`);
    return { path: candidate, sha256: sha256Bytes(Buffer.from(text)), size: details.size, exists: true };
  } catch (error) {
    if (error.code === 'ENOENT') return { path: candidate, exists: false };
    if (error.code) throw error;
    return { path: candidate, exists: false };
  }
}

function matchAsset(asset, expected) {
  if (!asset) return { ok: false, reason: 'missing' };
  if (Number(asset.size) !== expected.size) return { ok: false, reason: 'size' };
  if (!asset.digest) return { ok: false, reason: 'digest-unavailable' };
  const digest = String(asset.digest).toLowerCase();
  const normalized = digest.startsWith('sha256:') ? digest : `sha256:${digest}`;
  if (normalized !== `sha256:${expected.sha256}`) return { ok: false, reason: 'digest' };
  return { ok: true };
}

function inspectAssets(assets, expected) {
  const problems = [];
  for (const architecture of ARCHITECTURES) {
    const artifact = expected[architecture];
    const asset = (assets || []).find(candidate => candidate.name === artifact.file);
    const match = matchAsset(asset, artifact);
    if (!match.ok) problems.push({ architecture, reason: match.reason, asset: asset ?? null });
  }
  if (!problems.length) return { ok: true, problems: [] };
  return { ok: false, problems, ...problems[0] };
}

function assetProblem(result, expected) {
  const problems = result.problems || [result];
  return problems.map(problem => {
    const artifact = expected[problem.architecture];
    const detail = {
      missing: `has no asset named ${artifact.file}`,
      size: `asset ${artifact.file} has the wrong size; refusing to replace it`,
      'digest-unavailable': `asset ${artifact.file} has no sha256 digest, so its bytes are unverifiable; refusing to resume`,
      digest: `asset ${artifact.file} has a different sha256; refusing to replace it`
    }[problem.reason];
    return `${problem.architecture} ${detail || 'does not match'} (expected ${artifact.size} bytes, sha256 ${artifact.sha256}).`;
  }).join(' ');
}

function presentAssetConflicts(result) {
  return (result.problems || []).filter(problem => problem.reason !== 'missing');
}

export class GhReleaseClient {
  constructor({ runner, repo }) {
    this.runner = runner;
    this.repo = repo;
  }

  async view(tag) {
    const result = await this.runner.run('gh-release-view', 'gh',
      ['release', 'view', tag, '--repo', this.repo, '--json',
        'tagName,isDraft,isPrerelease,targetCommitish,url,assets'], { allowFailure: true });
    if (result.code !== 0) {
      if (/not found|HTTP 404/i.test(`${result.stderr} ${result.stdout}`)) return null;
      fail('gh-view-failed', `gh release view ${tag} failed: ${(result.stderr || result.stdout).trim()}`);
    }
    try { return JSON.parse(result.stdout); }
    catch (error) { fail('gh-view-invalid', `gh release view ${tag} returned invalid JSON: ${error.message}`); }
  }

  async createDraft({ tag, target, title, notesFile }) {
    await this.runner.run('gh-release-create', 'gh',
      ['release', 'create', tag, '--repo', this.repo, '--draft', '--title', title,
        '--notes-file', notesFile, '--target', target]);
  }

  async editDraft({ tag, title, notesFile }) {
    await this.runner.run('gh-release-edit', 'gh',
      ['release', 'edit', tag, '--repo', this.repo, '--draft', '--title', title,
        '--notes-file', notesFile]);
  }

  async upload({ tag, file }) {
    await this.runner.run('gh-release-upload', 'gh',
      ['release', 'upload', tag, file, '--repo', this.repo]);
  }

  async promote({ tag, notesFile }) {
    const args = ['release', 'edit', tag, '--repo', this.repo, '--draft=false'];
    if (notesFile) args.push('--notes-file', notesFile);
    await this.runner.run('gh-release-promote', 'gh', args);
  }

  async resolveCommit(ref) {
    const result = await this.runner.run('gh-commit', 'gh',
      ['api', `repos/${this.repo}/commits/${encodeURIComponent(ref)}`, '--jq', '.sha'], { allowFailure: true });
    return result.code === 0 ? normalizeCommit(result.stdout) : null;
  }
}

async function verifyRemoteSource({ client, source, release, tag }) {
  if (release.tagName && release.tagName !== tag) {
    fail('release-source-mismatch', `Release is ${release.tagName}, expected ${tag}.`);
  }
  const tagCommit = await client.resolveCommit(tag);
  if (tagCommit) {
    if (tagCommit !== source.commit) {
      fail('release-source-mismatch',
        `Remote tag ${tag} points to ${tagCommit}, but release.json source is ${source.commit}. Refusing to move or retag it.`);
    }
    return;
  }
  const target = release.targetCommitish || release.tagName || tag;
  if (!/^[0-9a-f]{7,64}$/i.test(target) || normalizeCommit(target) !== source.commit) {
    fail('release-source-unverifiable',
      `Remote tag ${tag} is absent and the draft targets ${target}, not the manifest commit ${source.commit}. ` +
      'Create the tag explicitly or recreate the draft targeting that commit; this tool will not retag or publish from a movable ref.');
  }
}

async function prepare({ options, runner, now, validatePackage }) {
  const directory = await resolveReleaseDir(options.releaseDir);
  const manifestPath = path.join(directory, 'release.json');
  let manifest;
  try { manifest = JSON.parse(await readFile(manifestPath, 'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT') fail('manifest-missing', `No release manifest at ${manifestPath}.`);
    fail('manifest-invalid', `${manifestPath} is not valid JSON: ${error.message}`);
  }
  const { tag, assets } = validateManifest(manifest, { repo: options.repo });
  const commandRunner = runner || (options.action === 'plan'
    ? createNoDiskRunner()
    : createCommandRunner({ logDirectory: path.join(directory, '.publish-logs'), now }));
  const source = await checkSource({ manifest, tag, action: options.action, runner: commandRunner });
  const verifiedAssets = await verifyArchives({ directory, manifest, assets });
  if (options.action !== 'plan') {
    await verifyPackageEvidence({ runner: commandRunner, manifest, assets: verifiedAssets, validatePackage });
  }
  const stateFile = path.join(directory, '.publish-state.json');
  const checkpoint = createCheckpoint({ file: stateFile, now });
  const state = await checkpoint.read();
  assertPublicationState(state, { manifest, tag, repo: options.repo, assets: verifiedAssets, stateFile });
  return {
    options, directory, manifestPath, manifest, tag, repo: options.repo,
    assets: verifiedAssets, source, state, stateFile, checkpoint,
    runner: commandRunner, now, log: options.log || (line => process.stdout.write(`${line}\n`))
  };
}

async function planResult(ctx) {
  const { manifest, tag, repo, assets, source, options, stateFile } = ctx;
  const website = options.websiteDir ? path.resolve(options.websiteDir) : null;
  const notes = options.notesFile
    ? path.resolve(options.notesFile)
    : path.resolve('Resources/ReleaseNotes', `${manifest.version}.md`);
  const notesExist = await pathExists(notes);
  const warnings = [];
  if (source.dirty) warnings.push('Source snapshot is dirty; remote actions are blocked until committed provenance matches.');
  if (!source.tagExists) warnings.push(`Local tag ${tag} is absent; --draft targets ${source.commit}. No tag is created silently.`);
  ctx.log(`Savenest ${manifest.version} publication plan (read-only)`);
  ctx.log(`Repository: ${repo}`);
  ctx.log(`Tag: ${tag}`);
  ctx.log(`Source: ${source.commit} (${source.dirty ? 'dirty snapshot' : 'committed'}); fingerprint ${source.fingerprint}`);
  if (source.tagExists) ctx.log(`Tag commit: ${source.tagCommit}`);
  ctx.log('Artifacts (immutable; never rebuilt or replaced):');
  for (const architecture of ARCHITECTURES) {
    const artifact = assets[architecture];
    ctx.log(`  ${architecture.padEnd(9)} ${artifact.file}  ${artifact.size} bytes  sha256 ${artifact.sha256}`);
  }
  ctx.log(`GitHub destination: https://github.com/${repo}/releases/tag/${tag}`);
  ctx.log(`  draft action:   npm run release:publish -- --draft --notes-file ${notes}`);
  ctx.log(`  public action:  npm run release:publish -- --publish`);
  ctx.log(`Feed destination: ${website ? path.join(website, 'downloads/electron/<arm64|x64>/RELEASES.json') : 'not supplied; pass --website-dir <existing static-public-root containing downloads/>'}`);
  ctx.log(`Notes: ${notes}`);
  ctx.log(`Publication state: ${stateFile}${ctx.state ? ` (status ${ctx.state.status || 'unknown'})` : ''}`);
  for (const warning of warnings) ctx.log(`Warning: ${warning}`);
  return {
    action: 'plan', version: manifest.version, tag, repo, source,
    artifacts: ARCHITECTURES.map(architecture => ({ ...assets[architecture] })),
    github: { tag, url: `https://github.com/${repo}/releases/tag/${tag}` },
    feed: { websiteDir: website, architectures: ['arm64', 'x64'] },
    notes: { path: notes, exists: notesExist },
    stateFile, warnings
  };
}

async function assertOpenDraft({ client, source, tag, release }) {
  if (!release || release.isDraft !== true) {
    fail('draft-not-open', `Release ${tag} is no longer an open draft. Stopping before any edit or upload; no published asset was changed.`);
  }
  await verifyRemoteSource({ client, source, release, tag });
  return release;
}

async function draft(ctx, client) {
  const { tag, source, assets, manifest, options } = ctx;
  let release = await client.view(tag);
  if (release) await verifyRemoteSource({ client, source, release, tag });
  if (release && release.isDraft === false) {
    const match = inspectAssets(release.assets, assets);
    if (match.ok) return { action: 'draft', status: 'already-published', tag, url: release.url };
    fail('published-release-immutable',
      `Public release ${tag} is immutable and ${assetProblem(match, assets)} No asset was replaced.`);
  }

  const notes = await resolveNotes({ options, manifest });
  if (!notes.exists) fail('notes-missing', `Release notes not found at ${notes.path}. Pass --notes-file <file>; gh bodies always use --notes-file.`);

  if (!release && ctx.state?.uploads && Object.values(ctx.state.uploads).some(entry => entry.status === 'started' || entry.status === 'unknown')) {
    fail('upload-ambiguous',
      'Publication state records an upload attempt, but GitHub has no release to reconcile it against. ' +
      `Confirm the remote outcome, then remove uploads from ${ctx.stateFile} before retrying.`);
  }

  if (release) {
    release = await assertOpenDraft({ client, source, tag, release: await client.view(tag) });
    const conflicts = presentAssetConflicts(inspectAssets(release.assets, assets));
    if (conflicts.length) {
      fail('draft-asset-conflict', `Draft ${tag} ${assetProblem({ problems: conflicts }, assets)} Resolve it manually; assets are never replaced.`);
    }
    await client.editDraft({ tag, title: options.title || `Savenest ${manifest.version}`, notesFile: notes.path });
    release = await client.view(tag);
  } else {
    if (await client.view(tag)) {
      fail('draft-state-changed', `Release ${tag} appeared while planning the draft. Rerun --draft to inspect it; nothing was created.`);
    }
    await client.createDraft({
      tag, target: source.commit, title: options.title || `Savenest ${manifest.version}`, notesFile: notes.path
    });
    release = await client.view(tag);
  }

  release = await assertOpenDraft({ client, source, tag, release });

  const preflight = inspectAssets(release.assets, assets);
  const conflicts = presentAssetConflicts(preflight);
  if (conflicts.length) {
    fail('draft-asset-conflict', `Draft ${tag} ${assetProblem({ problems: conflicts }, assets)} Resolve it manually; assets are never replaced.`);
  }

  await updateState(ctx, state => {
    state.status = 'draft-created';
    state.notes = { path: notes.path, sha256: notes.sha256, size: notes.size };
    state.draft = { tag, url: release.url ?? `https://github.com/${ctx.repo}/releases/tag/${tag}` };
  });

  for (const architecture of ARCHITECTURES) {
    release = await assertOpenDraft({ client, source, tag, release: await client.view(tag) });
    const artifact = assets[architecture];
    const existing = (release.assets || []).find(candidate => candidate.name === artifact.file);
    if (existing) {
      const match = matchAsset(existing, artifact);
      if (!match.ok) fail('draft-asset-conflict', `Draft ${tag} ${assetProblem({ ...match, architecture }, assets)}`);
      continue;
    }
    const prior = ctx.state?.uploads?.[architecture];
    if (prior?.status === 'started' || prior?.status === 'unknown') {
      fail('upload-ambiguous',
        `A previous ${architecture} upload may have reached GitHub but is not visible as a matching asset. ` +
        `Confirm it remotely, then remove uploads.${architecture} from ${ctx.stateFile} before retrying.`);
    }
    await updateState(ctx, state => {
      state.status = 'uploading';
      state.uploads = state.uploads || {};
      state.uploads[architecture] = {
        status: 'started', file: artifact.file, sha256: artifact.sha256, size: artifact.size,
        startedAt: new Date(ctx.now()).toISOString()
      };
    });
    try {
      await client.upload({ tag, file: artifact.path, asset: artifact });
    } catch (error) {
      await updateState(ctx, state => {
        state.uploads[architecture] = { ...state.uploads[architecture], status: 'unknown', error: String(error.message).slice(0, 800) };
      });
      const after = await client.view(tag).catch(() => null);
      const found = after && (after.assets || []).find(candidate => candidate.name === artifact.file);
      if (!found) {
        fail('upload-ambiguous',
          `Uploading ${artifact.file} failed or timed out and the asset is not visible: ${error.message}. ` +
          `Reconcile GitHub before retrying; ${ctx.stateFile} records the attempt.`);
      }
      const match = matchAsset(found, artifact);
      if (!match.ok) fail('upload-unverified', `Uploaded ${artifact.file} could not be verified: ${assetProblem({ ...match, architecture }, assets)}`);
    }
    const after = await assertOpenDraft({ client, source, tag, release: await client.view(tag) });
    const uploaded = (after.assets || []).find(candidate => candidate.name === artifact.file);
    if (!uploaded) fail('upload-unverified', `GitHub did not list ${artifact.file} after upload.`);
    const match = matchAsset(uploaded, artifact);
    if (!match.ok) fail('upload-unverified', `Uploaded ${artifact.file} ${assetProblem({ ...match, architecture }, assets)}`);
    await updateState(ctx, state => {
      state.uploads[architecture] = {
        status: 'uploaded', file: artifact.file, sha256: artifact.sha256, size: artifact.size,
        completedAt: new Date(ctx.now()).toISOString()
      };
    });
  }

  const finalRelease = await assertOpenDraft({ client, source, tag, release: await client.view(tag) });
  const finalMatch = inspectAssets(finalRelease.assets, assets);
  if (!finalMatch.ok) fail('draft-incomplete', `Draft ${tag} ${assetProblem(finalMatch, assets)}`);
  await updateState(ctx, state => {
    state.status = 'draft-ready';
    state.draft = { tag, url: finalRelease.url ?? state.draft?.url, assets: finalRelease.assets || [] };
  });
  ctx.log(`Draft ${tag} is ready with all three exact assets.`);
  ctx.log('Promote separately with: npm run release:publish -- --publish');
  return { action: 'draft', status: 'draft-ready', tag, url: finalRelease.url };
}

async function publish(ctx, client) {
  const { tag, source, assets, options, manifest } = ctx;
  const release = await client.view(tag);
  if (!release) fail('release-not-found', `No GitHub release ${tag}. Run --draft first; --publish never creates or uploads assets.`);
  await verifyRemoteSource({ client, source, release, tag });
  const match = inspectAssets(release.assets, assets);
  if (!match.ok) fail('draft-incomplete', `Draft ${tag} ${assetProblem(match, assets)} Public promotion requires all three exact assets.`);
  if (release.isDraft === false) {
    await updateState(ctx, state => {
      state.status = 'published';
      state.published = { tag, url: release.url, alreadyPublic: true, at: new Date(ctx.now()).toISOString() };
    });
    return { action: 'publish', status: 'already-published', tag, url: release.url };
  }
  const notes = await resolveNotes({ options, manifest });
  await client.promote({ tag, notesFile: notes.exists ? notes.path : null });
  const promoted = await client.view(tag);
  if (!promoted || promoted.isDraft !== false) fail('promotion-unverified', `GitHub did not confirm that ${tag} is public.`);
  await updateState(ctx, state => {
    state.status = 'published';
    state.published = { tag, url: promoted.url, at: new Date(ctx.now()).toISOString() };
  });
  ctx.log(`Published ${tag}: ${promoted.url}`);
  ctx.log('Verify public bytes before staging feeds: npm run release:publish -- --verify --website-dir <root>');
  return { action: 'publish', status: 'published', tag, url: promoted.url };
}

async function assertWebsiteRoot(root) {
  const instruction = `--website-dir must be an existing static-public-root that already contains downloads/; ` +
    'for example the checked-out website repository root. This tool writes only ' +
    'downloads/electron/<arm64|x64>/RELEASES.json, never deploys, and never edits the native Sparkle feed.';
  let rootInfo;
  try { rootInfo = await stat(root); }
  catch (error) {
    if (error.code === 'ENOENT') fail('website-root-missing', `Website root ${root} does not exist. ${instruction}`);
    throw error;
  }
  if (!isDirectory(rootInfo)) fail('website-root-invalid', `${root} is not a directory. ${instruction}`);
  const downloads = path.join(root, 'downloads');
  let downloadsInfo;
  try { downloadsInfo = await stat(downloads); }
  catch (error) {
    if (error.code === 'ENOENT') fail('website-root-invalid', `${root} has no downloads/ directory. ${instruction}`);
    throw error;
  }
  if (!isDirectory(downloadsInfo)) fail('website-root-invalid', `${downloads} is not a directory. ${instruction}`);
}

function validateFeed(feed, { version, architecture, artifact, file }) {
  if (!feed || typeof feed !== 'object') fail('feed-invalid', `${file} must contain an object.`);
  if (feed.currentRelease !== version) fail('feed-invalid', `${file} currentRelease is ${feed.currentRelease}, expected ${version}.`);
  const entry = Array.isArray(feed.releases) ? feed.releases.find(release => release?.version === version) : null;
  const updateTo = entry?.updateTo;
  if (!updateTo) fail('feed-invalid', `${file} has no updateTo entry for ${version}.`);
  const problems = [];
  if (updateTo.version !== version) problems.push('version');
  if (updateTo.url !== artifact.url) problems.push('url');
  if (updateTo.sha256 !== artifact.sha256) problems.push('sha256');
  if (updateTo.size !== artifact.size) problems.push('size');
  if (problems.length) fail('feed-mismatch', `${file} does not match the ${architecture} artifact: ${problems.join(', ')}.`);
  return feed;
}

async function verify(ctx, fetchImpl, client) {
  const { tag, source, assets, options, manifest, repo } = ctx;
  const release = await client.view(tag);
  if (!release || release.isDraft !== false) {
    fail('release-not-public', `Release ${tag} is not public. Verify only after an explicit --publish; no feed was staged.`);
  }
  await verifyRemoteSource({ client, source, release, tag });
  const remoteMatch = inspectAssets(release.assets, assets);
  if (!remoteMatch.ok) {
    fail('public-assets-mismatch', `Public release ${tag} ${assetProblem(remoteMatch, assets)} No download or feed was written.`);
  }
  const root = options.websiteDir ? path.resolve(options.websiteDir) : null;
  if (root) await assertWebsiteRoot(root);
  const urls = ARCHITECTURES.map(architecture => ({
    architecture, url: assets[architecture].url, sha256: assets[architecture].sha256, size: assets[architecture].size
  }));
  const verified = [];
  for (const expected of urls) {
    let response;
    try { response = await fetchImpl(expected.url, { redirect: 'follow' }); }
    catch (error) { fail('public-download-failed', `Could not fetch ${expected.url}: ${error.message}`); }
    if (!response || response.ok === false) {
      fail('public-download-failed', `Public download ${expected.url} returned HTTP ${response?.status ?? 'unknown'}.`);
    }
    const bytes = Buffer.from(await response.arrayBuffer());
    const digest = sha256Bytes(bytes);
    if (digest !== expected.sha256 || bytes.length !== expected.size) {
      fail('public-download-mismatch',
        `${expected.url} returned ${bytes.length} bytes with sha256 ${digest}; expected ${expected.size} bytes with ${expected.sha256}. ` +
        'No feed was staged.');
    }
    verified.push({ ...expected, fetchedAt: new Date(ctx.now()).toISOString() });
  }
  await updateState(ctx, state => {
    state.status = options.websiteDir ? 'verified' : 'public-verified';
    state.publicVerification = { tag, at: new Date(ctx.now()).toISOString(), assets: verified };
  });

  if (!root) {
    ctx.log('All three public downloads match release.json.');
    ctx.log('Feeds were not staged. Pass --website-dir <existing static-public-root containing downloads/> to stage arm64/x64 RELEASES.json.');
    return { action: 'verify', status: 'verified-no-website', verified };
  }

  const staged = [];
  for (const architecture of ['arm64', 'x64']) {
    const file = path.join(ctx.directory, architecture, 'RELEASES.json');
    let feed;
    try { feed = JSON.parse(await readFile(file, 'utf8')); }
    catch (error) {
      if (error.code === 'ENOENT') fail('feed-missing', `No ${file}. Rerun packaging to produce the existing feed format; feeds are never invented.`);
      fail('feed-invalid', `${file} is not valid JSON: ${error.message}`);
    }
    validateFeed(feed, { version: manifest.version, architecture, artifact: assets[architecture], file });
    staged.push({
      architecture, feed,
      target: path.join(root, 'downloads/electron', architecture, 'RELEASES.json')
    });
  }
  for (const item of staged) await writeJsonAtomic(item.target, item.feed);
  await updateState(ctx, state => {
    state.status = 'feeds-staged';
    state.feeds = {
      at: new Date(ctx.now()).toISOString(), root,
      files: Object.fromEntries(staged.map(item => [item.architecture, item.target]))
    };
  });
  ctx.log(`Verified public bytes for ${repo} ${tag}.`);
  for (const item of staged) ctx.log(`Staged ${item.target}`);
  ctx.log('The website deployment and native Sparkle migration checks remain separate.');
  return {
    action: 'verify', status: 'feeds-staged', verified,
    feeds: Object.fromEntries(staged.map(item => [item.architecture, item.target]))
  };
}

export async function runPublication(options, clients = {}) {
  if (options.help) { process.stdout.write(`${USAGE}\n`); return { action: 'help' }; }
  const ctx = await prepare({
    options, runner: clients.runner, now: clients.now || (() => Date.now()),
    validatePackage: clients.validatePackage || null
  });
  ctx.log = clients.log || (line => process.stdout.write(`${line}\n`));
  if (options.action === 'plan') return planResult(ctx);
  const needsClient = options.action === 'draft' || options.action === 'publish' || options.action === 'verify';
  const client = clients.client || (needsClient ? new GhReleaseClient({ runner: ctx.runner, repo: options.repo }) : null);
  if (options.action === 'draft') return draft(ctx, client);
  if (options.action === 'publish') return publish(ctx, client);
  if (options.action === 'verify') {
    const fetchImpl = clients.fetchImpl || globalThis.fetch;
    if (typeof fetchImpl !== 'function') fail('fetch-unavailable', 'No fetch implementation is available for --verify.');
    return verify(ctx, fetchImpl.bind(globalThis), client);
  }
  fail('usage', `Unknown action ${options.action}.`);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    const options = parseArguments(process.argv.slice(2));
    await runPublication(options);
  } catch (error) {
    process.stderr.write(`release:publish: ${error.message}\n`);
    process.exitCode = 1;
  }
}
