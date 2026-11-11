'use strict';

const APP_URL = 'savenest-ui://app/index.html';
const commands = new Set(['snapshot', 'search', 'refresh', 'suspend', 'retryContext', 'open', 'copy',
  'save', 'saveClose', 'close', 'favorite', 'archive', 'restore', 'delete', 'undo', 'edit', 'add',
  'account', 'settings', 'tags', 'share', 'cleanup', 'export', 'import', 'capture', 'synchronize', 'onboardingDone', 'privacy', 'analyticsEnabled', 'usageNoticeDismiss', 'dismissMessage',
  'dismiss', 'view', 'historyEnabled', 'historyAccess', 'saveDraft', 'cancelDraft', 'saveSelection', 'cancelSelection', 'saveClipboard', 'readerCurrent', 'readerOpen']);
const scopes = new Set(['All', 'Open', 'Saved', 'History', 'Favorites', 'Notes', 'Archive']);

function validateCommand(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || !commands.has(input.command)) {
    throw new Error('Unknown Savenest action.');
  }
  const result = { command: input.command };
  for (const [key, limit] of Object.entries({ query: 2000, title: 10000, note: 100000, url: 16384, scope: 20, action: 20, view: 20 })) {
    if (input[key] === undefined) continue;
    if (typeof input[key] !== 'string' || input[key].length > limit) throw new Error(`Invalid ${key}.`);
    result[key] = input[key];
  }
  if (input.enabled !== undefined) {
    if (typeof input.enabled !== 'boolean') throw new Error('Invalid setting.');
    result.enabled = input.enabled;
  }
  if (result.view !== undefined && !['root', 'editor', 'sources', 'selection'].includes(result.view)) throw new Error('Invalid launcher view.');
  for (const [key, count, length] of [['ids', 2000, 2000], ['tags', 100, 50]]) {
    if (input[key] === undefined) continue;
    if (!Array.isArray(input[key]) || input[key].length > count || input[key].some(v => typeof v !== 'string' || v.length > length)) {
      throw new Error(`Invalid ${key}.`);
    }
    result[key] = [...new Set(input[key])];
  }
  if (result.scope !== undefined && !scopes.has(result.scope)) throw new Error('Invalid search scope.');
  if (result.action !== undefined && !['quick', 'note', 'selected', 'window', 'search', 'duplicates'].includes(result.action)) {
    throw new Error('Invalid capture action.');
  }
  return result;
}

function trustedSender(event, webContents) {
  return event.sender === webContents && event.senderFrame === webContents.mainFrame && event.senderFrame?.url === APP_URL;
}

function assetName(raw) {
  try {
    const url = new URL(raw);
    if (url.protocol !== 'savenest-ui:' || url.hostname !== 'app' || url.port || url.username || url.password) return null;
    const name = url.pathname.slice(1);
    return ['index.html', 'launcher-model.js', 'renderer.js', 'styles.css', 'glass.css', 'workspace.html', 'workspace.js', 'workspace.css'].includes(name) ? name : null;
  } catch { return null; }
}

module.exports = { APP_URL, validateCommand, trustedSender, assetName };
