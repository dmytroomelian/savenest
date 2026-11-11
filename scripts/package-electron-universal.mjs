import { makeUniversalApp } from '@electron/universal';
import { sign } from '@electron/osx-sign';
import { cp, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile, access } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';

// Merge the already validated release archives, never a fresh working-tree build.
const manifest = JSON.parse(await readFile('package.json', 'utf8'));
const releaseDirectory = path.resolve(process.argv[2] || `build/releases/electron/${manifest.version}`);
const identity = process.env.SIGNING_IDENTITY;
const profile = process.env.NOTARY_PROFILE;
if (!identity || identity === '-' || !profile) throw new Error('Set SIGNING_IDENTITY and NOTARY_PROFILE to existing release credentials.');
const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
const filename = `SaveNest-${manifest.version}-macOS-universal.zip`;
const archive = path.join(releaseDirectory, filename);
try { await access(archive); throw new Error(`Refusing to overwrite release archive: ${archive}`); }
catch (error) { if (error.code !== 'ENOENT') throw error; }
const sha256 = async file => {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
};
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
await sign({ app, identity, platform: 'darwin', version: manifest.devDependencies.electron,
  preAutoEntitlements: false, preEmbedProvisioningProfile: false,
  ignore: file => file === embeddedHelper || file.startsWith(`${embeddedHelper}/`),
  optionsForFile: file => ({ hardenedRuntime: true,
    entitlements: file === app ? path.resolve('Resources/Electron.entitlements') : ['com.apple.security.cs.allow-jit'] })
});
run('codesign', ['--verify', '--deep', '--strict', app]);
for (const bundle of [app, embeddedHelper]) {
  for (const cpu of ['arm64', 'x86_64']) run('lipo', [path.join(bundle, 'Contents/MacOS/SaveNest'), '-verify_arch', cpu]);
}
const submission = path.join(workspace, 'notarize-universal.zip');
run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, submission]);
console.log('Submitting universal app for notarization.');
execFileSync('xcrun', ['notarytool', 'submit', submission, '--keychain-profile', profile, '--wait', '--timeout', '20m'], { stdio: 'inherit' });
run('xcrun', ['stapler', 'staple', app]);
run('xcrun', ['stapler', 'validate', app]);
run('spctl', ['--assess', '--type', 'execute', app]);
run('codesign', ['--verify', '--deep', '--strict', app]);
run('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, archive]);
await mkdir(path.join(releaseDirectory, 'universal'), { recursive: true });
const artifact = { architecture: 'universal', file: filename,
  url: `https://github.com/dmytroomelian/savenest/releases/download/v${manifest.version}/${filename}`,
  sha256: await sha256(archive), size: (await stat(archive)).size };
await writeFile(path.join(releaseDirectory, 'universal/artifact.json'), JSON.stringify(artifact, null, 2) + '\n');
await writeFile(path.join(releaseDirectory, 'universal/SHA256SUMS.txt'), `${artifact.sha256}  ${filename}\n`);
console.log(JSON.stringify({ archive, app, ...artifact }, null, 2));
