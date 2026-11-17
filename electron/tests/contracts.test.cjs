'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { APP_URL, validateCommand, trustedSender, assetName } = require('../contracts.cjs');

test('renderer cannot invoke auth callbacks, shell commands, or choose its request ID', () => {
  for (const command of ['callback', 'panelWillShow', 'restoreFocus', 'resume', 'exec', 'openExternal', '__proto__']) assert.throws(() => validateCommand({ command }));
  assert.deepEqual(validateCommand({ command: 'snapshot', id: 999, executable: '/bin/sh' }), { command: 'snapshot' });
});
test('commands reject oversized or malformed payloads', () => {
  for (const input of [null, [], { command: 'search', query: 'x'.repeat(2001) }, { command: 'delete', ids: [null] },
    { command: 'edit', tags: Array(101).fill('tag') }, { command: 'edit', tags: ['x'.repeat(51)] },
    { command: 'search', scope: 'Unknown' }, { command: 'capture', action: 'quit' },
    { command: 'historyEnabled', enabled: 'true' }, { command: 'analyticsEnabled', enabled: 'false' }, { command: 'view', view: 'shell' }]) assert.throws(() => validateCommand(input));
});
test('valid scoped search and annotation preserve literal untrusted text', () => {
  const input = { command: 'edit', ids: ['saved:123', 'saved:123'], title: '<img onerror=alert(1)>', note: 'line 1\nline 2', tags: ['Design'] };
  assert.deepEqual(validateCommand(input), { ...input, ids: ['saved:123'] });
  assert.equal(validateCommand({ command: 'search', scope: 'Archive', query: '#read' }).scope, 'Archive');
});
test('saved editor revisions survive IPC and reject malformed values', () => {
  assert.equal(validateCommand({ command: 'edit', revision: 'a'.repeat(64) }).revision, 'a'.repeat(64));
  assert.equal(validateCommand({ command: 'edit', revision: 'missing' }).revision, 'missing');
  assert.throws(() => validateCommand({ command: 'edit', revision: 123 }));
  assert.throws(() => validateCommand({ command: 'edit', revision: 'a'.repeat(129) }));
});
test('IPC only accepts the owning main frame at the exact local app URL', () => {
  const frame = { url: APP_URL }, contents = { mainFrame: frame };
  assert.equal(trustedSender({ sender: contents, senderFrame: frame }, contents), true);
  assert.equal(trustedSender({ sender: {}, senderFrame: frame }, contents), false);
  assert.equal(trustedSender({ sender: contents, senderFrame: { url: APP_URL } }, contents), false);
  frame.url = 'https://savenest.app';
  assert.equal(trustedSender({ sender: contents, senderFrame: frame }, contents), false);
});
test('local protocol serves only fixed launcher assets', () => {
  assert.equal(assetName(APP_URL), 'index.html');
  assert.equal(assetName('savenest-ui://app/styles.css'), 'styles.css');
  assert.equal(assetName('savenest-ui://app/launcher-model.js'), 'launcher-model.js');
  assert.equal(assetName('savenest-ui://app/features.js'), 'features.js');
  assert.equal(assetName('savenest-ui://app/features.css'), 'features.css');
  assert.equal(assetName('savenest-ui://app/activity.js'), 'activity.js');
  assert.equal(assetName('savenest-ui://app/activity.css'), 'activity.css');
  for (const url of ['file:///etc/passwd', 'savenest-ui://elsewhere/index.html', 'savenest-ui://app/../../main.cjs',
    'savenest-ui://app/%2e%2e%2fmain.cjs', 'savenest-ui://app/preload.cjs', 'savenest-ui://user@app/index.html',
    'savenest-ui://app:123/index.html', 'savenest-ui://app/features.json', 'invalid']) assert.equal(assetName(url), null);
});

test('social capture setup is an allowed launcher command', () => {
  assert.deepEqual(validateCommand({ command: 'socialCaptureSettings' }), { command: 'socialCaptureSettings' });
  assert.deepEqual(validateCommand({ command: 'socialCaptureSettings', executable: '/bin/sh', enabled: true }), { command: 'socialCaptureSettings', enabled: true });
  assert.throws(() => validateCommand({ command: 'socialCapture' }));
  assert.throws(() => validateCommand({ command: 'startSocialCapture' }));
});

test('activity accepts bounded yearly, filtered and paginated requests', () => {
  assert.deepEqual(validateCommand({ command: 'activity', year: 2026 }), { command: 'activity', year: 2026 });
  assert.deepEqual(validateCommand({ command: 'activity', year: 2024, kind: 'finished', day: '2024-02-29', offset: 100, limit: 50 }),
    { command: 'activity', year: 2024, kind: 'finished', day: '2024-02-29', offset: 100, limit: 50 });
  assert.equal(validateCommand({ command: 'activity', year: 1, kind: 'saved' }).year, 1);
  assert.equal(validateCommand({ command: 'activity', year: 9998 }).year, 9998);
  assert.equal(validateCommand({ command: 'activity', year: 2026, offset: Number.MAX_SAFE_INTEGER }).offset, Number.MAX_SAFE_INTEGER);
  for (const input of [
    { command: 'activity' }, { command: 'activity', year: '2026' }, { command: 'activity', year: 0 },
    { command: 'activity', year: 9999 }, { command: 'activity', year: 2026.5 }, { command: 'activity', year: 2026, kind: 'archived' },
    { command: 'activity', year: 2026, day: '2026-13-01' }, { command: 'activity', year: 2026, day: '2026-02-29' },
    { command: 'activity', year: 2025, day: '2026-01-01' }, { command: 'activity', year: 2026, offset: -1 },
    { command: 'activity', year: 2026, offset: 1.5 }, { command: 'activity', year: 2026, offset: Number.MAX_SAFE_INTEGER + 1 },
    { command: 'activity', year: 2026, limit: 0 }, { command: 'activity', year: 2026, limit: 101 }, { command: 'activity', year: 2026, limit: 1.5 }
  ]) assert.throws(() => validateCommand(input), JSON.stringify(input));
});

test('activity links require exactly one validated UUID and never accept a URL', () => {
  const id = '123e4567-e89b-42d3-a456-426614174000';
  assert.deepEqual(validateCommand({ command: 'activityOpen', ids: [id] }), { command: 'activityOpen', ids: [id] });
  for (const input of [
    { command: 'activityOpen' }, { command: 'activityOpen', ids: [] }, { command: 'activityOpen', ids: [id, id] },
    { command: 'activityOpen', ids: ['not-a-uuid'] }, { command: 'activityOpen', ids: [id], url: 'https://example.com/' }
  ]) assert.throws(() => validateCommand(input), JSON.stringify(input));
});

test('privacy actions cannot supply a destination or enable analytics with a non-boolean', () => {
  assert.deepEqual(validateCommand({ command: 'privacy', destination: 'https://attacker.example' }), { command: 'privacy' });
  assert.deepEqual(validateCommand({ command: 'analyticsEnabled', enabled: false }), { command: 'analyticsEnabled', enabled: false });
  assert.deepEqual(validateCommand({ command: 'usageNoticeDismiss' }), { command: 'usageNoticeDismiss' });
  assert.throws(() => validateCommand({ command: 'analyticsEnabled', enabled: 1 }));
});
