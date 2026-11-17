'use strict';

const APP_URL = 'savenest-ui://app/index.html';
const commands = new Set(['snapshot', 'search', 'refresh', 'suspend', 'retryContext', 'open', 'copy',
  'save', 'saveClose', 'close', 'favorite', 'archive', 'restore', 'delete', 'undo', 'edit', 'add',
  'account', 'settings', 'tags', 'share', 'cleanup', 'export', 'import', 'capture', 'synchronize', 'onboardingDone', 'privacy', 'analyticsEnabled', 'usageNoticeDismiss', 'dismissMessage',
  'dismiss', 'view', 'historyEnabled', 'historyAccess', 'saveDraft', 'cancelDraft', 'saveSelection', 'cancelSelection', 'saveClipboard', 'readerCurrent', 'readerOpen', 'socialCaptureSettings', 'siteIcon', 'activity', 'activityOpen']);
const scopes = new Set(['All', 'Open', 'Saved', 'History', 'Favorites', 'Notes', 'Archive']);
const activityKinds = new Set(['all', 'saved', 'finished']);
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function daysInMonth(year, month) {
  if (month === 2) return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28;
  return [4, 6, 9, 11].includes(month) ? 30 : 31;
}
function validActivityDay(value, year) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const parsedYear = Number(value.slice(0, 4));
  const month = Number(value.slice(5, 7));
  const day = Number(value.slice(8, 10));
  return parsedYear === year && month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth(parsedYear, month);
}

function validateCommand(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || !commands.has(input.command)) {
    throw new Error('Unknown Savenest action.');
  }
  const result = { command: input.command };
  for (const [key, limit] of Object.entries({ query: 2000, title: 10000, note: 100000, url: 16384, scope: 20, action: 20, view: 20, revision: 128, day: 10, kind: 16 })) {
    if (input[key] === undefined) continue;
    if (typeof input[key] !== 'string' || input[key].length > limit) throw new Error(`Invalid ${key}.`);
    result[key] = input[key];
  }
  if (input.enabled !== undefined) {
    if (typeof input.enabled !== 'boolean') throw new Error('Invalid setting.');
    result.enabled = input.enabled;
  }
  if (result.view !== undefined && !['root', 'editor', 'sources', 'selection', 'activity'].includes(result.view)) throw new Error('Invalid launcher view.');
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
  if (result.command === 'activity') {
    if (!Number.isInteger(input.year) || input.year < 1 || input.year > 9998) throw new Error('Invalid activity year.');
    result.year = input.year;
    if (input.kind !== undefined) {
      if (!activityKinds.has(input.kind)) throw new Error('Invalid activity filter.');
      result.kind = input.kind;
    }
    if (input.day !== undefined) {
      if (!validActivityDay(input.day, input.year)) throw new Error('Invalid activity day.');
      result.day = input.day;
    }
    if (input.offset !== undefined) {
      if (!Number.isSafeInteger(input.offset) || input.offset < 0) throw new Error('Invalid activity offset.');
      result.offset = input.offset;
    }
    if (input.limit !== undefined) {
      if (!Number.isInteger(input.limit) || input.limit < 1 || input.limit > 100) throw new Error('Invalid activity limit.');
      result.limit = input.limit;
    }
    return result;
  }
  if (result.command === 'activityOpen') {
    if (input.url !== undefined) throw new Error('Invalid activity link.');
    if (!Array.isArray(input.ids) || input.ids.length !== 1 || !result.ids
      || result.ids.length !== 1 || !UUID_PATTERN.test(result.ids[0])) throw new Error('Invalid activity link.');
    return { command: 'activityOpen', ids: [result.ids[0]] };
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
    return ['index.html', 'launcher-model.js', 'activity.js', 'renderer.js', 'styles.css', 'activity.css', 'glass.css', 'features.js', 'features.css', 'workspace.html', 'workspace.js', 'workspace.css'].includes(name) ? name : null;
  } catch { return null; }
}

module.exports = { APP_URL, validateCommand, trustedSender, assetName };
