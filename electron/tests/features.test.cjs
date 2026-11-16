'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { JSDOM, VirtualConsole } = require('jsdom');
const model = require('../renderer/launcher-model.js');
const catalog = require('../renderer/features.js');

const rendererDirectory = path.resolve(__dirname, '../renderer');
const html = readFileSync(path.join(rendererDirectory, 'index.html'), 'utf8');
const scripts = ['launcher-model.js', 'features.js', 'renderer.js'].map(name => readFileSync(path.join(rendererDirectory, name), 'utf8'));
const page = { id: 'saved:one', title: 'A saved page', url: 'https://example.com/one', domain: 'example.com', isSaved: true, tags: [] };

function launcher(t, initial = {}) {
  const errors = [], calls = [];
  const virtualConsole = new VirtualConsole();
  virtualConsole.on('jsdomError', error => errors.push(error));
  const dom = new JSDOM(html, { url: 'https://savenest.test/index.html', runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole });
  const { window } = dom, { document } = window;
  let onEvent;
  window.savenest = {
    command: async request => { calls.push(JSON.parse(JSON.stringify(request))); return true; },
    onEvent: handler => { onEvent = handler; }
  };
  window.HTMLElement.prototype.scrollIntoView = function () {};
  window.HTMLDialogElement.prototype.showModal = function () { this.open = true; };
  window.HTMLDialogElement.prototype.close = function () {
    if (!this.open) return;
    this.open = false;
    this.dispatchEvent(new window.Event('close'));
  };
  for (const script of scripts) window.eval(script);
  let snapshot = { rows: [], query: '', scope: 'All', tags: [], loading: false, historySources: [], message: '', ...initial };
  const update = change => { snapshot = { ...snapshot, ...change }; onEvent({ event: 'state', state: snapshot }); };
  update({});
  calls.length = 0;
  t.after(() => { window.close(); assert.deepEqual(errors, [], 'renderer must not emit unhandled DOM errors'); });
  const byID = id => document.getElementById(id);
  const key = (value, target = document.activeElement, modifiers = {}) => {
    const event = new window.KeyboardEvent('keydown', { key: value, bubbles: true, cancelable: true, ...modifiers });
    target.dispatchEvent(event);
    return event;
  };
  const action = title => {
    const button = [...document.querySelectorAll('#action-options button')].find(node => node.querySelector('.action-title')?.textContent === title);
    assert.ok(button, `Actions must expose ${title}`);
    return button;
  };
  const featureAction = id => {
    const card = document.querySelector(`.feature-card[data-feature-id="${id}"]`);
    assert.ok(card, `Feature catalog must expose ${id}`);
    return card.querySelector('.feature-action');
  };
  return { window, document, calls, update, byID, key, action, featureAction, event: message => onEvent(message) };
}

test('Explore features is discoverable in root search, Actions and the persistent footer', t => {
  const root = model.commands('');
  const explore = root.find(item => item.id === 'command:explore');
  assert.ok(explore, 'empty root search must offer Explore features');
  assert.equal(explore.ui, 'features');
  assert.equal(explore.title, 'Explore features');
  assert.ok(model.commands('guide').some(item => item.id === 'command:explore'));
  assert.equal(model.actionCatalog({}).find(item => item.id === 'command:explore')?.group, 'Savenest');

  const ui = launcher(t);
  assert.equal(ui.byID('show-features').textContent, 'Explore features');
  const trigger = ui.byID('show-features');
  trigger.focus(); trigger.click();
  assert.equal(ui.byID('features-dialog').open, true);
  assert.equal(ui.document.activeElement, ui.byID('features-search'));
  ui.key('Escape', ui.byID('features-search'));
  assert.equal(ui.byID('features-dialog').open, false);

  ui.byID('actions').click();
  ui.action('Explore features').click();
  assert.equal(ui.byID('action-dialog').open, false);
  assert.equal(ui.byID('features-dialog').open, true);
});

