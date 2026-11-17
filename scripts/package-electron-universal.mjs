import { makeUniversalApp } from '@electron/universal';
import { sign } from '@electron/osx-sign';
import { cp, mkdir, mkdtemp, readFile, readdir, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {
  createCheckpoint, createCommandRunner, hashFile, markCompleted, notarizeAndStaple,
  pathExists, removeSubmissionArchive, sha256Text, stableStringify, verifyExistingFinal,
  writeFileAtomic, writeJsonAtomic
} from './release-state.mjs';

// Merge the already validated release archives, never a fresh working-tree build.
const manifest = JSON.parse(await readFile('package.json', 'utf8'));
const releaseDirectory = path.resolve(process.argv[2] || process.env.RELEASE_OUTPUT_DIR || `build/releases/electron/${manifest.version}`);
const identity = process.env.SIGNING_IDENTITY;
const profile = process.env.NOTARY_PROFILE;
if (!identity || identity === '-' || !profile) throw new Error('Set SIGNING_IDENTITY and NOTARY_PROFILE to existing release credentials.');
const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
async function readJsonIfExists(file) {
  try { return JSON.parse(await readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
async function readTextIfExists(file) {
  try { return await readFile(file, 'utf8'); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
const filename = `SaveNest-${manifest.version}-macOS-universal.zip`;
const archive = path.join(releaseDirectory, filename);
const checkpoint = createCheckpoint({ file: path.join(releaseDirectory, '.release-state', 'universal.json') });
const runner = createCommandRunner({ logDirectory: path.join(releaseDirectory, '.release-state', 'logs', 'universal'), checkpoint });
const sha256 = hashFile;
const archiveInputs = {};
for (const architecture of ['arm64', 'x64']) {
  const artifactPath = path.join(releaseDirectory, architecture, 'artifact.json');
  const input = path.join(releaseDirectory, `SaveNest-${manifest.version}-macOS-${architecture}.zip`);
  let artifact;
  try { artifact = JSON.parse(await readFile(artifactPath, 'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT' && await pathExists(archive)) {
      throw new Error(`Refusing to reuse ${archive}: missing ${artifactPath} provenance.`);
    }
    throw error;
  }
  assert.equal(await sha256(input), artifact.sha256, `${architecture} archive checksum mismatch`);
  archiveInputs[architecture] = { file: artifact.file, sha256: artifact.sha256, size: artifact.size };
}
const build = run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleVersion', 'Resources/Info.plist']);
const identityInputs = {
  version: manifest.version, build, architecture: 'universal', electronVersion: manifest.devDependencies.electron,
  signingIdentity: sha256Text(identity), archives: archiveInputs,
  entitlements: {
    electron: await hashFile('Resources/Electron.entitlements'),
    helper: await hashFile('Resources/SaveNest.entitlements')
  },
  packageJson: await hashFile('package.json')
};
// The future orchestrator may supply a release-wide identity. Standalone
// builds derive one from the exact architecture archives and signing inputs.
const releaseIdentity = process.env.SAVENEST_RELEASE_IDENTITY || process.env.RELEASE_IDENTITY || sha256Text(stableStringify(identityInputs));
const universalDirectory = path.join(releaseDirectory, 'universal');
const metadataPaths = { artifact: path.join(universalDirectory, 'artifact.json'), sums: path.join(universalDirectory, 'SHA256SUMS.txt') };
const makeMetadata = facts => {
  const artifact = { architecture: 'universal', file: filename,
    url: `https://github.com/dmytroomelian/savenest/releases/download/v${manifest.version}/${filename}`,
    sha256: facts.sha256, size: facts.size };
  return { artifact, sha256sums: `${artifact.sha256}  ${filename}\n` };
};
const writeMetadata = async metadata => {
  await mkdir(universalDirectory, { recursive: true });
  await writeJsonAtomic(metadataPaths.artifact, metadata.artifact);
  await writeFileAtomic(metadataPaths.sums, metadata.sha256sums, { mode: 0o644 });
  await markCompleted({ checkpoint, metadata });
};
if (await pathExists(archive)) {
  const metadata = { artifact: await readJsonIfExists(metadataPaths.artifact), sha256sums: await readTextIfExists(metadataPaths.sums) };
  const verified = await verifyExistingFinal({ checkpoint, identity: releaseIdentity, architecture: 'universal',
    version: manifest.version, build, inputs: identityInputs, finalArchive: archive, metadata,
    validate: async file => {
      await runner.run('validate-package', process.execPath, ['scripts/check-electron-package.mjs', file, 'universal']);
    } });
  const recovered = metadata.artifact && metadata.sha256sums ? (verified.state.metadata ?? metadata)
    : (verified.state.metadata?.artifact && verified.state.metadata?.sha256sums ? verified.state.metadata : makeMetadata(verified.final));
  await writeMetadata(recovered);
  console.log(`Reused notarized ${archive}`);
  process.exit(0);
}
const pending = await checkpoint.read();
if (pending?.notary?.id && pending.submission && pending.identity === releaseIdentity) {
  // Resume the immutable submitted ZIP without rebuilding or re-signing a new
  // universal app. createSubmissionArchive is intentionally unreachable.
  const submission = path.join(releaseDirectory, '.notarize-universal.zip');
  const result = await notarizeAndStaple({
    checkpoint, runner, identity: releaseIdentity, architecture: 'universal', version: manifest.version, build,
    inputs: identityInputs, submissionArchive: submission, finalArchive: archive, profile,
    extractDirectory: path.join(releaseDirectory, '.release-state', 'extract-universal'),
    createSubmissionArchive: async () => { throw new Error('A pending submission must never be recreated.'); }
  });
  const metadata = makeMetadata(result.artifact);
  await writeMetadata(metadata);
  await removeSubmissionArchive({ checkpoint, submissionArchive: submission });
  console.log(JSON.stringify({ archive, app: result.app, ...metadata.artifact }, null, 2));
  process.exit(0);
}
const workspace = await mkdtemp(path.join(tmpdir(), 'savenest-universal-'));
console.log(`Staging universal app in ${workspace}`);
const apps = {};
const plist = (app, key) => run('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, path.join(app, 'Contents/Info.plist')]);
for (const architecture of ['arm64', 'x64']) {
  const artifact = JSON.parse(await readFile(path.join(releaseDirectory, architecture, 'artifact.json'), 'utf8'));
  const input = path.join(releaseDirectory, `SaveNest-${manifest.version}-macOS-${architecture}.zip`);
  assert.equal(await sha256(input), artifact.sha256, `${architecture} archive checksum mismatch`);
  run('ditto', ['-x', '-k', input, path.join(workspace, architecture)]);
  const app = apps[architecture] = path.join(workspace, architecture, 'SaveNest.app');
  assert.equal(plist(app, 'CFBundleShortVersionString'), manifest.version);
  run('codesign', ['--verify', '--deep', '--strict', app]);
  run('xcrun', ['stapler', 'validate', app]);
  run('spctl', ['--assess', '--type', 'execute', app]);
}
assert.equal(plist(apps.arm64, 'CFBundleVersion'), plist(apps.x64, 'CFBundleVersion'));
const mcpFlag = bundle => { try { return plist(bundle, 'SaveNestMCPEnabled') === 'true'; } catch { return false; } };
const hasMCP = mcpFlag(apps.arm64);
assert.equal(hasMCP, mcpFlag(apps.x64), 'Both release architectures must contain the same MCP component choice.');
assert.equal(plist(apps.arm64, 'SaveNestSocialCaptureEnabled'), plist(apps.x64, 'SaveNestSocialCaptureEnabled'),
  'Both release architectures must contain the same social capture component choice.');
assert.equal(await sha256(path.join(apps.arm64, 'Contents/Resources/app.asar')),
  await sha256(path.join(apps.x64, 'Contents/Resources/app.asar')), 'Release app code must match across architectures');

// Sparkle already contains both architectures. Preserve its signed bundle and
// merge only our Swift executable, then sign the helper again.
const helper = path.join(workspace, 'native/SaveNest.app');
await cp(path.join(apps.x64, 'Contents/Resources/SaveNest.app'), helper, { recursive: true, verbatimSymlinks: true });
run('lipo', [path.join(apps.x64, 'Contents/Resources/SaveNest.app/Contents/MacOS/SaveNest'),
  path.join(apps.arm64, 'Contents/Resources/SaveNest.app/Contents/MacOS/SaveNest'),
  '-create', '-output', path.join(helper, 'Contents/MacOS/SaveNest')]);
run('xattr', ['-cr', helper]);
run('codesign', ['--force', '--options', 'runtime', '--timestamp', '--entitlements',
  path.resolve('Resources/SaveNest.entitlements'), '--sign', identity, helper]);
run('codesign', ['--verify', '--deep', '--strict', helper]);

async function removeResourceSeals(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const file = path.join(directory, entry.name);
    if (entry.name === '_CodeSignature') await rm(file, { recursive: true });
    else await removeResourceSeals(file);
  }
}
for (const app of Object.values(apps)) {
  await rm(path.join(app, 'Contents/Resources/SaveNest.app'), { recursive: true });
  // The stapled ticket belongs to the original architecture-specific signature.
  await rm(path.join(app, 'Contents/CodeResources'), { force: true });
  await removeResourceSeals(app);
}
const app = path.join(workspace, 'universal/SaveNest.app');
await makeUniversalApp({ x64AppPath: apps.x64, arm64AppPath: apps.arm64, outAppPath: app, mergeASARs: true });
const embeddedHelper = path.join(app, 'Contents/Resources/SaveNest.app');
await cp(helper, embeddedHelper, { recursive: true, verbatimSymlinks: true });
run('xattr', ['-cr', app]);
const mcpExecutable = path.join(app, 'Contents/Resources/savenest-mcp');
if (hasMCP) {
  for (const cpu of ['arm64', 'x86_64']) run('lipo', [mcpExecutable, '-verify_arch', cpu]);
  run('codesign', ['--force', '--options', 'runtime', '--timestamp', '--sign', identity, mcpExecutable]);
  run('codesign', ['--verify', '--strict', mcpExecutable]);
}
await sign({ app, identity, platform: 'darwin', version: manifest.devDependencies.electron,
  preAutoEntitlements: false, preEmbedProvisioningProfile: false,
  ignore: file => file === embeddedHelper || file.startsWith(`${embeddedHelper}/`) || (hasMCP && file === mcpExecutable),
  optionsForFile: file => ({ hardenedRuntime: true,
    entitlements: file === app ? path.resolve('Resources/Electron.entitlements') : ['com.apple.security.cs.allow-jit'] })
});
run('codesign', ['--verify', '--deep', '--strict', app]);
for (const bundle of [app, embeddedHelper]) {
  for (const cpu of ['arm64', 'x86_64']) run('lipo', [path.join(bundle, 'Contents/MacOS/SaveNest'), '-verify_arch', cpu]);
}
const submission = path.join(releaseDirectory, '.notarize-universal.zip');
console.log('Submitting universal app for notarization.');
const result = await notarizeAndStaple({
  checkpoint, runner, identity: releaseIdentity, architecture: 'universal', version: manifest.version, build,
  inputs: identityInputs, submissionArchive: submission, finalArchive: archive, profile,
  extractDirectory: path.join(releaseDirectory, '.release-state', 'extract-universal'),
  createSubmissionArchive: async () => {
    await rm(submission, { force: true });
    await runner.run('submission-compress', 'ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, submission]);
  }
});
const metadata = makeMetadata(result.artifact);
await writeMetadata(metadata);
await removeSubmissionArchive({ checkpoint, submissionArchive: submission });
console.log(JSON.stringify({ archive, app, ...metadata.artifact }, null, 2));
