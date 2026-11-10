import { packager } from '@electron/packager';
import { sign } from '@electron/osx-sign';
import { flipFuses, FuseVersion, FuseV1Options } from '@electron/fuses';
import { cp, mkdir, readFile, writeFile, rm, stat, access } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

const root = process.cwd();
const architecture = process.env.ELECTRON_ARCH || process.arch;
if (!['arm64', 'x64'].includes(architecture)) throw new Error('ELECTRON_ARCH must be arm64 or x64.');
const distribution = process.env.DISTRIBUTION === '1';
const identity = process.env.SIGNING_IDENTITY;
const profile = process.env.NOTARY_PROFILE;
if (distribution && (!identity || identity === '-' || !profile)) throw new Error('Distribution requires SIGNING_IDENTITY and NOTARY_PROFILE.');
const manifest = JSON.parse(await readFile('package.json', 'utf8'));
const plistValue = (plist, key) => execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist], { encoding: 'utf8' }).trim();
const nativeValue = key => plistValue('Resources/Info.plist', key);
const nativeVersion = nativeValue('CFBundleShortVersionString');
const nativeBuild = nativeValue('CFBundleVersion');
const nativePublicKey = nativeValue('SUPublicEDKey');
if (manifest.version !== nativeVersion) throw new Error('Electron and native helper versions must match.');
if (!/^[1-9]\d*$/.test(nativeBuild)) throw new Error('The native build number must be a positive integer for Sparkle version ordering.');
if (Buffer.from(nativePublicKey, 'base64').length !== 32 || Buffer.from(nativePublicKey, 'base64').toString('base64') !== nativePublicKey) {
  throw new Error('The existing Sparkle Ed25519 public key must be valid.');
}
const helper = path.resolve(process.env.HELPER_APP_PATH || 'build/electron-native/SaveNest.app');
const helperPlist = path.join(helper, 'Contents/Info.plist');
const helperValue = key => plistValue(helperPlist, key);
if (helperValue('CFBundleShortVersionString') !== manifest.version) throw new Error('The built helper is stale. Rebuild it for this release version.');
if (helperValue('CFBundleVersion') !== nativeBuild) throw new Error('The built helper is stale. Rebuild it for this native build number.');
if (helperValue('SUPublicEDKey') !== nativePublicKey) throw new Error('The built helper must preserve the existing Sparkle public key.');
if (helperValue('SaveNestUpdatesEnabled') !== 'false') throw new Error('The embedded helper must have its Sparkle updater disabled.');
if (helperValue('CFBundleIdentifier') !== 'app.savenest.mac') throw new Error('The helper must preserve the existing library and account identity.');
execFileSync('lipo', [path.join(helper, 'Contents/MacOS/SaveNest'), '-verify_arch', architecture === 'x64' ? 'x86_64' : 'arm64']);
const workspace = path.resolve(process.env.PACKAGE_WORK_DIR || 'build');
const stage = path.join(workspace, `electron-package-${architecture}`);
await rm(stage, { recursive: true, force: true });
await mkdir(stage, { recursive: true });
await cp('electron', path.join(stage, 'electron'), { recursive: true, filter: source => !source.includes('/tests') && !source.endsWith('smoke.cjs') });
for (const name of ['LICENSE', 'THIRD_PARTY_NOTICES.md']) {
  try { await cp(name, path.join(stage, name)); }
  catch (error) { if (distribution) throw new Error(`${name} is required for a public release.`, { cause: error }); }
}
await writeFile(path.join(stage, 'package.json'), JSON.stringify({
  name: manifest.name, productName: manifest.productName, version: manifest.version,
  main: manifest.main, description: manifest.description, license: 'MIT', saveNestRelease: distribution
}));
const apps = await packager({
  dir: stage, out: process.env.PACKAGE_WORK_DIR ? path.join(workspace, 'packages') : 'dist', name: 'SaveNest', platform: 'darwin', arch: architecture,
  electronVersion: manifest.devDependencies.electron, overwrite: true, asar: true,
  appBundleId: 'app.savenest.electron', appVersion: manifest.version, buildVersion: nativeBuild,
  icon: 'build/AppIcon.icns',
  // Preserve Sparkle's build ordering and EdDSA identity for migration from the native app.
  // Electron still uses Squirrel; neither the outer app nor its helper starts Sparkle.
  extendInfo: { LSMinimumSystemVersion: '14.0', NSAppleEventsUsageDescription: 'SaveNest reads browser tabs when you save or search them.',
    SUPublicEDKey: nativePublicKey, SaveNestUpdatesEnabled: false,
    CFBundleURLTypes: [{ CFBundleURLName: 'app.savenest.electron.auth', CFBundleURLSchemes: ['savenest'] }] }
});
for (const directory of apps) {
  const app = path.join(directory, 'SaveNest.app');
  const embeddedHelper = path.join(app, 'Contents/Resources/SaveNest.app');
  await cp(helper, embeddedHelper, { recursive: true, verbatimSymlinks: true });
  const notices = path.join(app, 'Contents/Resources/licenses');
  await mkdir(notices, { recursive: true });
  await cp('node_modules/electron/dist/LICENSE', path.join(notices, 'Electron-LICENSE.txt'));
  await cp('node_modules/electron/dist/LICENSES.chromium.html', path.join(notices, 'LICENSES.chromium.html'));
  await cp('build/reader-third-party-licenses.txt', path.join(notices, 'reader-third-party-licenses.txt'));
  await cp(path.resolve(process.env.SWIFT_SCRATCH_PATH || '.build', 'artifacts/sparkle/Sparkle/LICENSE'), path.join(notices, 'Sparkle-LICENSE.txt'));

  await flipFuses(app, { version: FuseVersion.V1,
    [FuseV1Options.RunAsNode]: false,
    [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
    [FuseV1Options.EnableNodeCliInspectArguments]: false,
    [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
    [FuseV1Options.OnlyLoadAppFromAsar]: true
  });
  execFileSync('xattr', ['-cr', app]);
  if (distribution) {
    // The Swift helper and its Sparkle framework are already signed inside-out.
    // Do not replace their Automation/installer entitlements with Electron defaults.
    await sign({ app, identity, platform: 'darwin', version: manifest.devDependencies.electron,
      preAutoEntitlements: false, preEmbedProvisioningProfile: false,
      ignore: file => file === embeddedHelper || file.startsWith(`${embeddedHelper}/`),
      optionsForFile: file => ({ hardenedRuntime: true,
        entitlements: file === app ? path.join(root, 'Resources/Electron.entitlements') : ['com.apple.security.cs.allow-jit'] })
    });
  } else {
    execFileSync('codesign', ['--force', '--deep', '--preserve-metadata=entitlements', '--sign', '-', app], { stdio: 'inherit' });
  }
  execFileSync('codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });
  console.log(`Built ${app}`);
  if (!distribution) continue;
  const releaseDirectory = path.join(root, 'build/releases/electron', manifest.version);
  await mkdir(releaseDirectory, { recursive: true });
  const filename = `SaveNest-${manifest.version}-macOS-${architecture}.zip`;
  const archive = path.join(releaseDirectory, filename);
  try { await access(archive); throw new Error(`Refusing to overwrite release archive: ${archive}`); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const submissionArchive = path.join(releaseDirectory, `.notarize-${architecture}.zip`);
  execFileSync('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, submissionArchive], { stdio: 'inherit' });
  try {
    execFileSync('xcrun', ['notarytool', 'submit', submissionArchive, '--keychain-profile', profile, '--wait', '--timeout', '20m'], { stdio: 'inherit' });
    execFileSync('xcrun', ['stapler', 'staple', app], { stdio: 'inherit' });
    execFileSync('xcrun', ['stapler', 'validate', app], { stdio: 'inherit' });
    execFileSync('spctl', ['--assess', '--type', 'execute', '--verbose=2', app], { stdio: 'inherit' });
    execFileSync('codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });
    execFileSync('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, archive], { stdio: 'inherit' });
  } finally { await rm(submissionArchive, { force: true }); }
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(archive)) hash.update(chunk);
  const artifact = { architecture, file: filename,
    url: `https://github.com/dmytro-omelian/savenest/releases/download/v${manifest.version}/${filename}`,
    sha256: hash.digest('hex'), size: (await stat(archive)).size };
  const feed = { currentRelease: manifest.version, releases: [{ version: manifest.version, updateTo: {
    version: manifest.version, url: artifact.url, name: `SaveNest ${manifest.version}`,
    notes: 'Glass appearance, global Actions, visible Settings, and a keyboard shortcut guide. Includes the save-with-note dismissal fix.',
    pub_date: new Date().toISOString(), sha256: artifact.sha256, size: artifact.size
  } }] };
  await mkdir(path.join(releaseDirectory, architecture), { recursive: true });
  await writeFile(path.join(releaseDirectory, architecture, 'RELEASES.json'), JSON.stringify(feed, null, 2) + '\n');
  await writeFile(path.join(releaseDirectory, architecture, 'artifact.json'), JSON.stringify(artifact, null, 2) + '\n');
  console.log(`Notarized ${archive}`);
}
