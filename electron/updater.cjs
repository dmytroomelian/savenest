'use strict';

function feedURL(architecture) {
  if (!['arm64', 'x64'].includes(architecture)) return null;
  return `https://savenest.app/downloads/electron/${architecture}/RELEASES.json`;
}

function canRestartSafely({ view, state, failed = false }) {
  return !failed && state?.canRestartForUpdate === true && !state.busy &&
    !['editor', 'selection'].includes(view) && !state.captureDraft && !state.captureSelection;
}

// Squirrel validates the downloaded application's signing identity. The feed is
// separate from the native Sparkle feed and uses numeric version comparisons.
// Checks are user-initiated: no background update requests or surprise downloads.
function createUpdater({ app, autoUpdater, dialog, release = false, architecture = process.arch, canRestart = () => true, beforeInstall = () => {}, onInstallError = () => {}, onStatus = () => {} }) {
  const url = feedURL(architecture);
  const enabled = Boolean(app.isPackaged && release && process.platform === 'darwin' && url);
  let busy = false, downloaded = false, prompting = false, installing = false;
  let updateState = 'idle';
  const status = () => ({ enabled, updateState });
  const report = state => { updateState = state; onStatus(status()); };
  const show = options => {
    app.focus?.({ steal: true });
    return dialog.showMessageBox({ type: 'info', buttons: ['OK'], ...options });
  };
  async function safeToRestart() {
    try { return await canRestart() === true; } catch { return false; }
  }
  async function failed() {
    busy = false;
    const wasInstalling = installing;
    installing = false;
    report(downloaded ? 'downloaded' : 'error');
    let recovered = true;
    if (wasInstalling) {
      try { await onInstallError(); } catch { recovered = false; }
    }
    await show({ type: 'warning',
      message: wasInstalling ? 'Couldn’t install the update' : 'Couldn’t check or download the update',
      detail: wasInstalling ? (recovered ? 'SaveNest is still open. Your work is kept. Try installing the update again.'
        : 'Your installed app and local library are unchanged. Quit and reopen SaveNest to try again.')
        : 'Your installed app and local library are unchanged. Check your connection and try again.' });
  }
  async function offerInstall() {
    if (prompting) return;
    prompting = true;
    try {
      if (!await safeToRestart()) {
        await show({ message: 'Update downloaded', detail: 'Finish saving your work and close any open dialogs, then check for updates again to restart. You can also quit SaveNest to install the update.' });
        return;
      }
      const result = await show({ message: 'SaveNest is ready to update',
        detail: 'Your local library and settings will be kept. Install and restart now, or install on your next quit.',
        buttons: ['On next quit', 'Install & restart'], defaultId: 0, cancelId: 0 });
      if (result.response === 1 && await safeToRestart()) {
        installing = true;
        try { beforeInstall(); autoUpdater.quitAndInstall(); }
        catch { await failed(); }
      }
    } finally { prompting = false; }
  }
  if (enabled) {
    autoUpdater.setFeedURL({ url, serverType: 'json' });
    autoUpdater.on('update-available', () => { report('downloading'); });
    autoUpdater.on('error', () => { void failed(); });
    autoUpdater.on('update-not-available', () => {
      busy = false;
      report('current');
      void show({ message: 'You’re up to date', detail: `SaveNest ${app.getVersion()} is the latest available release.` });
    });
    autoUpdater.on('update-downloaded', () => { busy = false; downloaded = true; report('downloaded'); void offerInstall(); });
  }
  return {
    enabled,
    get status() { return status(); },
    async check() {
      if (!enabled || busy || installing) return;
      if (downloaded) return offerInstall();
      busy = true;
      report('checking');
      try { autoUpdater.checkForUpdates(); }
      catch { busy = false; report('error'); await show({ type: 'warning', message: 'Couldn’t start the update check', detail: 'Try again from an installed release in Applications.' }); }
    }
  };
}

module.exports = { feedURL, createUpdater, canRestartSafely };
