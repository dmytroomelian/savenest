import { execFileSync } from 'node:child_process';
import { access, rm } from 'node:fs/promises';
import path from 'node:path';

// One architecture stage runs in its own process so the orchestrator can keep
// arm64 and x64 fully concurrent while each stage has independent logs/state.
const helper = process.env.APP_PATH || process.env.HELPER_APP_PATH;
if (!helper) throw new Error('APP_PATH/HELPER_APP_PATH is required.');
const reuse = process.env.RELEASE_REUSE_HELPER === '1';
if (reuse) {
  await access(path.join(helper, 'Contents/Info.plist'));
  await access(path.join(helper, 'Contents/MacOS/SaveNest'));
  console.log(`Reusing prepared helper ${helper}`);
} else {
  // Never mix resources from an older helper into a changed source build.
  await rm(helper, { recursive: true, force: true });
  execFileSync('bash', ['scripts/build-app.sh'], { stdio: 'inherit', env: process.env });
}
execFileSync(process.execPath, ['scripts/package-electron.mjs'], { stdio: 'inherit', env: process.env });
