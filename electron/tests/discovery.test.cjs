'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { JSDOM, VirtualConsole } = require('jsdom');

const rendererDirectory = path.resolve(__dirname, '../renderer');
const html = readFileSync(path.join(rendererDirectory, 'index.html'), 'utf8');
const scripts = ['launcher-model.js', 'activity.js', 'features.js', 'renderer.js'].map(name => readFileSync(path.join(rendererDirectory, name), 'utf8'));
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
  window.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
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
  return { window, document, calls, update, byID, key, action, event: message => onEvent(message) };
}

for (const scope of ['All', 'Saved']) {
  test(`Actions remains available with no results in ${scope}`, t => {
    const ui = launcher(t, { scope, query: 'no matching page' });
    assert.equal(ui.document.querySelectorAll('.row').length, 0);
    assert.equal(ui.byID('primary').disabled, true);
    assert.equal(ui.byID('actions').disabled, false);
    ui.byID('search').focus();
    ui.key('k', ui.byID('search'), { metaKey: true });
    assert.equal(ui.byID('action-dialog').open, true);
    ui.action('Search saved links');
    ui.action('Settings');
    ui.action('Keyboard shortcuts');
    assert.deepEqual(ui.calls, []);
  });
}

test('a searched global action changes the saved-link scope without needing a selected result', t => {
  const ui = launcher(t, { query: 'no matching page' });
  ui.byID('actions').click();
  const search = ui.byID('action-search');
  search.value = 'search saved links';
  search.dispatchEvent(new ui.window.Event('input', { bubbles: true }));
  ui.key('Enter', search);
  assert.deepEqual(ui.calls, [{ command: 'search', query: '', scope: 'Saved' }]);
  assert.equal(ui.byID('scope').value, 'Saved');
  assert.equal(ui.byID('action-dialog').open, false);
});

test('Settings dispatches from both the global Actions list and the persistent footer control', t => {
  const ui = launcher(t, { scope: 'Saved' });
  ui.byID('actions').click();
  ui.action('Settings').click();
  assert.equal(ui.byID('action-dialog').open, false);
  assert.deepEqual(ui.calls.splice(0), [{ command: 'settings' }]);
  ui.byID('open-settings').click();
  assert.deepEqual(ui.calls, [{ command: 'settings' }]);
});

test('global keyboard help shows configured bindings, unassigned actions and registration errors', t => {
  const ui = launcher(t, { scope: 'Saved', shortcuts: [
    { id: 'search', title: 'Open Savenest', key: '⌃⌥P', error: '' },
    { id: 'reader', title: 'Read & note current tab', key: '', error: '' },
    { id: 'quick', title: 'Save link', key: '⇧⌘J', error: 'Already in use. Choose another shortcut.' }
  ] });
  ui.byID('actions').click();
  ui.action('Keyboard shortcuts').click();
  assert.equal(ui.byID('action-dialog').open, false);
  assert.equal(ui.byID('shortcuts-dialog').open, true);
  const shortcutRow = title => [...ui.document.querySelectorAll('.shortcut-row')].find(node => node.firstElementChild?.firstChild?.textContent === title);
  assert.equal(shortcutRow('Open Savenest').querySelector('kbd').textContent, '⌃⌥P');
  assert.equal(shortcutRow('Read & note current tab').querySelector('kbd'), null);
  assert.equal(shortcutRow('Read & note current tab').querySelector('.shortcut-unassigned').textContent, 'Not assigned');
  assert.equal(shortcutRow('Save link').querySelector('.error').textContent, 'Already in use. Choose another shortcut.');
  ui.update({ shortcuts: [{ id: 'search', title: 'Open Savenest', key: '⌃⌥L', error: '' }] });
  assert.equal(shortcutRow('Open Savenest').querySelector('kbd').textContent, '⌃⌥L');
  assert.deepEqual(ui.calls, []);
  ui.byID('shortcut-settings').click();
  assert.equal(ui.byID('shortcuts-dialog').open, false);
  assert.deepEqual(ui.calls, [{ command: 'settings' }]);
});

