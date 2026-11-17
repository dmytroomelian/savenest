'use strict';

function loginItemStatus(app, { preview = false, enabled } = {}) {
  if (preview || !app.isPackaged) return {
    enabled: false, available: false,
    message: preview ? 'Startup settings are disabled in Preview.' : 'Install Savenest to configure launch at login.'
  };
  try {
    if (typeof enabled === 'boolean') app.setLoginItemSettings({ openAtLogin: enabled });
    const state = app.getLoginItemSettings();
    const registered = state.openAtLogin || state.status === 'requires-approval';
    return {
      enabled: registered, available: true,
      message: state.status === 'requires-approval'
        ? 'Allow Savenest in System Settings → General → Login Items.'
        : typeof enabled === 'boolean' && registered !== enabled
          ? 'macOS did not apply this change. Check Login Items in System Settings.'
          : 'Open Savenest automatically when you log in to your Mac.'
    };
  } catch (error) {
    let registered = false;
    try { const state = app.getLoginItemSettings(); registered = state.openAtLogin || state.status === 'requires-approval'; } catch {}
    return { enabled: registered, available: true, message: `Could not change startup settings: ${error.message}` };
  }
}
module.exports = { loginItemStatus };
