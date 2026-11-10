'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { JSDOM, VirtualConsole } = require('jsdom');

const rendererDirectory = path.resolve(__dirname, '../renderer');
const html = readFileSync(path.join(rendererDirectory, 'index.html'), 'utf8');
const scripts = ['launcher-model.js', 'renderer.js'].map(name => readFileSync(path.join(rendererDirectory, name), 'utf8'));
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
  return { window, document, calls, update, byID, key, action };
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
    { id: 'search', title: 'Open SaveNest', key: '⌃⌥P', error: '' },
    { id: 'reader', title: 'Read & note current tab', key: '', error: '' },
    { id: 'quick', title: 'Save link', key: '⇧⌘J', error: 'Already in use. Choose another shortcut.' }
  ] });
  ui.byID('actions').click();
  ui.action('Keyboard shortcuts').click();
  assert.equal(ui.byID('action-dialog').open, false);
  assert.equal(ui.byID('shortcuts-dialog').open, true);
  const shortcutRow = title => [...ui.document.querySelectorAll('.shortcut-row')].find(node => node.firstElementChild?.firstChild?.textContent === title);
  assert.equal(shortcutRow('Open SaveNest').querySelector('kbd').textContent, '⌃⌥P');
  assert.equal(shortcutRow('Read & note current tab').querySelector('kbd'), null);
  assert.equal(shortcutRow('Read & note current tab').querySelector('.shortcut-unassigned').textContent, 'Not assigned');
  assert.equal(shortcutRow('Save link').querySelector('.error').textContent, 'Already in use. Choose another shortcut.');
  ui.update({ shortcuts: [{ id: 'search', title: 'Open SaveNest', key: '⌃⌥L', error: '' }] });
  assert.equal(shortcutRow('Open SaveNest').querySelector('kbd').textContent, '⌃⌥L');
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
