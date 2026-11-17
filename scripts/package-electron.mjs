import { packager } from '@electron/packager';
import { sign } from '@electron/osx-sign';
import { flipFuses, FuseVersion, FuseV1Options } from '@electron/fuses';
import { cp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { prepareMCP } from './mcp-package.mjs';
import { prepareSocialCapture } from './social-capture-package.mjs';
import {
  collectReleaseInputs, createCheckpoint, createCommandRunner, markCompleted,
  notarizeAndStaple, pathExists, removeSubmissionArchive, sha256Text,
  stableStringify, verifyExistingFinal, writeJsonAtomic
} from './release-state.mjs';

const root = process.cwd();
async function readJsonIfExists(file) {
  try { return JSON.parse(await readFile(file, 'utf8')); }
  catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
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
const mcp = await prepareMCP({ architecture, workspace });
const socialCapture = await prepareSocialCapture({ binary: path.join(helper, 'Contents/MacOS/SaveNest') });
const feedNotes = socialCapture.enabled
  ? 'Help now gathers Explore features, feature requests, bug reports, and keyboard shortcuts in one menu. Release preparation is more reliable. Save from other apps remains an optional Pro beta and starts off; Chrome is experimental. Free local saving, reading, search and organization remain available.'
  : 'Help now gathers Explore features, feature requests, bug reports, and keyboard shortcuts in one menu. Release preparation is more reliable. Free local saving, reading, search and organization remain available.';
let releaseIdentity, identityInputs;
if (distribution) {
  const sparkleLicense = path.resolve(process.env.SWIFT_SCRATCH_PATH || '.build', 'artifacts/sparkle/Sparkle/LICENSE');
  const consumed = await collectReleaseInputs({
    helper,
    files: {
      packageJson: 'package.json', packageLock: 'package-lock.json',
      appIcon: 'build/AppIcon.icns', license: 'LICENSE', thirdPartyNotices: 'THIRD_PARTY_NOTICES.md',
      readerLicenses: 'build/reader-third-party-licenses.txt',
      servicesAdapter: path.join('build/services', architecture, 'savenest-services.node'),
      servicesSource: 'electron/native/services.m',
      servicesScript: 'scripts/build-services.mjs',
      electronLicense: 'node_modules/electron/dist/LICENSE',
      chromiumLicenses: 'node_modules/electron/dist/LICENSES.chromium.html',
      nodeApiLicense: 'node_modules/node-api-headers/LICENSE',
      sparkleLicense,
      electronEntitlements: 'Resources/Electron.entitlements',
      helperEntitlements: 'Resources/SaveNest.entitlements',
      packageScript: 'scripts/package-electron.mjs',
      universalPackageScript: 'scripts/package-electron-universal.mjs',
      mcpScript: 'scripts/mcp-package.mjs',
      socialCaptureScript: 'scripts/social-capture-package.mjs',
      ...(socialCapture.enabled ? { captureLicense: socialCapture.license, captureThirdParty: socialCapture.thirdParty } : {}),
      releaseStateScript: 'scripts/release-state.mjs',
      ...(mcp ? { mcpBinary: mcp.binary, mcpLicense: mcp.license, mcpThirdParty: mcp.thirdParty } : {})
    },
    directories: { electron: 'electron' }
  });
  identityInputs = {
    version: manifest.version, build: nativeBuild, architecture, electronVersion: manifest.devDependencies.electron,
    distribution, signingIdentity: sha256Text(identity),
    mcp: mcp ? { included: true } : null,
    socialCapture: socialCapture.enabled ? { included: true } : null, source: consumed
  };
  // The future orchestrator may supply a release-wide identity. Standalone
  // builds derive one from the exact source/helper inputs above.
  releaseIdentity = process.env.SAVENEST_RELEASE_IDENTITY || process.env.RELEASE_IDENTITY || sha256Text(stableStringify(identityInputs));
  // Resume an in-flight notarization before rebuilding or re-signing anything.
  // The checkpoint pins the exact submitted ZIP, so it remains immutable.
  const resumeDirectory = path.resolve(process.env.RELEASE_OUTPUT_DIR || path.join(root, 'build/releases/electron', manifest.version));
  const resumeFilename = `SaveNest-${manifest.version}-macOS-${architecture}.zip`;
  const resumeArchive = path.join(resumeDirectory, resumeFilename);
  const resumeCheckpoint = createCheckpoint({ file: path.join(resumeDirectory, '.release-state', `${architecture}.json`) });
  if (await pathExists(resumeArchive)) {
    const metadataDirectory = path.join(resumeDirectory, architecture);
    const metadataPaths = { artifact: path.join(metadataDirectory, 'artifact.json'), feed: path.join(metadataDirectory, 'RELEASES.json') };
    const metadata = { artifact: await readJsonIfExists(metadataPaths.artifact), feed: await readJsonIfExists(metadataPaths.feed) };
    const verifyRunner = createCommandRunner({ logDirectory: path.join(resumeDirectory, '.release-state', 'logs', architecture), checkpoint: resumeCheckpoint });
    const verified = await verifyExistingFinal({ checkpoint: resumeCheckpoint, identity: releaseIdentity, architecture,
      version: manifest.version, build: nativeBuild, inputs: identityInputs, finalArchive: resumeArchive, metadata,
      validate: async file => {
        await verifyRunner.run('validate-package', process.execPath, ['scripts/check-electron-package.mjs', file, architecture]);
      } });
    const artifact = { architecture, file: resumeFilename,
      url: `https://github.com/dmytroomelian/savenest/releases/download/v${manifest.version}/${resumeFilename}`,
      sha256: verified.final.sha256, size: verified.final.size };
    const feed = { currentRelease: manifest.version, releases: [{ version: manifest.version, updateTo: {
      version: manifest.version, url: artifact.url, name: `Savenest ${manifest.version}`,
      notes: feedNotes,
      pub_date: new Date().toISOString(), sha256: artifact.sha256, size: artifact.size
    } }] };
    const recovered = metadata.artifact && metadata.feed ? (verified.state.metadata ?? metadata)
      : (verified.state.metadata?.artifact && verified.state.metadata?.feed ? verified.state.metadata : { artifact, feed });
    await mkdir(metadataDirectory, { recursive: true });
    await writeJsonAtomic(metadataPaths.artifact, recovered.artifact);
    await writeJsonAtomic(metadataPaths.feed, recovered.feed);
    await markCompleted({ checkpoint: resumeCheckpoint, metadata: recovered });
    console.log(`Reused notarized ${resumeArchive}`);
    process.exit(0);
  }
  const resumeState = await resumeCheckpoint.read();
  if (resumeState?.notary?.id && resumeState.submission && resumeState.identity === releaseIdentity) {
    const resumeRunner = createCommandRunner({ logDirectory: path.join(resumeDirectory, '.release-state', 'logs', architecture), checkpoint: resumeCheckpoint });
    const submissionArchive = path.join(resumeDirectory, `.notarize-${architecture}.zip`);
    const result = await notarizeAndStaple({
      checkpoint: resumeCheckpoint, runner: resumeRunner, identity: releaseIdentity, architecture, version: manifest.version, build: nativeBuild,
      inputs: identityInputs, submissionArchive, finalArchive: resumeArchive, profile,
      extractDirectory: path.join(resumeDirectory, '.release-state', `extract-${architecture}`),
      createSubmissionArchive: async () => { throw new Error('A pending submission must never be recreated.'); }
    });
    const artifact = { architecture, file: resumeFilename,
      url: `https://github.com/dmytroomelian/savenest/releases/download/v${manifest.version}/${resumeFilename}`,
      sha256: result.artifact.sha256, size: result.artifact.size };
    const feed = { currentRelease: manifest.version, releases: [{ version: manifest.version, updateTo: {
      version: manifest.version, url: artifact.url, name: `Savenest ${manifest.version}`,
      notes: feedNotes,
      pub_date: new Date().toISOString(), sha256: artifact.sha256, size: artifact.size
    } }] };
    const metadata = { artifact, feed };
    const metadataDirectory = path.join(resumeDirectory, architecture);
    await mkdir(metadataDirectory, { recursive: true });
    await writeJsonAtomic(path.join(metadataDirectory, 'artifact.json'), artifact);
    await writeJsonAtomic(path.join(metadataDirectory, 'RELEASES.json'), feed);
    await markCompleted({ checkpoint: resumeCheckpoint, metadata });
    await removeSubmissionArchive({ checkpoint: resumeCheckpoint, submissionArchive });
    console.log(`Notarized ${resumeArchive}`);
    process.exit(0);
  }
}
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
  extendInfo: { CFBundleDisplayName: 'Savenest', CFBundleName: 'Savenest', LSMinimumSystemVersion: '14.0', NSAppleEventsUsageDescription: 'Savenest reads browser tabs when you save or search them.',
    SUPublicEDKey: nativePublicKey, SaveNestUpdatesEnabled: false, SaveNestMCPEnabled: Boolean(mcp), SaveNestSocialCaptureEnabled: socialCapture.enabled,
    NSServices: [{
      NSMenuItem: { default: 'Add to SaveNest…' },
      NSMessage: 'addToSaveNest',
      NSPortName: 'Savenest',
      NSRequiredContext: { NSTextContent: 'URL' },
      NSSendTypes: ['public.url', 'public.utf8-plain-text', 'NSStringPboardType']
    }],
    CFBundleURLTypes: [{ CFBundleURLName: 'app.savenest.electron.auth', CFBundleURLSchemes: ['savenest'] }] }
});
for (const directory of apps) {
  const app = path.join(directory, 'SaveNest.app');
  const embeddedHelper = path.join(app, 'Contents/Resources/SaveNest.app');
  await cp(helper, embeddedHelper, { recursive: true, verbatimSymlinks: true });
  const servicesAdapter = path.join(app, 'Contents/Resources/native/savenest-services.node');
  await mkdir(path.dirname(servicesAdapter), { recursive: true });
  await cp(path.resolve('build/services', architecture, 'savenest-services.node'), servicesAdapter);
  execFileSync('lipo', [servicesAdapter, '-verify_arch', architecture === 'x64' ? 'x86_64' : 'arm64']);
  const notices = path.join(app, 'Contents/Resources/licenses');
  await mkdir(notices, { recursive: true });
  await cp('node_modules/electron/dist/LICENSE', path.join(notices, 'Electron-LICENSE.txt'));
  await cp('node_modules/electron/dist/LICENSES.chromium.html', path.join(notices, 'LICENSES.chromium.html'));
  await cp('node_modules/node-api-headers/LICENSE', path.join(notices, 'Node-API-LICENSE.txt'));
  await cp('build/reader-third-party-licenses.txt', path.join(notices, 'reader-third-party-licenses.txt'));
  await cp(path.resolve(process.env.SWIFT_SCRATCH_PATH || '.build', 'artifacts/sparkle/Sparkle/LICENSE'), path.join(notices, 'Sparkle-LICENSE.txt'));
  if (socialCapture.enabled) {
    await cp(socialCapture.license, path.join(notices, 'SaveNest-Pro-Capture-LICENSE.txt'));
    await cp(socialCapture.thirdParty, path.join(notices, 'SaveNest-Pro-Capture-THIRD-PARTY-NOTICES.txt'));
  }
  const mcpExecutable = path.join(app, 'Contents/Resources/savenest-mcp');
  if (mcp) {
    await cp(mcp.binary, mcpExecutable);
    await cp(mcp.license, path.join(notices, 'SaveNest-Pro-MCP-LICENSE.txt'));
    await cp(mcp.thirdParty, path.join(notices, 'SaveNest-Pro-MCP-THIRD-PARTY-NOTICES.txt'));
  }

  await flipFuses(app, { version: FuseVersion.V1,
    [FuseV1Options.RunAsNode]: false,
    [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
    [FuseV1Options.EnableNodeCliInspectArguments]: false,
    [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
    [FuseV1Options.OnlyLoadAppFromAsar]: true
  });
  execFileSync('xattr', ['-cr', app]);
  execFileSync('codesign', ['--force', ...(distribution ? ['--options', 'runtime', '--timestamp'] : []),
    '--sign', distribution ? identity : '-', servicesAdapter], { stdio: 'inherit' });
  if (distribution) {
    if (mcp) execFileSync('codesign', ['--force', '--options', 'runtime', '--timestamp', '--sign', identity, mcpExecutable], { stdio: 'inherit' });
    // The Swift helper and its Sparkle framework are already signed inside-out.
    // Do not replace their Automation/installer entitlements with Electron defaults.
    await sign({ app, identity, platform: 'darwin', version: manifest.devDependencies.electron,
      preAutoEntitlements: false, preEmbedProvisioningProfile: false,
      ignore: file => file === embeddedHelper || file.startsWith(`${embeddedHelper}/`) || (mcp && file === mcpExecutable),
      optionsForFile: file => ({ hardenedRuntime: true,
        entitlements: file === app ? path.join(root, 'Resources/Electron.entitlements') : ['com.apple.security.cs.allow-jit'] })
    });
  } else {
    // Resources executables are not reliably included by --deep. Intel Swift
    // binaries also lack the linker's implicit Apple Silicon ad-hoc signature.
    if (mcp) execFileSync('codesign', ['--force', '--sign', '-', mcpExecutable], { stdio: 'inherit' });
    execFileSync('codesign', ['--force', '--deep', '--preserve-metadata=entitlements', '--sign', '-', app], { stdio: 'inherit' });
  }
  if (mcp) execFileSync('codesign', ['--verify', '--strict', mcpExecutable], { stdio: 'inherit' });
  execFileSync('codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });
  console.log(`Built ${app}`);
  if (!distribution) continue;
  const releaseDirectory = path.resolve(process.env.RELEASE_OUTPUT_DIR || path.join(root, 'build/releases/electron', manifest.version));
  await mkdir(releaseDirectory, { recursive: true });
  const filename = `SaveNest-${manifest.version}-macOS-${architecture}.zip`;
  const archive = path.join(releaseDirectory, filename);
  const checkpoint = createCheckpoint({ file: path.join(releaseDirectory, '.release-state', `${architecture}.json`) });
  const runner = createCommandRunner({ logDirectory: path.join(releaseDirectory, '.release-state', 'logs', architecture), checkpoint });
  const metadataDirectory = path.join(releaseDirectory, architecture);
  const metadataPaths = { artifact: path.join(metadataDirectory, 'artifact.json'), feed: path.join(metadataDirectory, 'RELEASES.json') };
  const readMetadata = async () => ({ artifact: await readJsonIfExists(metadataPaths.artifact), feed: await readJsonIfExists(metadataPaths.feed) });
  const makeMetadata = facts => {
    const artifact = { architecture, file: filename,
      url: `https://github.com/dmytroomelian/savenest/releases/download/v${manifest.version}/${filename}`,
      sha256: facts.sha256, size: facts.size };
    const feed = { currentRelease: manifest.version, releases: [{ version: manifest.version, updateTo: {
      version: manifest.version, url: artifact.url, name: `Savenest ${manifest.version}`,
      notes: feedNotes,
      pub_date: new Date().toISOString(), sha256: artifact.sha256, size: artifact.size
    } }] };
    return { artifact, feed };
  };
  const writeMetadata = async metadata => {
    await mkdir(metadataDirectory, { recursive: true });
    await writeJsonAtomic(metadataPaths.artifact, metadata.artifact);
    await writeJsonAtomic(metadataPaths.feed, metadata.feed);
    await markCompleted({ checkpoint, metadata });
  };
  if (await pathExists(archive)) {
    const metadata = await readMetadata();
    const verified = await verifyExistingFinal({ checkpoint, identity: releaseIdentity, architecture,
      version: manifest.version, build: nativeBuild, inputs: identityInputs, finalArchive: archive, metadata,
      validate: async file => {
        await runner.run('validate-package', process.execPath, ['scripts/check-electron-package.mjs', file, architecture]);
      } });
    const recovered = metadata.artifact && metadata.feed ? (verified.state.metadata ?? metadata)
      : (verified.state.metadata?.artifact && verified.state.metadata?.feed ? verified.state.metadata : makeMetadata(verified.final));
    await writeMetadata(recovered);
    console.log(`Reused notarized ${archive}`);
    continue;
  }
  const submissionArchive = path.join(releaseDirectory, `.notarize-${architecture}.zip`);
  const result = await notarizeAndStaple({
    checkpoint, runner, identity: releaseIdentity, architecture, version: manifest.version, build: nativeBuild,
    inputs: identityInputs, submissionArchive, finalArchive: archive, profile,
    extractDirectory: path.join(releaseDirectory, '.release-state', `extract-${architecture}`),
    createSubmissionArchive: async () => {
      await rm(submissionArchive, { force: true });
      await runner.run('submission-compress', 'ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, submissionArchive]);
    }
  });
  await writeMetadata(makeMetadata(result.artifact));
  await removeSubmissionArchive({ checkpoint, submissionArchive });
  console.log(`Notarized ${archive}`);
}
