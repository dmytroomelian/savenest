'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { updateWindowMaterial } = require('../window-material.cjs');

test('system accessibility preferences replace desktop blur with an opaque surface in either appearance', () => {
  const calls = [];
  const window = { isDestroyed: () => false, setVibrancy: value => calls.push(['vibrancy', value]), setBackgroundColor: value => calls.push(['background', value]) };
  updateWindowMaterial(window);
  assert.deepEqual(calls.splice(0), [['vibrancy', 'under-window'], ['background', '#00000000']]);
  updateWindowMaterial(window, { reducedTransparency: true });
  assert.deepEqual(calls.splice(0), [['vibrancy', null], ['background', '#111e30']]);
  updateWindowMaterial(window, { appearance: 'cream', highContrast: true });
  assert.deepEqual(calls.splice(0), [['vibrancy', null], ['background', '#edf3fa']]);
  updateWindowMaterial(window, { appearance: 'cream' });
  assert.deepEqual(calls.splice(0), [['vibrancy', 'under-window'], ['background', '#00000000']]);
  updateWindowMaterial(window, { appearance: 'cream' });
  assert.deepEqual(calls, []);
  window.isDestroyed = () => true;
  updateWindowMaterial(window, { reducedTransparency: true });
  assert.deepEqual(calls, []);
});
