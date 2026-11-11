import { readFile, writeFile, mkdir, mkdtemp } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { tmpdir } from 'node:os';

if (!process.env.SIGNING_IDENTITY || !process.env.NOTARY_PROFILE) {
  throw new Error('Set SIGNING_IDENTITY and NOTARY_PROFILE to existing release credentials.');
}
execFileSync('xcrun', ['notarytool', 'history', '--keychain-profile', process.env.NOTARY_PROFILE], { stdio: 'ignore' });
const manifest = JSON.parse(await readFile('package.json', 'utf8'));
const releaseDirectory = path.resolve(`build/releases/electron/${manifest.version}`);
await mkdir(releaseDirectory, { recursive: true });
// Desktop/iCloud file providers can attach Finder metadata after it is cleared,
// invalidating codesign. Keep signable bundles and Swift artifacts outside sync.
const workspace = process.env.RELEASE_WORK_DIR ? path.resolve(process.env.RELEASE_WORK_DIR) : await mkdtemp(path.join(tmpdir(), 'savenest-release-'));
await mkdir(workspace, { recursive: true });
await writeFile(path.join(releaseDirectory, 'local-staging-path.txt'), workspace + '\n');
const artifacts = [];
for (const architecture of ['arm64', 'x64']) {
  const helper = path.join(workspace, `native-${architecture}/SaveNest.app`);
  const environment = { ...process.env, CONFIGURATION: 'release', ELECTRON_HELPER: '1',
    APP_PATH: helper, TARGET_ARCH: architecture === 'x64' ? 'x86_64' : 'arm64',
    SWIFT_SCRATCH_PATH: path.join(workspace, `swift-${architecture}`), PACKAGE_WORK_DIR: workspace };
  execFileSync('bash', ['scripts/build-app.sh'], { env: environment, stdio: 'inherit' });
  execFileSync(process.execPath, ['scripts/package-electron.mjs'], { env: { ...environment,
    DISTRIBUTION: '1', ELECTRON_ARCH: architecture, HELPER_APP_PATH: helper }, stdio: 'inherit' });
  artifacts.push(JSON.parse(await readFile(`build/releases/electron/${manifest.version}/${architecture}/artifact.json`, 'utf8')));
}
execFileSync(process.execPath, ['scripts/package-electron-universal.mjs', releaseDirectory], { stdio: 'inherit' });
artifacts.push(JSON.parse(await readFile(path.join(releaseDirectory, 'universal/artifact.json'), 'utf8')));
const release = { version: manifest.version, minimumSystemVersion: '14.0',
  architectures: Object.fromEntries(artifacts.map(artifact => [artifact.architecture, artifact])) };
await writeFile(`build/releases/electron/${manifest.version}/release.json`, JSON.stringify(release, null, 2) + '\n');
console.log(`Release staged in build/releases/electron/${manifest.version}. No files have been published.`);
