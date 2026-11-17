'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { EventEmitter } = require('node:events');
const { execFileSync } = require('node:child_process');
const { copyApplication, offerInstallation, resolveStartupConflict, handoff } = require('../installation.cjs');
const { NativeClient } = require('../native-client.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'savenest-install-test-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const applications = path.join(root, 'Applications');
  const source = path.join(root, 'SaveNest 2.app');
  await fs.mkdir(applications); await fs.mkdir(source);
  await fs.writeFile(path.join(source, 'app'), 'new app');
  const calls = []; let lock = true;
  const app = {
    isPackaged: true, isInApplicationsFolder: () => false, getPath: () => root,
    releaseSingleInstanceLock() { lock = false; calls.push('release'); },
    requestSingleInstanceLock() { lock = true; calls.push('reacquire'); return true; },
    hasSingleInstanceLock: () => lock,
    quit() { calls.push('quit'); }, relaunch() { calls.push('relaunch'); }
  };
  const messages = [];
  const options = { app, release: true, applications, userApplications: path.join(root, 'UserApplications'), source, argv: [],
    dialog: { showMessageBox: async value => { messages.push(value); return { response: 0 }; } },
    identify: async () => true, open: async destination => { assert.equal(lock, false); calls.push(destination); } };
  return { ...options, options, calls, messages };
}

test('first install uses canonical name, keeps source, and releases lock before launch', async t => {
  const f = await fixture(t);
  execFileSync('/usr/bin/xattr', ['-w', 'com.apple.quarantine', '0081;00000000;SaveNestInstallerTest;', f.source]);
  assert.equal(await offerInstallation(f.options), true);
  const destination = path.join(f.applications, 'SaveNest.app');
  assert.equal(await fs.readFile(path.join(destination, 'app'), 'utf8'), 'new app');
  assert.equal(await fs.readFile(path.join(f.source, 'app'), 'utf8'), 'new app');
  assert.deepEqual(f.calls, ['release', destination, 'quit']);
  assert.deepEqual(await fs.readdir(f.applications), ['SaveNest.app']);
  assert.equal(execFileSync('/usr/bin/xattr', [destination], { encoding: 'utf8' }).includes('com.apple.quarantine'), false);
  assert.equal(execFileSync('/usr/bin/xattr', [f.source], { encoding: 'utf8' }).includes('com.apple.quarantine'), true);
});

test('repeat download opens installed native or Electron copy without replacing it', async t => {
  const f = await fixture(t);
  const destination = path.join(f.applications, 'SaveNest.app');
  await fs.mkdir(destination); await fs.writeFile(path.join(destination, 'app'), 'old app');
  assert.equal(await offerInstallation({ ...f.options, copy: () => { throw new Error('must not copy'); } }), true);
  assert.equal(await fs.readFile(path.join(destination, 'app'), 'utf8'), 'old app');
  assert.equal(f.messages[0].buttons[0], 'Open Savenest');
});

test('user Applications copy is recognized before installing another copy', async t => {
  const f = await fixture(t);
  const destination = path.join(f.userApplications, 'SaveNest.app');
  await fs.mkdir(destination, { recursive: true });
  assert.equal(await offerInstallation(f.options), true);
  assert.deepEqual(f.calls, ['release', destination, 'quit']);
  assert.deepEqual(await fs.readdir(f.applications), []);
});

test('cancel, development, installed, and callback launches leave app usable without installing', async t => {
  const f = await fixture(t);
  for (const override of [
    { release: false }, { app: { ...f.app, isPackaged: false } },
    { app: { ...f.app, isInApplicationsFolder: () => true } },
    { argv: ['--savenest-installed'] }, { hasPendingURLs: () => true },
    { dialog: { showMessageBox: async () => ({ response: 1 }) } }
  ]) assert.equal(await offerInstallation({ ...f.options, ...override }), false);
  assert.deepEqual(f.calls, []);
  assert.deepEqual(await fs.readdir(f.applications), []);
});

test('a sign-in callback arriving during confirmation cancels handoff', async t => {
  const f = await fixture(t); let pending = false;
  assert.equal(await offerInstallation({ ...f.options, hasPendingURLs: () => pending,
    dialog: { showMessageBox: async () => { pending = true; return { response: 0 }; } } }), false);
  assert.deepEqual(f.calls, []);
});

test('failed copying leaves no partial installation and allows continuing', async t => {
  const f = await fixture(t);
  assert.equal(await offerInstallation({ ...f.options, copy: (source, applications) => copyApplication(source, applications,
    async (_from, to) => { await fs.mkdir(to); throw new Error('disk full'); }) }), false);
  assert.deepEqual(await fs.readdir(f.applications), []);
  assert.equal(f.messages.at(-1).buttons[0], 'Continue');
  assert.deepEqual(f.calls, []);
});

test('a sign-in callback arriving during a large copy stays in the current process', async t => {
  const f = await fixture(t); let pending = false;
  assert.equal(await offerInstallation({ ...f.options, hasPendingURLs: () => pending,
    copy: async (...args) => { const destination = await copyApplication(...args); pending = true; return destination; } }), false);
  assert.deepEqual(f.calls, []);
  assert.deepEqual(await fs.readdir(f.applications), ['SaveNest.app']);
});

test('an existing destination or concurrent installation cannot be overwritten', async t => {
  const f = await fixture(t);
  const destination = path.join(f.applications, 'SaveNest.app');
  await assert.rejects(copyApplication(f.source, f.applications, async (source, to) => {
    await fs.cp(source, to, { recursive: true });
    await fs.mkdir(destination); await fs.writeFile(path.join(destination, 'app'), 'other installer');
  }), { code: 'EEXIST' });
  await assert.rejects(copyApplication(f.source, f.applications), { code: 'EEXIST' });
  assert.equal(await fs.readFile(path.join(destination, 'app'), 'utf8'), 'other installer');
  assert.deepEqual(await fs.readdir(f.applications), ['SaveNest.app']);
});

test('failed launch restores the single-instance lock and keeps the download usable', async t => {
  const f = await fixture(t);
  await assert.rejects(handoff({ ...f.options, destination: 'fixture', open: async () => { throw new Error('launch failed'); } }));
  assert.deepEqual(f.calls, ['release', 'reacquire']);
});

test('running-copy recovery supports opening existing app, retrying, and quitting', async t => {
  const f = await fixture(t);
  for (const response of [0, 1, 2]) {
    f.calls.length = 0;
    await resolveStartupConflict({ ...f.options, existingAppPath: 'existing.app',
      dialog: { showMessageBox: async () => ({ response }) } });
    assert.deepEqual(f.calls, response === 0 ? ['release', 'existing.app', 'quit'] : response === 1 ? ['relaunch', 'quit'] : ['quit']);
  }
});

test('helper exit cannot overwrite a startup conflict with a generic fatal error', async () => {
  const client = new EventEmitter(); Object.setPrototypeOf(client, NativeClient.prototype);
  Object.assign(client, { buffer: '', pending: new Map(), sequence: 0, closed: false });
  const events = [], failures = [];
  client.on('event', event => events.push(event)); client.on('failure', error => failures.push(error));
  client.receive(JSON.stringify({ event: 'startup-conflict', existingAppPath: '/fixture/SaveNest.app' }) + '\n');
  client.fail('The native helper stopped.');
  assert.equal(events.length, 1); assert.deepEqual(failures, []); assert.equal(client.closed, true);
  await assert.rejects(client.request({ command: 'snapshot' }));
});
