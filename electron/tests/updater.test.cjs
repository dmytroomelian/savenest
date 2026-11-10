'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { feedURL, createUpdater, canRestartSafely } = require('../updater.cjs');

function fixture(overrides = {}) {
  const autoUpdater = new EventEmitter();
  const calls = { checks: 0, installs: 0, before: 0, installRecoveries: 0, messages: [], statuses: [] };
  autoUpdater.setFeedURL = value => { calls.feed = value; };
  autoUpdater.checkForUpdates = () => { calls.checks++; };
  autoUpdater.quitAndInstall = () => { calls.installs++; };
  const dialog = { showMessageBox: async value => { calls.messages.push(value); return { response: 1 }; } };
  const updater = createUpdater({ app: { isPackaged: true, getVersion: () => '0.11.0' }, autoUpdater, dialog,
    release: true, architecture: 'arm64', beforeInstall: () => { calls.before++; },
    onInstallError: () => { calls.installRecoveries++; },
    onStatus: status => calls.statuses.push({ ...status }), ...overrides });
  return { updater, autoUpdater, calls };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

test('architecture selects a fixed HTTPS Electron feed; unknown architectures are unsupported', () => {
  assert.equal(feedURL('arm64'), 'https://savenest.app/downloads/electron/arm64/RELEASES.json');
  assert.equal(feedURL('x64'), 'https://savenest.app/downloads/electron/x64/RELEASES.json');
  assert.equal(feedURL('../appcast.xml'), null);
});
test('development packages never configure or contact the production updater', async () => {
  for (const options of [{ release: false }, { app: { isPackaged: false } }, { architecture: 'invalid' }]) {
    const { updater, calls } = fixture(options);
    assert.deepEqual(updater.status, { enabled: false, updateState: 'idle' });
    const initialStatuses = calls.statuses.length;
    await updater.check(); await updater.check();
    assert.equal(updater.enabled, false); assert.equal(calls.feed, undefined); assert.equal(calls.checks, 0);
    assert.deepEqual(updater.status, { enabled: false, updateState: 'idle' });
    assert.equal(calls.statuses.length, initialStatuses);
  }
});
test('checks are explicit, overlapping checks are ignored, and current status permits another manual check', async () => {
  const { updater, calls, autoUpdater } = fixture();
  if (process.platform !== 'darwin') return;
  assert.equal(calls.checks, 0); assert.equal(calls.feed.serverType, 'json');
  assert.deepEqual(updater.status, { enabled: true, updateState: 'idle' });
  const initialStatuses = calls.statuses.length;
  await updater.check();
  assert.deepEqual(updater.status, { enabled: true, updateState: 'checking' });
  await updater.check(); assert.equal(calls.checks, 1);
  assert.deepEqual(calls.statuses.slice(initialStatuses), [{ enabled: true, updateState: 'checking' }]);
  autoUpdater.emit('update-not-available'); await tick();
  assert.deepEqual(updater.status, { enabled: true, updateState: 'current' });
  assert.deepEqual(calls.statuses.at(-1), updater.status);
  await updater.check(); assert.equal(calls.checks, 2);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'checking' });
  assert.deepEqual(calls.statuses.slice(initialStatuses).map(status => status.updateState), ['checking', 'current', 'checking']);
});
test('manual update reports checking, downloading and downloaded without starting overlapping downloads', async () => {
  const { updater, autoUpdater, calls } = fixture({ canRestart: () => false });
  if (process.platform !== 'darwin') return;
  const initialStatuses = calls.statuses.length;
  await updater.check();
  autoUpdater.emit('update-available');
  assert.deepEqual(updater.status, { enabled: true, updateState: 'downloading' });
  assert.deepEqual(calls.statuses.at(-1), updater.status);
  await updater.check();
  assert.equal(calls.checks, 1);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'downloading' });
  autoUpdater.emit('update-downloaded'); await tick();
  assert.deepEqual(updater.status, { enabled: true, updateState: 'downloaded' });
  assert.deepEqual(calls.statuses.slice(initialStatuses), [
    { enabled: true, updateState: 'checking' },
    { enabled: true, updateState: 'downloading' },
    { enabled: true, updateState: 'downloaded' }
  ]);
  await updater.check();
  assert.equal(calls.checks, 1);
  assert.equal(calls.installs, 0);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'downloaded' });
});
test('downloaded update only restarts after a confirmed choice and prepares host closure', async () => {
  const { autoUpdater, calls } = fixture();
  if (process.platform !== 'darwin') return;
  autoUpdater.emit('update-downloaded'); await tick();
  assert.equal(calls.before, 1); assert.equal(calls.installs, 1);
});
test('canceling immediate installation keeps the update available without preparing host closure', async () => {
  let response = 0;
  const { updater, autoUpdater, calls } = fixture({ dialog: { showMessageBox: async () => ({ response }) } });
  if (process.platform !== 'darwin') return;
  autoUpdater.emit('update-downloaded'); await tick();
  assert.equal(calls.before, 0); assert.equal(calls.installs, 0); assert.equal(calls.installRecoveries, 0);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'downloaded' });
  response = 1; await updater.check();
  assert.equal(calls.before, 1); assert.equal(calls.installs, 1); assert.equal(calls.checks, 0);
});
test('an asynchronous installation failure restores host state and permits retry of the downloaded update', async () => {
  const { updater, autoUpdater, calls } = fixture();
  if (process.platform !== 'darwin') return;
  autoUpdater.emit('update-downloaded'); await tick();
  assert.equal(calls.before, 1); assert.equal(calls.installs, 1); assert.equal(calls.installRecoveries, 0);
  autoUpdater.emit('error', new Error('installer failed')); await tick();
  assert.equal(calls.installRecoveries, 1);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'downloaded' });
  assert.deepEqual(calls.statuses.at(-1), updater.status);
  assert.equal(calls.messages.at(-1).message, 'Couldn’t install the update');
  assert.equal(calls.messages.at(-1).type, 'warning');
  await updater.check();
  assert.equal(calls.before, 2); assert.equal(calls.installs, 2); assert.equal(calls.checks, 0);
  assert.equal(calls.installRecoveries, 1);
});
test('a synchronous installation failure restores host state and permits a successful manual retry', async () => {
  const { updater, autoUpdater, calls } = fixture();
  if (process.platform !== 'darwin') return;
  autoUpdater.quitAndInstall = () => {
    calls.installs++;
    if (calls.installs === 1) throw new Error('installer could not start');
  };
  autoUpdater.emit('update-downloaded'); await tick();
  assert.equal(calls.before, 1); assert.equal(calls.installs, 1); assert.equal(calls.installRecoveries, 1);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'downloaded' });
  assert.deepEqual(calls.statuses.at(-1), updater.status);
  assert.equal(calls.messages.at(-1).message, 'Couldn’t install the update');
  assert.equal(calls.messages.at(-1).type, 'warning');
  await updater.check();
  assert.equal(calls.before, 2); assert.equal(calls.installs, 2); assert.equal(calls.checks, 0);
  assert.equal(calls.installRecoveries, 1);
});
test('active drafts prevent updater-initiated restart; a later check can offer installation', async () => {
  let safe = false;
  const { updater, autoUpdater, calls } = fixture({ canRestart: () => safe });
  if (process.platform !== 'darwin') return;
  autoUpdater.emit('update-downloaded'); await tick(); assert.equal(calls.installs, 0);
  safe = true; await updater.check(); assert.equal(calls.installs, 1); assert.equal(calls.checks, 0);
});
test('failed updates permit retry without altering installed app', async () => {
  const { updater, autoUpdater, calls } = fixture();
  if (process.platform !== 'darwin') return;
  const initialStatuses = calls.statuses.length;
  await updater.check(); autoUpdater.emit('error', new Error('offline')); await tick();
  assert.equal(calls.installRecoveries, 0);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'error' });
  assert.deepEqual(calls.statuses.at(-1), updater.status);
  await updater.check(); assert.equal(calls.checks, 2); assert.equal(calls.installs, 0);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'checking' });
  assert.deepEqual(calls.statuses.slice(initialStatuses).map(status => status.updateState), ['checking', 'error', 'checking']);
});
test('a synchronous check failure reports error and leaves manual retry available', async () => {
  const { updater, autoUpdater, calls } = fixture();
  if (process.platform !== 'darwin') return;
  const initialStatuses = calls.statuses.length;
  autoUpdater.checkForUpdates = () => {
    calls.checks++;
    if (calls.checks === 1) throw new Error('update service unavailable');
  };
  await updater.check();
  assert.deepEqual(updater.status, { enabled: true, updateState: 'error' });
  assert.deepEqual(calls.statuses.at(-1), updater.status);
  assert.equal(calls.installs, 0);
  await updater.check();
  assert.equal(calls.checks, 2);
  assert.deepEqual(updater.status, { enabled: true, updateState: 'checking' });
  autoUpdater.emit('update-not-available'); await tick();
  assert.deepEqual(updater.status, { enabled: true, updateState: 'current' });
  assert.deepEqual(calls.statuses.slice(initialStatuses).map(status => status.updateState), ['checking', 'error', 'checking', 'current']);
});

