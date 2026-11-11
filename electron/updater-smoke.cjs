'use strict';
const assert = require('node:assert/strict');

// Use the real helper and the same action as the Settings button. The preview
// host's updater remains disabled, so simulated capability cannot contact a feed.
exports.run = async ({ native, win }) => {
  let state, checks = 0;
  const receive = message => {
    if (message.event === 'state') state = message.state;
    if (message.event === 'checkForUpdates') checks++;
  };
  native.on('event', receive);
  const snapshot = async () => { await native.request({ command: 'snapshot' }); return state; };
  const status = async (updateState, enabled = true) => {
    await native.request({ command: 'updateStatus', enabled, updateState });
    return (await snapshot()).updater;
  };
  try {
    assert.equal((await snapshot()).preview, true);
    for (const command of ['updateStatus', 'checkForUpdates']) {
      await assert.rejects(win.webContents.executeJavaScript(
        `window.savenest.command(${JSON.stringify({ command, enabled: true, updateState: 'idle' })})`
      ), /Unknown Savenest action/, 'renderer cannot impersonate the update host');
    }
    assert.equal((await status('idle', false)).canCheckForUpdates, false);
    await native.request({ command: 'checkForUpdates' });
    assert.equal(checks, 0);
    assert.equal((await status('idle')).canCheckForUpdates, true);
    await native.request({ command: 'checkForUpdates' });
    assert.equal(checks, 1, 'Settings sends its check to the host');
    assert.equal((await snapshot()).updater.state, 'checking');
    await native.request({ command: 'checkForUpdates' });
    assert.equal(checks, 1, 'busy Settings cannot request overlapping checks');
    assert.equal((await status('downloading')).buttonTitle, 'Downloading…');
    assert.equal(state.updater.canCheckForUpdates, false);
    for (const updateState of ['error', 'current']) {
      assert.equal((await status(updateState)).canCheckForUpdates, true);
      await native.request({ command: 'checkForUpdates' });
    }
    assert.equal(checks, 3, 'errors and current releases both permit another manual check');
    assert.equal((await status('downloaded')).buttonTitle, 'Install Update…');
    await native.request({ command: 'checkForUpdates' });
    assert.equal(checks, 4);
    await assert.rejects(native.request({ command: 'updateStatus', enabled: true, updateState: 'unknown' }), /Invalid update status/);
    await native.request({ command: 'settings' });
    assert.equal((await snapshot()).canRestartForUpdate, true, 'plain Settings allows update installation');
    await native.request({ command: 'account' });
    assert.equal((await snapshot()).canRestartForUpdate, false, 'Account may contain unsaved input');
    await native.request({ command: 'settings' });
    await native.request({ command: 'tags' });
    assert.equal((await snapshot()).canRestartForUpdate, false, 'tag editing still blocks update installation');
  } finally {
    await status('idle', false);
    native.removeListener('event', receive);
  }
};