test('shortcut help shields the result list from Enter and arrow keys; Escape closes only help', t => {
  const ui = launcher(t, { scope: 'Saved', rows: [page, { ...page, id: 'saved:two', title: 'Another saved page' }] });
  const selectedBefore = ui.byID('search').getAttribute('aria-activedescendant');
  const trigger = ui.byID('show-shortcuts');
  trigger.focus();
  trigger.click();
  const list = ui.byID('shortcut-list');
  list.tabIndex = -1;
  list.focus();
  ui.key('ArrowDown', list);
  ui.key('ArrowUp', list);
  ui.key('Enter', list);
  assert.equal(ui.byID('shortcuts-dialog').open, true);
  assert.equal(ui.byID('search').getAttribute('aria-activedescendant'), selectedBefore);
  assert.deepEqual(ui.calls, []);
  assert.equal(ui.key('Escape', list).defaultPrevented, true);
  assert.equal(ui.byID('shortcuts-dialog').open, false);
  assert.equal(ui.byID('scope').value, 'Saved');
  assert.equal(ui.document.activeElement, trigger);
  assert.deepEqual(ui.calls, []);
});

test('Enter on a focused Actions button preserves native activation instead of running the highlighted result', t => {
  const ui = launcher(t, { scope: 'Saved', rows: [page] });
  ui.byID('actions').click();
  assert.equal(ui.document.querySelector('#action-options button.active .action-title').textContent, 'Open link');
  const settings = ui.action('Settings');
  settings.focus();
  assert.equal(ui.key('Enter', settings).defaultPrevented, false);
  assert.equal(ui.byID('action-dialog').open, true);
  assert.deepEqual(ui.calls, [], 'keydown must not execute the highlighted Open link action');
  // JSDOM does not synthesize a button click from a trusted Enter key, so perform
  // the browser default activation after checking that the handler permits it.
  settings.click();
  assert.deepEqual(ui.calls, [{ command: 'settings' }]);
  assert.equal(ui.byID('action-dialog').open, false);
});


test('feature requests remain discoverable without search results', t => {
  const ui = launcher(t, { query: 'no matching page' });
  ui.byID('actions').click();
  ui.action('Request a feature').click();
  assert.deepEqual(ui.calls, [{ command: 'requestFeature' }]);
});

test('the footer Help menu opens, handles arrows, and restores focus on Escape', t => {
  const ui = launcher(t);
  const trigger = ui.byID('open-help');
  const items = [...ui.byID('help-menu').querySelectorAll('[role="menuitem"]')];
  assert.equal(items.length, 4);
  assert.equal(ui.byID('open-feature-request'), null, 'the standalone footer feedback button is removed');
  assert.equal(ui.byID('show-features'), null, 'Explore moves into Help');
  trigger.focus(); trigger.click();
  assert.equal(ui.byID('help-menu').hidden, false);
  assert.equal(trigger.getAttribute('aria-expanded'), 'true');
  assert.equal(ui.document.activeElement, items[0]);
  ui.key('ArrowDown', items[0]);
  assert.equal(ui.document.activeElement, items[1]);
  ui.key('ArrowUp', items[1]);
  const escape = ui.key('Escape', items[0]);
  assert.equal(escape.defaultPrevented, true);
  assert.equal(ui.byID('help-menu').hidden, true);
  assert.equal(trigger.getAttribute('aria-expanded'), 'false');
  assert.equal(ui.document.activeElement, trigger);
  assert.deepEqual(ui.calls, []);
});

test('Help routes Explore, feedback, bug reports, and keyboard shortcuts', t => {
  const ui = launcher(t);
  const open = action => {
    ui.byID('open-help').click();
    ui.byID('help-menu').querySelector(`[data-help-action="${action}"]`).click();
  };
  open('request-feature');
  assert.deepEqual(ui.calls.splice(0), [{ command: 'requestFeature' }]);
  open('report-bug');
  assert.deepEqual(ui.calls.splice(0), [{ command: 'reportBug' }]);
  open('shortcuts');
  assert.equal(ui.byID('shortcuts-dialog').open, true);
  ui.key('Escape', ui.byID('shortcuts-close'));
  open('features');
  assert.equal(ui.byID('features-dialog').open, true);
  assert.equal(ui.document.activeElement, ui.byID('features-search'));
  assert.deepEqual(ui.calls, []);
  const template = readFileSync(path.resolve(__dirname, '../../.github/ISSUE_TEMPLATE/feature.yml'), 'utf8');
  assert.match(template, /^name: Feature request/m);
});

