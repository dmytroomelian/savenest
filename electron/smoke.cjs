'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

exports.run = async ({ win, native, root, show, toggle }) => {
  const privacyPreferences = () => ['analyticsEnabled', 'hasSeenUsageNotice', 'historySearchEnabled', 'closeAfterQuickSave'].map(key => {
    try { return execFileSync('/usr/bin/defaults', ['read', 'app.savenest.mac', key], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); }
    catch (error) { if (error.status === 1) return null; throw error; }
  });
  const originalPreferences = privacyPreferences();
  let state;
  const errors = [];
  native.on('event', message => { if (message.event === 'state') state = message.state; });
  win.webContents.on('console-message', event => { if (event.level === 'error') errors.push(event.message); });
  const js = source => win.webContents.executeJavaScript(source, true);
  const wait = async (predicate, label) => {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) { if (await predicate()) return; await new Promise(resolve => setTimeout(resolve, 70)); }
    throw new Error('Timed out: ' + label);
  };
  const key = (key, modifiers = {}) => js(`document.dispatchEvent(new KeyboardEvent('keydown', ${JSON.stringify({ key, bubbles: true, cancelable: true, ...modifiers })}))`);
  const type = async value => {
    await js(`document.getElementById('search').value=${JSON.stringify(value)}; document.getElementById('search').dispatchEvent(new Event('input'))`);
    await wait(() => state?.query === value && state.resultsQuery === value, 'search ' + value);
    await new Promise(resolve => setTimeout(resolve, 100));
  };
  const scope = async value => {
    await js(`document.getElementById('scope').value=${JSON.stringify(value)}; document.getElementById('scope').dispatchEvent(new Event('change'))`);
    await wait(() => state.scope === value && state.resultsScope === value && state.query === '', value + ' scope');
  };
  const route = value => wait(() => js(`document.body.dataset.view === ${JSON.stringify(value)}`), value + ' view');
  const painted = async () => {
    await js('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
    await new Promise(resolve => setTimeout(resolve, 120));
  };
  await native.request({ command: 'snapshot' });
  await wait(() => state?.preview && state.rows.length >= 10, 'native preview fixture');
  await wait(() => js("document.querySelectorAll('.row').length >= 10"), 'launcher results');
  assert.equal(win.isAlwaysOnTop(), true);
  assert.equal(win.getBounds().width, 760);
  assert.equal(await js("document.querySelectorAll('.sidebar').length"), 0);
  assert.equal(state.launcherShortcut, '⌘O');
  assert.equal(state.shortcuts.length, 7, 'native state exposes all configurable shortcuts');
  assert.equal(state.shortcuts.find(binding => binding.id === 'search').key, state.launcherShortcut);
  assert.equal(await js('typeof require'), 'undefined'); assert.equal(await js('typeof process'), 'undefined');
  assert.equal(win.webContents.getLastWebPreferences().sandbox, true);
  assert.equal(win.webContents.getLastWebPreferences().contextIsolation, true);
  await assert.rejects(js("window.savenest.command({command:'callback',url:'savenest://auth'})"), /Unknown Savenest action/);

  // The native fixture has no account or subscription. It follows the same local
  // write checks as the normal app; preview only replaces persistence/browser IO.
  assert.equal(state.canSave, true);
  assert.equal(state.canRestartForUpdate, true);
  assert.equal(state.analyticsEnabled, true);
  await wait(() => js("!document.getElementById('usage-notice').hidden"), 'visible privacy disclosure');
  await painted();
  await fs.mkdir(path.join(root, 'build'), { recursive: true });
  await fs.writeFile(path.join(root, 'build/launcher-privacy.png'), (await win.webContents.capturePage()).toPNG());
  await js("document.getElementById('usage-off').focus()");
  assert.equal(await js("(() => { const event = new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true }); document.getElementById('usage-off').dispatchEvent(event); return event.defaultPrevented; })()"), false, 'focused privacy button keeps native Enter activation');
  // Synthetic DOM events do not trigger browser default actions; exercise the click separately.
  await js("document.getElementById('usage-off').click(); document.getElementById('search').focus()");
  await wait(() => !state.analyticsEnabled && !state.showUsageNotice, 'analytics opt-out');
  await wait(() => js("document.getElementById('usage-notice').hidden"), 'notice dismissed after opt-out');
  await native.request({ command: 'analyticsEnabled', enabled: true });
  await wait(() => state.analyticsEnabled && !state.showUsageNotice, 'reporting preference without repeated notice');

  await type('history'); await key('Enter');
  await wait(() => state.scope === 'History' && state.resultsScope === 'History' && state.rows.length === 3, 'history command from root');
  await type('raycast');
  await wait(() => state.rows.length === 1 && state.rows[0].isHistory && !state.rows[0].isSaved, 'history-only page');
  await key('s', { metaKey: true });
  await wait(() => state.rows.length === 1 && state.rows[0].isSaved && state.rows[0].isHistory, 'save history result in place');
  await key('Escape');
  await wait(() => state.scope === 'All' && state.resultsScope === 'All', 'Escape returns from scope to root');
  await type('history sources'); await key('Enter'); await route('sources');
  await js("document.getElementById('history-enabled').click()");
  await wait(() => !state.historyEnabled && state.historyCount === 0, 'pause clears history');
  assert(state.rows.every(row => !row.isHistory));
  assert(state.savedCount >= 9);
  await js("document.getElementById('history-enabled').click()");
  await wait(() => state.historyEnabled && state.historyCount === 3, 'resume preview history');
  await key('Escape'); await route('root');

  await scope('Open'); await type('weekly research');
  await wait(() => state.rows.length === 1, 'page-context search');
  await scope('All'); await type('example.com/launcher-smoke'); await key('Enter'); await route('editor');
  assert.equal(await js("document.getElementById('edit-url').value"), 'https://example.com/launcher-smoke');
  await js("document.getElementById('edit-title').value='<img src=x onerror=alert(1)>'; document.getElementById('edit-note').value='Round trip note'; document.getElementById('edit-tags').value='Launcher, Test'");
  await key('Enter', { metaKey: true }); await route('root');
  await wait(() => !win.isVisible(), 'successful add dismisses launcher');
  await show(); await route('root');
  await wait(() => state.rows.some(row => row.url.endsWith('/launcher-smoke')), 'save URL through inline editor');
  let item = state.rows.find(row => row.url.endsWith('/launcher-smoke'));
  assert.deepEqual(item.tags, ['Launcher', 'Test']); assert.equal(item.note, 'Round trip note');
  assert.equal(await js("document.querySelectorAll('img[onerror]').length"), 0);
  assert.equal(await js("document.getElementById('results').textContent.includes('<img src=x onerror=alert(1)>')"), true);
  // Search for the saved title so the page, not the URL-save command, is selected.
  await type('onerror'); await key('k', { metaKey: true });
  await wait(() => js("document.getElementById('action-dialog').open"), 'contextual action panel');
  await key('Escape');
  assert.equal(await js("document.getElementById('action-dialog').open"), false);
  assert.equal(win.isVisible(), true);
  await key('e', { metaKey: true }); await route('editor');
  await js("document.getElementById('edit-title').value='Launcher round trip'; document.getElementById('edit-note').value='Edited note'");
  // A second local test app may own focus; toggle intentionally hides only a focused launcher.
  require('electron').app.focus({ steal: true }); win.focus();
  await wait(() => win.isFocused(), 'focus launcher before toggle');
  toggle(); await wait(() => !win.isVisible(), 'hide with unfinished draft');
  await show(); await route('editor');
  assert.equal(await js("document.getElementById('edit-note').value"), 'Edited note');
  await key('Escape'); await wait(() => js("document.getElementById('discard-dialog').open"), 'dirty draft guard');
  await js("document.getElementById('keep-editing').click()");
  await key('Enter', { metaKey: true }); await route('root');
  assert.equal(win.isVisible(), true, 'editing an existing link keeps launcher open');
  await type('launcher round trip'); await wait(() => state.rows.some(row => row.note === 'Edited note'), 'edited link searchable');
  item = state.rows.find(row => row.note === 'Edited note');
  await native.request({ command: 'favorite', ids: [item.id] }); await wait(() => state.rows[0]?.favorite, 'favorite');
  await native.request({ command: 'archive', ids: [item.id] });
  await scope('Archive'); await type('launcher round trip'); await wait(() => state.rows[0]?.archived, 'archive');
  await native.request({ command: 'delete', ids: [item.id] }); await wait(() => state.rows.length === 0, 'delete');
  await native.request({ command: 'undo' }); await wait(() => state.rows.length === 1, 'undo deletion');
  await native.request({ command: 'restore', ids: [item.id] });
  await scope('Saved'); await type('launcher round trip'); await wait(() => state.rows.length === 1 && !state.rows[0].archived, 'restore');
  await native.request({ command: 'delete', ids: [item.id] });

  await scope('All'); await type('save with a note'); await key('Enter'); await route('editor');
  assert(state.captureDraft);
  assert.equal(state.canRestartForUpdate, false, 'native capture drafts block update restarts');
  await js("document.getElementById('edit-note').value='Captured inside the launcher'");
  await key('Enter', { metaKey: true }); await route('root');
  await wait(() => !win.isVisible(), 'successful save-with-note dismisses launcher');
  await show(); await route('root');
  await type('Captured inside the launcher'); await wait(() => state.rows.some(row => row.note === 'Captured inside the launcher'), 'native capture saved in same panel');
  await type('save selected'); await key('Enter'); await route('selection');
  assert.equal(state.canRestartForUpdate, false, 'native tab selection blocks update restarts');
  await js("document.querySelectorAll('#capture-tabs input')[2].click()");
  await key('Enter', { metaKey: true }); await route('root');
  await wait(() => state.captureSelection === null, 'selected capture committed');
  await native.request({ command: 'snapshot' });
  await wait(() => state.canRestartForUpdate === true, 'completed capture allows update restart');

  await scope('Open'); await wait(() => state.rows.length === 3, 'preview tabs');
  const tab = state.rows.find(row => !row.isSaved);
  assert(tab); await native.request({ command: 'saveClose', ids: [tab.id] });
  await wait(() => state.rows.length === 2 && !state.busy, 'save and close preview tab');
  await scope('Saved'); await wait(() => state.rows.some(row => row.url === tab.url && row.isSaved), 'closed tab retained');
  await scope('All');
  await wait(() => js("document.querySelectorAll('#results .row').length >= 10"), 'root suggestions rendered');
  await js("document.getElementById('dismiss-notice').click(); document.getElementById('search').focus()");
  await painted();
  assert.equal(await js("document.querySelectorAll('#results .row').length >= 10"), true);
  await fs.mkdir(path.join(root, 'build'), { recursive: true });
  await fs.writeFile(path.join(root, 'build/launcher-preview.png'), (await win.webContents.capturePage()).toPNG());
  const initialAppearance = state.appearance;
  // Exercise appearance delivery without writing the user's saved preference.
  for (const appearance of ['black', 'cream']) {
    native.emit('event', { event: 'state', state: { ...state, appearance } });
    await wait(() => js(`document.documentElement.dataset.appearance === '${appearance}'`), appearance + ' appearance');
    await painted();
    await fs.writeFile(path.join(root, `build/launcher-${appearance}.png`), (await win.webContents.capturePage()).toPNG());
  }
  native.emit('event', { event: 'state', state: { ...state, appearance: initialAppearance } });
  assert.equal(await js("getComputedStyle(document.getElementById('search')).outlineStyle"), 'none', 'launcher search stays borderless when focused');
  assert.equal(await js("document.getElementById('open-settings').getBoundingClientRect().width > 0 && document.getElementById('show-shortcuts').getBoundingClientRect().width > 0"), true, 'settings and shortcut help remain visible');

  // App commands remain discoverable even when a scoped search has no pages.
  await scope('Saved'); await type('unmatched-discovery-fixture');
  await wait(() => js("document.querySelectorAll('#results .row').length === 0"), 'empty scoped search');
  await key('k', { metaKey: true });
  assert.equal(await js("document.getElementById('action-dialog').open"), true);
  assert.equal(await js("Boolean(document.querySelector('[data-action-id=\"command:settings\"]'))"), true);
  await js("document.getElementById('action-search').value='saved'; document.getElementById('action-search').dispatchEvent(new Event('input'))");
  await key('Enter');
  await wait(() => state.scope === 'Saved' && state.query === '' && state.rows.length > 0, 'global saved search action');
  await scope('All');
  native.emit('event', { event: 'state', state: { ...state, appearance: 'black' } });
  await key('k', { metaKey: true });
  await painted();
  await fs.writeFile(path.join(root, 'build/launcher-global-actions.png'), (await win.webContents.capturePage()).toPNG());
  await key('Escape');

  await js("document.getElementById('show-shortcuts').click()");
  assert.equal(await js("document.getElementById('shortcuts-dialog').open"), true);
  assert.equal(await js("document.getElementById('shortcut-list').textContent.includes('Global shortcuts are inactive in this preview.')"), true);
  const selectedBeforeHelp = await js("document.querySelector('#results .row.selected')?.dataset.id");
  await key('ArrowDown');
  assert.equal(await js("document.querySelector('#results .row.selected')?.dataset.id"), selectedBeforeHelp, 'help shields the result selection');
  await painted();
  await fs.writeFile(path.join(root, 'build/launcher-shortcuts.png'), (await win.webContents.capturePage()).toPNG());
  await key('Escape');
  assert.equal(await js("document.getElementById('shortcuts-dialog').open"), false);
  assert.equal(win.isVisible(), true, 'closing help keeps launcher visible');
  await key('/', { metaKey: true });
  assert.equal(await js("document.getElementById('shortcuts-dialog').open"), true, 'keyboard shortcut opens help');
  await key('Escape');
  native.emit('event', { event: 'state', state: { ...state, appearance: initialAppearance } });

  await type('raycast'); await key('k', { metaKey: true });
  await wait(() => js("document.getElementById('action-dialog').open"), 'actions screenshot');
  await painted();
  await fs.writeFile(path.join(root, 'build/launcher-actions.png'), (await win.webContents.capturePage()).toPNG());
  await key('Escape'); await type('');
  await key('Escape'); await wait(() => !win.isVisible(), 'Escape dismisses root launcher');
  await show(); await wait(() => win.isVisible() && win.isFocused(), 'reopen and focus launcher');
  // A second local test app may own focus; toggle intentionally hides only a focused launcher.
  require('electron').app.focus({ steal: true }); win.focus();
  await wait(() => win.isFocused(), 'focus launcher before toggle');
  toggle(); await wait(() => !win.isVisible(), 'hotkey toggle hides launcher');
  await show();
  assert.deepEqual(errors, []);
  await require('./updater-smoke.cjs').run({ native, win });
  native.stop();
  await wait(() => native.child.exitCode !== null || native.child.signalCode !== null, 'helper shuts down after parent pipe closes');
  assert.deepEqual(privacyPreferences(), originalPreferences, 'preview must not change live privacy/history preferences');
};
