'use strict';

const glassWindowOptions = { backgroundColor: '#00000000', vibrancy: 'under-window', visualEffectState: 'active' };
const applied = new WeakMap();

function updateWindowMaterial(window, { appearance = 'black', reducedTransparency = false, highContrast = false } = {}) {
  if (!window || window.isDestroyed()) return;
  const opaque = reducedTransparency || highContrast;
  const background = opaque ? (appearance === 'cream' ? '#edf3fa' : '#111e30') : '#00000000';
  const key = `${opaque}:${background}`;
  if (applied.get(window) === key) return;
  window.setVibrancy(opaque ? null : 'under-window');
  window.setBackgroundColor(background);
  applied.set(window, key);
}

module.exports = { glassWindowOptions, updateWindowMaterial };