test('Explore stays searchable but is not a default quick action', t => {
  const ui = launcher(t);
  const titles = () => [...ui.document.querySelectorAll('.row-title')].map(node => node.textContent);
  assert.ok(!titles().includes('Explore features'), 'Explore must not be a default quick action');
  ui.byID('search').focus();
  ui.byID('search').value = 'explore';
  ui.byID('search').dispatchEvent(new ui.window.Event('input', { bubbles: true }));
  assert.ok(titles().includes('Explore features'));
  ui.key('Enter', ui.byID('search'));
  assert.equal(ui.byID('features-dialog').open, true);
  ui.key('Escape', ui.byID('features-search'));
  assert.equal(ui.byID('features-dialog').open, false);
});

const secondPage = { ...page, id: 'saved:two', title: 'Another page', url: 'https://example.com/two' };
const thirdPage = { ...page, id: 'saved:three', title: 'Third page', url: 'https://example.com/three' };
const checkedIDs = ui => [...ui.document.querySelectorAll('.row-check:checked')].map(check => check.closest('.row').dataset.id);

test('keyboard selection supports disjoint links, ranges that shrink, and Escape before leaving scope', t => {
  const ui = launcher(t, { scope: 'Saved', rows: [page, secondPage, thirdPage] });
  const search = ui.byID('search'); search.focus();
  assert.equal(ui.byID('selection-bar').hidden, false);
  ui.key(' ', search, { shiftKey: true });
  ui.key('ArrowDown'); ui.key('ArrowDown'); ui.key(' ', search, { shiftKey: true });
  assert.deepEqual(checkedIDs(ui), [page.id, thirdPage.id]);
  assert.equal(ui.byID('selection-count').textContent, '2 selected');
  ui.key('Escape');
  assert.deepEqual(checkedIDs(ui), []);
  assert.equal(ui.byID('scope').value, 'Saved');
  assert.deepEqual(ui.calls, []);
  ui.key('ArrowUp', search, { shiftKey: true });
  assert.deepEqual(checkedIDs(ui), [secondPage.id, thirdPage.id]);
  ui.key('ArrowUp', search, { shiftKey: true });
  assert.deepEqual(checkedIDs(ui), [page.id, secondPage.id, thirdPage.id]);
  ui.key('ArrowDown', search, { shiftKey: true });
  assert.deepEqual(checkedIDs(ui), [secondPage.id, thirdPage.id]);
});

test('selection controls and bulk favorites use checked links', t => {
  const ui = launcher(t, { scope: 'Saved', rows: [page, secondPage, thirdPage] });
  ui.byID('toggle-selection').click();
  assert.deepEqual(checkedIDs(ui), [page.id]);
  const rows = [...ui.document.querySelectorAll('.row')];
  rows[2].dispatchEvent(new ui.window.MouseEvent('click', { bubbles: true, metaKey: true }));
  assert.deepEqual(checkedIDs(ui), [page.id, thirdPage.id]);
  ui.byID('clear-selection').click(); rows[0].click();
  rows[2].dispatchEvent(new ui.window.MouseEvent('click', { bubbles: true, shiftKey: true }));
  assert.deepEqual(checkedIDs(ui), [page.id, secondPage.id, thirdPage.id]);
  rows[1].querySelector('.row-check').click();
  assert.deepEqual(checkedIDs(ui), [page.id, thirdPage.id]);
  rows[2].querySelector('.row-more').click();
  assert.equal(ui.byID('actions-context').textContent, '2 selected pages');
  ui.action('Copy URLs').click();
  assert.deepEqual(ui.calls, [{ command: 'copy', ids: [page.id, thirdPage.id] }]);
});

