'use strict';

const nativeWindowCommands = new Set(['account', 'settings', 'socialCaptureSettings', 'tags']);

function isNativeWindowCommand(input) {
  return Boolean(input) && nativeWindowCommands.has(input.command);
}

// Hide the launcher before the helper raises its own window. Browser focus must
// stay untouched during this handoff, so hide is called without restoreFocus.
// If the helper rejects, bring the launcher back instead of leaving it stranded.
async function requestNativeWindowCommand(input, { hide, show, request }) {
  if (!isNativeWindowCommand(input)) return request(input);
  hide(false);
  try {
    return await request(input);
  } catch (error) {
    try { await show(); } catch {}
    throw error;
  }
}

module.exports = { nativeWindowCommands, isNativeWindowCommand, requestNativeWindowCommand };