test('the social capture card summarizes setup, limits and evidence', t => {
  const ui = launcher(t);
  ui.byID('show-features').click();
  const card = ui.document.querySelector('.feature-card[data-feature-id="social-capture"]');
  assert.ok(card);
  const text = card.textContent;
  assert.match(text, /Save from other apps/);
  assert.deepEqual([...card.querySelectorAll('.feature-badge')].map(node => node.textContent), ['Pro', 'Beta']);
  assert.match(card.querySelector('.feature-description').textContent, /How it works/i);
  const points = [...card.querySelectorAll('.social-points li')];
  assert.equal(points.length, 4);
  for (const point of points) assert.ok(point.textContent.length < 150, 'social points stay short');
  assert.match(text, /off until you enable|off by default/i);
  assert.match(text, /Settings → Capture/);
  assert.match(text, /Accessibility permission/);
  assert.match(text, /source app is in front/);
  assert.match(text, /LinkedIn/);
  assert.match(text, /clipboard/i);
  assert.match(text, /cloud backup/);
  assert.match(text, /\bAI\b/);
  assert.match(text, /optional/i);
  assert.match(text, /Slack and Safari are tested/);
  assert.match(text, /Chrome is experimental/);
  assert.equal(card.querySelector('.feature-status').textContent, 'Off');

  card.querySelector('.feature-action').click();
  assert.equal(ui.byID('features-dialog').open, false);
  assert.deepEqual(ui.calls, [{ command: 'socialCaptureSettings' }]);
});

test('social capture status follows the optional launcher state and stays a demo in preview', t => {
  const ui = launcher(t);
  ui.byID('show-features').click();
  const status = () => ui.document.querySelector('.social-capture .feature-status');
  assert.equal(status().textContent, 'Off');
  ui.update({ socialCapture: { enabled: true, paused: false, hasAccess: true, permissionGranted: true, status: 'ready', enabledCount: 2 } });
  assert.equal(status().textContent, 'On');
  assert.match(ui.document.querySelector('.social-status-detail').textContent, /2 app connections/);
  ui.update({ socialCapture: { enabled: true, paused: true, hasAccess: true, permissionGranted: true, status: 'paused', enabledCount: 2 } });
  assert.equal(status().textContent, 'Paused');
  ui.update({ socialCapture: { enabled: true, paused: false, hasAccess: false, permissionGranted: false, status: 'needsAccess', enabledCount: 0 } });
  assert.equal(status().textContent, 'Needs access');
  ui.update({ socialCapture: { available: false, enabled: true, paused: false, hasAccess: true, permissionGranted: true, status: 'ready', enabledCount: 2 } });
  assert.equal(status().textContent, 'Unavailable');
  assert.match(ui.document.querySelector('.social-status-detail').textContent, /unavailable in this build/i);
  ui.update({ preview: true, socialCapture: { available: false, enabled: true, paused: false, hasAccess: true, permissionGranted: true, status: 'ready', enabledCount: 2 } });
  assert.equal(status().textContent, 'Off');
  assert.match(ui.document.querySelector('.social-status-detail').textContent, /Preview demo/);
});

test('catalog shortcuts follow live bindings by capture id and hide unassigned or missing keys', t => {
  const shortcuts = [
    { id: 'quick', title: 'Save link', key: '⇧⌘J', assigned: true, error: '' },
    { id: 'note', title: 'Save with a note', key: '⌥⌘N', assigned: true, error: '' },
    { id: 'selected', title: 'Save selected tabs', key: '', assigned: false, error: '' },
    { id: 'duplicates', title: 'Close duplicate tabs', key: '⇧⌘L', assigned: true, error: '' }
  ];
  const ui = launcher(t, { shortcuts });
  ui.byID('show-features').click();
  const key = id => ui.document.querySelector(`.feature-card[data-feature-id="${id}"] .feature-key`)?.textContent || '';
  assert.equal(key('save-current'), '⇧⌘J');
  assert.equal(key('save-note'), '⌥⌘N');
  assert.equal(key('save-selected'), '', 'unassigned bindings stay hidden');
  assert.equal(key('save-window'), '', 'missing bindings stay hidden');
  assert.equal(key('duplicates'), '⇧⌘L');
  assert.equal(key('read-current'), '', 'missing reader binding stays hidden');

  ui.update({ shortcuts: shortcuts.map(binding => binding.id === 'note' ? { ...binding, key: '⌥⌘M' } : binding) });
  assert.equal(key('save-note'), '⌥⌘M', 'the note card follows the configured key instead of a hardcoded one');
  assert.equal(key('save-current'), '⇧⌘J');
});

