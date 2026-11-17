'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loginItemStatus } = require('../login-item.cjs');

function fakeApp(state = { openAtLogin: false, status: 'not-registered' }) {
  return { isPackaged: true, calls: [], getLoginItemSettings: () => state,
    setLoginItemSettings(value) { this.calls.push(value); state = { openAtLogin: value.openAtLogin, status: value.openAtLogin ? 'enabled' : 'not-registered' }; } };
}
test('startup reads system state and toggles the host app in both directions', () => {
  const app = fakeApp();
  assert.equal(loginItemStatus(app).enabled, false);
  assert.deepEqual(app.calls, []);
  assert.equal(loginItemStatus(app, { enabled: true }).enabled, true);
  assert.equal(loginItemStatus(app, { enabled: false }).enabled, false);
  assert.deepEqual(app.calls, [{ openAtLogin: true }, { openAtLogin: false }]);
});
test('preview and development never register login items', () => {
  const app = fakeApp();
  assert.equal(loginItemStatus(app, { preview: true, enabled: true }).available, false);
  app.isPackaged = false;
  assert.equal(loginItemStatus(app, { enabled: true }).available, false);
  assert.deepEqual(app.calls, []);
});
test('pending approval stays switchable and explains the required system action', () => {
  const result = loginItemStatus(fakeApp({ openAtLogin: false, status: 'requires-approval' }));
  assert.equal(result.enabled, true);
  assert.equal(result.available, true);
  assert.match(result.message, /System Settings/);
});
test('failed changes retain actual state and show the error', () => {
  const app = fakeApp({ openAtLogin: true, status: 'enabled' });
  app.setLoginItemSettings = () => { throw new Error('Denied'); };
  const result = loginItemStatus(app, { enabled: false });
  assert.equal(result.enabled, true);
  assert.match(result.message, /Denied/);
});
test('silently ignored registration is reported, not shown as enabled', () => {
  const app = fakeApp();
  app.setLoginItemSettings = () => {};
  const result = loginItemStatus(app, { enabled: true });
  assert.equal(result.enabled, false);
  assert.match(result.message, /did not apply/);
});