test('restart fails closed for missing helper state, native sheets, pending captures, and connection failures', () => {
  const safe = { canRestartForUpdate: true, busy: false, captureDraft: null, captureSelection: null };
  assert.equal(canRestartSafely({ view: 'root', state: safe }), true);
  for (const input of [
    { view: 'root' }, { view: 'root', state: {} },
    { view: 'root', state: { ...safe, canRestartForUpdate: false } },
    { view: 'editor', state: safe }, { view: 'selection', state: safe },
    { view: 'root', state: { ...safe, busy: true } },
    { view: 'root', state: { ...safe, captureDraft: { id: 'draft' } } },
    { view: 'root', state: { ...safe, captureSelection: { id: 'selection' } } },
    { view: 'root', state: safe, failed: true }
  ]) assert.equal(canRestartSafely(input), false);
});

test('restart rechecks fresh asynchronous helper state after confirmation', async () => {
  let checks = 0;
  const { autoUpdater, calls } = fixture({ canRestart: async () => ++checks === 1 });
  if (process.platform !== 'darwin') return;
  autoUpdater.emit('update-downloaded'); await tick();
  assert.equal(checks, 2); assert.equal(calls.installs, 0);
});
test('a failed helper readiness request never restarts the app', async () => {
  const { autoUpdater, calls } = fixture({ canRestart: async () => { throw new Error('disconnected'); } });
  if (process.platform !== 'darwin') return;
  autoUpdater.emit('update-downloaded'); await tick();
  assert.equal(calls.installs, 0);
});