test('select all skips commands, preserves text shortcuts, and clears on a new query', t => {
  const ui = launcher(t, { rows: [page, secondPage] });
  const search = ui.byID('search'); search.focus();
  for (const modifiers of [{ metaKey: true }, { metaKey: true, shiftKey: true }]) {
    assert.equal(ui.key('z', search, modifiers).defaultPrevented, false);
  }
  assert.equal(ui.key('a', search, { metaKey: true }).defaultPrevented, false);
  ui.key('A', search, { metaKey: true, shiftKey: true });
  assert.deepEqual(checkedIDs(ui), [page.id, secondPage.id]);
  ui.key('F', search, { metaKey: true, shiftKey: true });
  assert.deepEqual(ui.calls, [{ command: 'favorite', ids: [page.id, secondPage.id] }]);
  search.value = 'another'; search.dispatchEvent(new ui.window.Event('input', { bubbles: true }));
  assert.deepEqual(checkedIDs(ui), []);
});

test('Actions updates favorite state and keyboard targets when native results change', t => {
  const ui = launcher(t, { scope: 'Saved', rows: [page, secondPage, thirdPage] });
  ui.byID('search').focus(); ui.key('ArrowDown'); ui.byID('actions').click();
  ui.update({ rows: [page, { ...secondPage, favorite: true }, thirdPage] });
  ui.action('Remove from favorites');
  ui.update({ rows: [page, thirdPage] });
  assert.equal(ui.byID('actions-context').textContent, thirdPage.title, 'triage continues at the next row');
  ui.key('f', ui.byID('action-search'), { metaKey: true, shiftKey: true });
  assert.deepEqual(ui.calls, [{ command: 'favorite', ids: [thirdPage.id] }]);
});

test('sync status is absent without Pro and changes immediately when sync loses access', t => {
  const ui = launcher(t, { savedCount: 4 });
  const status = ui.byID('sync-status');
  assert.equal(status.hidden, true);
  assert.equal(ui.byID('status').hidden, false);
  ui.update({ syncStatus: { state: 'active', label: 'Sync is active' } });
  assert.equal(status.hidden, false);
  assert.equal(status.dataset.state, 'active');
  assert.equal(ui.byID('sync-label').textContent, 'Sync is active');
  assert.equal(ui.byID('status').hidden, true);
  for (const [state, label] of [['offline', 'Offline'], ['attention', 'Needs attention'], ['checking', 'Checking…'], ['restoring', 'Restoring…']]) {
    ui.update({ syncStatus: { state, label } });
    assert.equal(status.hidden, false);
    assert.equal(status.dataset.state, state);
    assert.equal(ui.byID('sync-label').textContent, label);
  }
  ui.update({ syncStatus: { state: 'hidden', label: '' } });
  assert.equal(status.hidden, true);
  assert.equal(status.dataset.state, undefined);
  assert.equal(ui.byID('sync-label').textContent, '');
  assert.equal(ui.byID('status').hidden, false);
  assert.match(ui.byID('status').textContent, /4 saved/);
});

test('a native connection failure cannot leave a green active sync status behind', t => {
  const ui = launcher(t, { syncStatus: { state: 'active', label: 'Sync is active' } });
  assert.equal(ui.byID('sync-status').hidden, false);
  ui.event({ event: 'fatal', message: 'The native helper stopped.' });
  assert.equal(ui.byID('sync-status').hidden, true);
  assert.equal(ui.byID('sync-status').dataset.state, undefined);
  assert.equal(ui.byID('status').hidden, false);
  assert.equal(ui.byID('status').textContent, 'Connection unavailable');
  ui.update({ syncStatus: { state: 'active', label: 'Sync is active' } });
  assert.equal(ui.byID('sync-status').hidden, true);
});

test('sync status does not hide a launcher shortcut error', t => {
  const ui = launcher(t, { syncStatus: { state: 'active', label: 'Sync is active' }, shortcutError: 'Shortcut unavailable' });
  assert.equal(ui.byID('sync-status').hidden, true);
  assert.equal(ui.byID('status').hidden, false);
  assert.equal(ui.byID('status').textContent, 'Shortcut unavailable · open Settings');
});
