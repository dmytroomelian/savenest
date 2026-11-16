'use strict';
const path = require('node:path');

// The outer app receives Services before its library helper may be ready.
// Serialize requests so a later request cannot overwrite the first editor.
function createServiceQueue({ capture, onError }) {
  const pending = [];
  let ready = false, draining = false;
  async function drain() {
    if (!ready || draining) return;
    draining = true;
    try {
      while (pending.length) {
        try { await capture(pending.shift()); }
        catch (error) { onError(error); }
      }
    } finally { draining = false; }
  }
  return {
    receive(url) {
      if (typeof url !== 'string' || Buffer.byteLength(url) > 8192) {
        onError(new Error('Select one complete http:// or https:// web address.')); return;
      }
      if (pending.length >= 10) { onError(new Error('SaveNest is busy. Please try again.')); return; }
      pending.push(url); void drain();
    },
    ready() { ready = true; void drain(); }
  };
}

function registerServices({ app, root, preview, receive }) {
  if (preview) return;
  const binary = app.isPackaged
    ? path.join(process.resourcesPath, 'native/savenest-services.node')
    : path.join(root, 'build/services', process.arch, 'savenest-services.node');
  require(binary).register(receive);
}

module.exports = { createServiceQueue, registerServices };
