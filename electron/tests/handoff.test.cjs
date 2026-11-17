'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { isNativeWindowCommand, requestNativeWindowCommand } = require('../window-handoff.cjs');

function harness({ fail = false, showFails = false } = {}) {
  const calls = [];
  return {
    calls,
    options: {
      hide: (...args) => { calls.push(['hide', ...args]); },
      show: async (...args) => { calls.push(['show', ...args]); if (showFails) throw new Error('show failed'); },
      request: async request => {
        calls.push(['request', request.command]);
        if (fail) throw new Error('native failed');
        return 'ok';
      }
    }
  };
}

const nativeWindowCommands = ['account', 'settings', 'socialCaptureSettings', 'tags'];

for (const command of nativeWindowCommands) {
  test(`${command} hides the launcher before the native window opens without restoring browser focus`, async () => {
    assert.equal(isNativeWindowCommand({ command }), true);
    const { calls, options } = harness();
    assert.equal(await requestNativeWindowCommand({ command }, options), 'ok');
    assert.deepEqual(calls, [['hide', false], ['request', command]]);
  });
}

for (const command of nativeWindowCommands) {
  test(`a failed ${command} native window handoff shows the launcher again`, async () => {
    const { calls, options } = harness({ fail: true });
    await assert.rejects(requestNativeWindowCommand({ command }, options), /native failed/);
    assert.deepEqual(calls, [['hide', false], ['request', command], ['show']]);
  });
}

for (const command of nativeWindowCommands) {
  test(`handoff error recovery preserves the original ${command} failure if showing also fails`, async () => {
    const { calls, options } = harness({ fail: true, showFails: true });
    await assert.rejects(requestNativeWindowCommand({ command }, options), /native failed/);
    assert.deepEqual(calls, [['hide', false], ['request', command], ['show']]);
  });
}

test('other native commands do not hide or show the launcher, even on failure', async () => {
  assert.equal(isNativeWindowCommand({ command: 'requestFeature' }), false);
  const success = harness();
  assert.equal(await requestNativeWindowCommand({ command: 'refresh' }, success.options), 'ok');
  assert.deepEqual(success.calls, [['request', 'refresh']]);
  const failure = harness({ fail: true });
  await assert.rejects(requestNativeWindowCommand({ command: 'refresh' }, failure.options), /native failed/);
  assert.deepEqual(failure.calls, [['request', 'refresh']]);
});
