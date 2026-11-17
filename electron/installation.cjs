'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const { execFile } = require('node:child_process');
const { promisify } = require('node:util');
const run = promisify(execFile);
const INSTALLED_ARGUMENT = '--savenest-installed';

async function exists(file) {
  try { await fs.lstat(file); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

async function isSaveNest(bundle) {
  try {
    const { stdout } = await run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', path.join(bundle, 'Contents/Info.plist')]);
    return ['app.savenest.mac', 'app.savenest.electron'].includes(stdout.trim());
  } catch { return false; }
}

// Stage the entire bundle before exposing it at its canonical name. Reserve that
// name exclusively: never replace an existing app, including a racing installer.
async function copyApplication(source, applications, copy = async (from, to) => {
  await run('/usr/bin/ditto', [from, to]);
}) {
  const destination = path.join(applications, 'SaveNest.app');
  const staging = await fs.mkdtemp(path.join(applications, '.SaveNest-install-'));
  let reserved = false;
  try {
    const stagedApp = path.join(staging, 'SaveNest.app');
    await copy(source, stagedApp);
    // Match the native installer's behavior for this already-approved running
    // release. Only its new staged bundle root is changed; existing installations
    // and the download retain their metadata. Avoid read-only app translocation.
    const { stdout: attributes } = await run('/usr/bin/xattr', [stagedApp]);
    if (attributes.split('\n').includes('com.apple.quarantine')) {
      await run('/usr/bin/xattr', ['-d', 'com.apple.quarantine', stagedApp]);
    }
    await fs.mkdir(destination); // EEXIST leaves the installed copy untouched.
    reserved = true;
    await fs.rename(stagedApp, destination);
    reserved = false;
    return destination;
  } finally {
    // Only remove an empty reservation, never another app or a partial library.
    if (reserved) await fs.rmdir(destination).catch(() => {});
    await fs.rm(staging, { recursive: true, force: true });
  }
}

async function openApplication(bundle) {
  const { stdout } = await run('/usr/libexec/PlistBuddy', ['-c', 'Print :CFBundleIdentifier', path.join(bundle, 'Contents/Info.plist')]);
  // A normal open can reactivate this Downloads process by bundle ID. A fresh
  // Electron instance takes the released lock; native Savenest can reuse itself.
  const fresh = stdout.trim() === 'app.savenest.electron' ? ['-n'] : [];
  await run('/usr/bin/open', [...fresh, '-a', bundle, '--args', INSTALLED_ARGUMENT]);
}

// Called before starting the native library writer. Release Electron's lock
// before opening another Electron copy or the new copy would immediately exit.
async function handoff({ app, destination, open = openApplication }) {
  app.releaseSingleInstanceLock();
  try {
    await open(destination);
    app.quit();
    return true;
  } catch (error) {
    if (!app.requestSingleInstanceLock()) app.quit();
    throw error;
  }
}

async function offerInstallation({ app, dialog, release = false, hasPendingURLs = () => false,
  argv = process.argv, applications = '/Applications',
  userApplications = path.join(app.getPath('home'), 'Applications'),
  source = path.resolve(app.getPath('exe'), '../../..'),
  identify = isSaveNest, copy = copyApplication, open = openApplication }) {
  if (!app.isPackaged || !release || app.isInApplicationsFolder() || argv.includes(INSTALLED_ARGUMENT) || hasPendingURLs()) return false;
  try {
    // A repeat extraction may be named "SaveNest 2.app". Always look for the
    // canonical installation as well as an earlier same-name installation.
    const candidates = [...new Set([applications, userApplications].flatMap(directory =>
      ['SaveNest.app', path.basename(source)].map(name => path.join(directory, name))))];
    let installed;
    for (const candidate of candidates) {
      if (await exists(candidate) && await identify(candidate)) { installed = candidate; break; }
    }
    const { response } = await dialog.showMessageBox({ type: 'question',
      message: installed ? 'Open your installed Savenest?' : 'Install Savenest in Applications?',
      detail: installed
        ? `Savenest is already in ${path.dirname(installed)}. Open that copy and choose Check for Updates… to update it. Your library stays in place.`
        : 'Savenest will copy itself to Applications and open from there. You can also keep using this download for now.',
      buttons: installed ? ['Open Savenest', 'Use This Download'] : ['Install & Open', 'Not Now'],
      defaultId: 0, cancelId: 1 });
    // A sign-in callback can arrive while the prompt is open. Keep it in this
    // process instead of losing it during an installation handoff.
    if (response !== 0 || hasPendingURLs()) return false;
    const destination = installed || await copy(source, applications);
    if (hasPendingURLs()) return false;
    return await handoff({ app, destination, open });
  } catch {
    await dialog.showMessageBox({ type: 'warning', message: 'Continue with this download',
      detail: 'Savenest could not install or open the copy in Applications. You can keep using this download. To install manually, quit Savenest, then drag it into Applications in Finder. If a copy is already there, open it and choose Check for Updates….',
      buttons: ['Continue'], defaultId: 0 });
    return !app.hasSingleInstanceLock();
  }
}

async function resolveStartupConflict({ app, dialog, existingAppPath, open = openApplication }) {
  const { response } = await dialog.showMessageBox({ type: 'info', message: 'Savenest is already open',
    detail: 'Your library is open in another copy of Savenest. Open that copy to continue. To use this download instead, quit the other copy from its menu bar icon, then choose Try Again.',
    buttons: ['Open Savenest', 'Try Again', 'Quit This Copy'], defaultId: 0, cancelId: 2 });
  if (response === 0) {
    try { await handoff({ app, destination: existingAppPath, open }); }
    catch {
      await dialog.showMessageBox({ type: 'warning', message: 'Open Savenest from its menu bar icon',
        detail: 'The other copy could not be brought forward. Quit it from its menu bar icon, then reopen this download.', buttons: ['OK'] });
      app.quit();
    }
  } else {
    if (response === 1) app.relaunch();
    app.quit();
  }
}

module.exports = { copyApplication, offerInstallation, resolveStartupConflict, handoff };