test('catalog actions use existing commands and search scopes', t => {
  const ui = launcher(t);
  const run = id => { ui.byID('show-features').click(); ui.featureAction(id).click(); };
  run('save-current');
  assert.deepEqual(ui.calls.splice(0), [{ command: 'capture', action: 'quick' }]);
  run('manage-tags');
  assert.deepEqual(ui.calls.splice(0), [{ command: 'tags' }]);
  run('export');
  assert.deepEqual(ui.calls.splice(0), [{ command: 'export' }]);
  run('cloud-saving');
  assert.deepEqual(ui.calls.splice(0), [{ command: 'account' }]);
  ui.byID('show-features').click();
  assert.equal(ui.featureAction('duplicates').textContent, 'Close duplicate tabs');
  ui.featureAction('duplicates').click();
  assert.deepEqual(ui.calls.splice(0), [{ command: 'capture', action: 'duplicates' }]);
  run('search-open');
  assert.deepEqual(ui.calls.splice(0), [{ command: 'search', query: '', scope: 'Open' }]);
  assert.equal(ui.byID('scope').value, 'Open');
});

test('live state refreshes preserve the focused catalog action, search focus and scroll position', t => {
  const ui = launcher(t);
  ui.byID('show-features').click();
  const list = ui.byID('features-list');
  const action = ui.featureAction('duplicates');
  action.focus();
  list.scrollTop = 180;
  assert.equal(ui.document.activeElement, action);

  ui.update({ socialCapture: { enabled: true, paused: false, hasAccess: true, permissionGranted: true, status: 'ready', enabledCount: 1 } });
  const refreshed = ui.featureAction('duplicates');
  assert.notEqual(refreshed, action, 'the catalog is rebuilt from fresh state');
  assert.equal(ui.document.activeElement, refreshed, 'focus follows the same action after the rebuild');
  assert.equal(list.scrollTop, 180, 'scroll position survives the rebuild');
  assert.equal(ui.document.querySelector('.social-capture .feature-status').textContent, 'On');

  const search = ui.byID('features-search');
  search.focus();
  ui.update({ socialCapture: { enabled: true, paused: true, hasAccess: true, permissionGranted: true, status: 'paused', enabledCount: 1 } });
  assert.equal(ui.document.activeElement, search, 'search focus survives a status refresh');
  assert.equal(list.scrollTop, 180);
});

test('live catalog refreshes keep the search element, caret and selection stable', t => {
  const ui = launcher(t);
  ui.byID('show-features').click();
  const search = ui.byID('features-search');
  search.value = 'social capture';
  search.focus();
  search.setSelectionRange(3, 5, 'backward');
  ui.update({ socialCapture: { enabled: true, paused: false, hasAccess: true, permissionGranted: true, status: 'ready', enabledCount: 1 } });
  assert.equal(ui.byID('features-search'), search, 'the search input is never replaced');
  assert.equal(ui.document.activeElement, search, 'focus is not stolen during a state update');
  assert.equal(search.value, 'social capture');
  assert.equal(search.selectionStart, 3);
  assert.equal(search.selectionEnd, 5);
  assert.equal(search.selectionDirection, 'backward');
  assert.equal(ui.document.querySelector('.social-capture .feature-status').textContent, 'On');
});

test('feature search filters the catalog without firing root shortcuts', t => {
  const ui = launcher(t);
  ui.byID('show-features').click();
  const search = ui.byID('features-search');
  search.value = 'pro';
  search.dispatchEvent(new ui.window.Event('input', { bubbles: true }));
  assert.match(ui.byID('features-list').textContent, /Pro on this Mac/);
  assert.doesNotMatch(ui.byID('features-list').textContent, /Capture from your browser/);
  assert.match(ui.byID('features-count').textContent, /feature/);

  ui.key('k', search, { metaKey: true });
  ui.key('1', search, { metaKey: true });
  ui.key('Enter', search);
  assert.equal(ui.byID('action-dialog').open, false);
  assert.equal(ui.byID('features-dialog').open, true);
  assert.deepEqual(ui.calls, []);
});

