'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');

exports.run = async ({ workspace, native, root }) => {
  const errors = [];
  const wait = async (predicate, label) => {
    const until = Date.now() + 15000;
    while (Date.now() < until) { if (await predicate()) return; await new Promise(resolve => setTimeout(resolve, 60)); }
    throw new Error('Timed out: ' + label);
  };
  await workspace.open({ command: 'readerCurrent' });
  let win = workspace.window;
  const js = source => workspace.window.webContents.executeJavaScript(source, true);
  const state = () => js('window.workspaceTest.getState()');
  win.webContents.on('console-message', event => { if (event.level === 'error' && !event.message.includes('Content Security Policy')) errors.push(event.message); });
  await wait(() => js('Boolean(window.workspaceTest)'), 'workspace ready');
  assert.equal((await state()).notes.configured, false);
  assert.equal((await state()).original, true, 'Original opens by default');
  assert(workspace.original, 'original page loads without another click');
  assert.equal(await js('typeof require'), 'undefined');
  assert.equal(await js('typeof process'), 'undefined');
  assert.equal(win.isAlwaysOnTop(), false);
  assert.equal(win.isResizable(), true);
  await assert.rejects(js("window.workspace.request({command:'exec'})"), /Unknown workspace action/);
  await js('window.workspaceTest.chooseVault()');
  let first = await state();
  assert(first.document?.documentId);
  assert.equal(first.document.exists, false);
  assert(first.document.path.includes('SaveNest-reader-preview-'));
  await assert.rejects(fs.access(first.document.path), /ENOENT/);
  const body = first.text + '## What I want to remember\n\nA useful idea deserves room to grow. **Keep the source close.**\n\n- [ ] Revisit this thought\n- Connect it to [[Another idea]]\n\nУкраїнські нотатки — 日本語.\n';
  await js(`window.workspaceTest.setText(${JSON.stringify(body)})`);
  await wait(async () => (await state()).document.exists && !(await state()).dirty, 'autosave to Markdown');
  first = await state();
  assert.equal(await fs.readFile(first.document.path, 'utf8'), body);
  assert.equal(workspace.dirty, false);
  const originalId = first.document.documentId;
  await js("document.getElementById('source-toggle').click()");
  assert.equal((await state()).sourceMode, true);
  assert.equal((await state()).text, body);
  await js("document.getElementById('source-toggle').click()");

  const external = body + '\nEdited in Obsidian.\n';
  await fs.writeFile(first.document.path, external);
  await js('window.workspaceTest.check()');
  assert.equal((await state()).text, external);
  const diskVersion = external + '\nA simultaneous external edit.\n';
  await fs.writeFile(first.document.path, diskVersion);
  await js(`window.workspaceTest.setText(${JSON.stringify(external + '\nMy pending change.\n')}); window.workspaceTest.save()`);
  await wait(async () => Boolean((await state()).conflict), 'conflicting edit detected');
  assert.equal(await fs.readFile(first.document.path, 'utf8'), diskVersion);
  assert.equal(await workspace.flush('switch'), false);
  workspace.send({ event: 'flushCancelled' });
  await js("document.getElementById('save-copy').click()");
  await wait(async () => (await state()).document.documentId !== originalId && !(await state()).conflict, 'conflict copy');
  let copied = await state();
  assert.equal(await fs.readFile(first.document.path, 'utf8'), diskVersion);
  assert((await fs.readFile(copied.document.path, 'utf8')).includes('My pending change.'));

  // Reloading a conflict must lock editing until recovery discard finishes.
  const reloadDisk = copied.text + '\nExternal version chosen for reload.\n';
  await fs.writeFile(copied.document.path, reloadDisk);
  await js(`window.workspaceTest.setText(${JSON.stringify(copied.text + '\nLocal conflict to discard.\n')}); window.workspaceTest.save()`);
  await wait(async () => Boolean((await state()).conflict), 'reload conflict detected');
  // A last edit schedules a recovery write; reload must cancel it rather than restore discarded text later.
  await js(`window.workspaceTest.setText(${JSON.stringify(copied.text + '\nFinal local edit before reload.\n')})`);
  const nativeRequest = native.request.bind(native);
  let releaseDiscard, discardStarted = false, lateDrafts = 0;
  const discardGate = new Promise(resolve => { releaseDiscard = resolve; });
  native.request = async command => {
    if (command.command === 'noteDraft' && discardStarted) lateDrafts++;
    if (command.command === 'noteDiscardDraft') { discardStarted = true; await discardGate; }
    return nativeRequest(command);
  };
  try {
    await js("document.getElementById('reload-note').click()");
    await wait(() => discardStarted, 'delayed recovery discard');
    assert.equal(await js("document.querySelector('#editor-host .cm-content').isContentEditable"), false, 'reload blocks typing while replacement is pending');
    assert.equal(await js("['reload-note','save-copy','locate-note'].every(id => document.getElementById(id).disabled)"), true, 'conflict actions cannot overlap');
    await new Promise(resolve => setTimeout(resolve, 250));
    releaseDiscard();
    await wait(async () => !(await state()).conflict && (await state()).text === reloadDisk, 'disk version restored');
    assert.equal(await js("document.querySelector('#editor-host .cm-content').isContentEditable"), true, 'editing resumes after reload');
    assert.equal((await state()).dirty, false);
    assert.equal(lateDrafts, 0, 'discarded writing must not return as a delayed recovery draft');
  } finally { releaseDiscard(); native.request = nativeRequest; }
  copied = await state();

  // Reader extraction is optional and never resets the note or its source.
  const metadata = { ...(await state()).source }; delete metadata.article;
  await workspace.openSource(metadata);
  await wait(async () => { const current = await state(); return current.original && !current.source?.article && current.document?.documentId === copied.document.documentId; }, 'metadata-only Original');
  assert(workspace.original);
  await js('window.workspaceTest.setOriginal(false)');
  assert((await state()).source.article?.content);
  assert.equal((await state()).document.documentId, copied.document.documentId);
  assert.equal((await state()).text, copied.text);

  // Safe HTML and image opt-in; no inserted markup can become application code.
  const fixture = await native.request({ command: 'readerCurrent' });
  fixture.article.content += '<script>window.injected=true</script><img src="https://example.invalid/tracker.png" onerror="window.injected=true"><table background="https://example.invalid/tracker2.png"><tr><td>Safe table</td></tr></table>';
  await workspace.openSource(fixture);
  await wait(async () => (await state()).document?.documentId === copied.document.documentId, 'same URL restores note');
  assert.equal(await js('window.injected === true'), false);
  assert.equal(await js("document.querySelectorAll('#article-content [onerror], #article-content script, #article-content img[src], #article-content [background]').length"), 0);
  await js('window.workspaceTest.setOriginal(true)');
  assert(workspace.original);
  await wait(() => !workspace.original.webContents.isLoading(), 'isolated original webpage');
  assert.equal(await workspace.original.webContents.executeJavaScript('typeof window.workspace'), 'undefined');
  assert.equal(workspace.original.webContents.getLastWebPreferences().sandbox, true);
  await js('window.workspaceTest.setOriginal(false)');
  assert.equal(workspace.original, null);
  await js("document.getElementById('divider').dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft',bubbles:true}))");
  assert.equal(await js("document.getElementById('divider').getAttribute('aria-valuenow')"), '53');
  await js("document.getElementById('divider').dispatchEvent(new KeyboardEvent('keydown', {key:'Home',bubbles:true}))");

  await fs.mkdir(path.join(root, 'build'), { recursive: true });
  for (const theme of ['cream', 'black']) {
    workspace.send({ event: 'appearance', appearance: theme });
    await js('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
    await new Promise(resolve => setTimeout(resolve, 180));
    await fs.writeFile(path.join(root, `build/reader-${theme}.png`), (await win.webContents.capturePage()).toPNG());
  }
  win.setSize(800, 700);
  await js('new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))');
  assert.equal(await js("getComputedStyle(document.getElementById('compact-tabs')).display !== 'none'"), true);
  await fs.writeFile(path.join(root, 'build/reader-compact.png'), (await win.webContents.capturePage()).toPNG());
  win.setSize(1240, 820);
  const pending = (await state()).text + '\nSaved while closing.\n';
  await js(`window.workspaceTest.setText(${JSON.stringify(pending)})`);
  assert.equal(await workspace.close(), true);
  await wait(() => workspace.window === null, 'workspace finishes closing before reopen');
  assert.equal(await fs.readFile(copied.document.path, 'utf8'), pending);
  await workspace.open({ command: 'readerCurrent' });
  win = workspace.window;
  await wait(() => js('Boolean(window.workspaceTest)'), 'reopened workspace');
  assert.equal((await state()).text, pending);
  assert.equal((await state()).original, true, 'reopening defaults to Original');
  assert.equal(await workspace.close(), true);
  assert.deepEqual(errors, []);
  console.log('Passed workspace: vault setup, Markdown autosave, external edits, conflict copy, isolation, layouts, and close/reopen.');
};