test('closing the catalog preserves the launcher query, selection, scope and focus', t => {
  const ui = launcher(t, { rows: [page], query: 'saved page' });
  const selected = ui.document.querySelector('.row-check');
  assert.ok(selected);
  selected.click();
  assert.equal(selected.checked, true);
  const trigger = ui.byID('show-features');
  trigger.focus(); trigger.click();
  assert.equal(ui.byID('features-dialog').open, true);
  assert.equal(ui.key('Escape', ui.byID('features-search')).defaultPrevented, true);
  assert.equal(ui.byID('features-dialog').open, false);
  assert.equal(ui.byID('search').value, 'saved page');
  assert.equal(ui.byID('scope').value, 'All');
  assert.equal(ui.document.querySelector('.row-check').checked, true);
  assert.equal(ui.document.activeElement, trigger);
  assert.equal(ui.calls.some(call => call.command === 'dismiss'), false);
});

test('Escape closes the catalog before leaving an open draft', t => {
  const ui = launcher(t);
  ui.event({ event: 'add' });
  assert.equal(ui.document.body.dataset.view, 'editor');
  ui.calls.length = 0;
  const note = ui.byID('edit-note');
  note.value = 'Draft still here';
  ui.byID('show-features').click();
  assert.equal(ui.byID('features-dialog').open, true);
  ui.key('Escape', ui.byID('features-search'));
  assert.equal(ui.byID('features-dialog').open, false);
  assert.equal(ui.document.body.dataset.view, 'editor');
  assert.equal(note.value, 'Draft still here');
  assert.deepEqual(ui.calls, []);
});

test('arrow keys move from catalog search to visible actions', t => {
  const ui = launcher(t);
  ui.byID('show-features').click();
  const search = ui.byID('features-search');
  ui.key('ArrowDown', search);
  assert.equal(ui.document.activeElement, ui.document.querySelector('.social-capture .feature-action'));
  ui.key('ArrowDown', ui.document.activeElement);
  assert.equal(ui.document.activeElement, ui.document.querySelector('.feature-card[data-feature-id="save-current"] .feature-action'));
  ui.key('ArrowUp', ui.document.activeElement);
  assert.equal(ui.document.activeElement, ui.document.querySelector('.social-capture .feature-action'));
});

test('catalog exposes shipped add link, local tags, close-after-save, appearance and keyboard guide capabilities', t => {
  const items = catalog.groups.flatMap(group => group.items);
  const item = id => items.find(entry => entry.id === id);
  const add = item('add-link'), launcherAdd = model.catalog.find(entry => entry.id === 'add-link');
  assert.ok(add && launcherAdd);
  assert.equal(add.action.ui, launcherAdd.ui, 'Add a link follows the shipped launcher flow');
  assert.equal(add.action.ui, 'add');
  assert.equal(add.action.command, 'add', 'saving the add editor submits the shipped add command');
  assert.match(add.description, /URL/i);

  for (const id of ['auto-tags', 'close-after-save', 'appearance']) {
    assert.equal(item(id).action.command, 'settings', `${id} must open Settings`);
  }
  assert.match(item('auto-tags').description, /local|on this Mac/i);
  assert.match(item('close-after-save').description, /bulk saves never close/i);
  assert.match(item('appearance').description, /Midnight and Pearl/i);
  assert.equal(item('keyboard-guide').action.ui, 'shortcuts');

  const ui = launcher(t);
  ui.byID('show-features').click();
  ui.featureAction('add-link').click();
  assert.equal(ui.byID('features-dialog').open, false);
  assert.equal(ui.document.body.dataset.view, 'editor');
  assert.equal(ui.byID('edit-url').readOnly, false);

  ui.byID('show-features').click();
  ui.featureAction('keyboard-guide').click();
  assert.equal(ui.byID('shortcuts-dialog').open, true);
});

test('catalog descriptions only expose shipped capabilities', () => {
  const text = JSON.stringify(catalog);
  assert.doesNotMatch(text, /macOS Services|Activity feed|Activity tab/i);
  const groups = catalog.groups.map(group => group.id);
  assert.deepEqual(groups, ['capture', 'find', 'read', 'organize', 'library', 'pro']);
  for (const title of ['Invite a friend', 'AI connections', 'Automatic saving and recovery']) {
    assert.ok(catalog.groups.find(group => group.id === 'pro').items.some(item => item.title === title));
  }
});
