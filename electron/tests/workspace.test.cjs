'use strict';
const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { readFileSync, mkdtempSync, rmSync, writeFileSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { WORKSPACE_URL, validateWorkspaceCommand, trustedWorkspaceSender, webURL, clampBounds } = require('../workspace-contracts.cjs');

function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
async function tick() { await new Promise(resolve => setImmediate(resolve)); }
const testDirectories = [];
afterEach(() => { for (const directory of testDirectories.splice(0)) rmSync(directory, {recursive:true, force:true}); });
async function waitForClose(workspace) {
  const deadline = Date.now() + 3000;
  while (workspace.escapePrompt || workspace.closing) {
    assert.ok(Date.now() < deadline, 'close operation must finish');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}
function harness(native = { request: async () => ({ configured: false }) }, userData) {
  let networkHandler, nextID = 1;
  const fakeContents = () => Object.assign(new EventEmitter(), {
    id: nextID++, mainFrame: { url: WORKSPACE_URL }, destroyed: false,
    isDestroyed() { return this.destroyed; }, close() { this.destroyed = true; },
    setWindowOpenHandler(handler) { this.windowOpenHandler = handler; },
    send(_channel, message) {
      this.messages.push(message);
      if (message.event === 'flush' && this.autoFlush) queueMicrotask(() => workspace.request(event(), { command: 'flushed', requestId: message.requestId, ok: true }));
    },
    messages: [], autoFlush: true, loadURL: async () => {}
  });
  class FakeWindow extends EventEmitter {
    constructor(options) { super(); this.options = options; this.webContents = fakeContents(); this.destroyed = false; this.contentView = { addChildView() {}, removeChildView() {} }; }
    isDestroyed() { return this.destroyed; }
    getContentSize() { return [1240, 820]; }
    getBounds() { return { width: 1240, height: 820 }; }
    loadURL() { return Promise.resolve(); }
    setTitle() {}
    show() {}
    focus() {}
    close() { this.destroy(); }
    destroy() { this.destroyed = true; this.emit('closed'); }
  }
  class FakeView { constructor(options) { this.options = options; this.webContents = fakeContents(); } setBounds(bounds) { this.bounds = bounds; } }
  const fakeSession = () => Object.assign(new EventEmitter(), { setPermissionRequestHandler(handler) { this.permissionHandler = handler; }, setPermissionCheckHandler(handler) { this.permissionCheck = handler; } });
  const electron = {
    BrowserWindow: FakeWindow, WebContentsView: FakeView, ipcMain: { handle() {} },
    session: { defaultSession: { webRequest: { onBeforeRequest(_filter, handler) { networkHandler = handler; } } }, fromPartition: fakeSession },
    screen: { getCursorScreenPoint: () => ({x:0,y:0}), getDisplayNearestPoint: () => ({workArea:{width:1440,height:900}}) },
    shell: { openExternal: async () => {} }, dialog: { showMessageBox: async () => ({response:0}) }
  };
  const module = { exports: {} }, directory = path.resolve(__dirname, '..');
  const code = readFileSync(path.join(directory, 'workspace.cjs'), 'utf8');
  vm.runInNewContext(code, { module, exports: module.exports, require: name => name === 'electron' ? electron : name.startsWith('./') ? require(path.join(directory, name)) : require(name), __dirname: directory, setTimeout, clearTimeout, console });
  if (!userData) { userData = mkdtempSync(path.join(os.tmpdir(), 'savenest-workspace-tests-')); testDirectories.push(userData); }
  const workspace = new module.exports.ReadingWorkspace({ native, preview: true, userData });
  workspace.window = new FakeWindow({});
  workspace.source = { url: 'https://example.com/a', title: 'Page A' };
  workspace.payload = { source: workspace.source, notes: {configured:true} };
  workspace.documents.add('note-a');
  const event = () => ({ sender: workspace.window.webContents, senderFrame: workspace.window.webContents.mainFrame });
  return { workspace, event, electron, network: details => { let value; networkHandler(details, result => { value = result; }); return value; } };
}

test('workspace commands reject arbitrary capabilities and malformed note writes', () => {
  for (const input of [null, [], 'noteSave', {command:'exec'}, {command:'callback'}, {command:'noteDiscardDraft'}, {command:'noteSave',documentId:'a',text:'x'}, {command:'noteDraft',documentId:'a',revision:'r',text:'x'.repeat(100001)}, {command:'readerImages',enabled:1}, {command:'original',enabled:true,bounds:{x:0,y:0,width:NaN,height:40}}]) assert.throws(() => validateWorkspaceCommand(input));
  assert.deepEqual(validateWorkspaceCommand({command:'noteDiscardDraft',documentId:'note-a',path:'/etc/passwd'}), {command:'noteDiscardDraft',documentId:'note-a'});
  assert.equal(webURL('file:///etc/passwd'), null);
  assert.equal(webURL('https://user:password@example.com'), null);
  assert.deepEqual(clampBounds({x:1200,y:800,width:900,height:1000},[1240,820]),{x:1200,y:800,width:40,height:20});
});

test('only the exact owning local main frame can access workspace IPC', async () => {
  const {workspace,event} = harness();
  assert.equal(trustedWorkspaceSender(event(), workspace.window.webContents), true);
  const childFrame = {...event(),senderFrame:{url:WORKSPACE_URL}};
  assert.equal(trustedWorkspaceSender(childFrame,workspace.window.webContents),false);
  await assert.rejects(workspace.request(childFrame,{command:'noteOpen',documentId:'note-a'}),/Untrusted/);
  await assert.rejects(workspace.request(event(),{command:'noteOpen',documentId:'another-note'}),/no longer open/);
  await assert.rejects(workspace.request(event(),{command:'noteLoad',url:'https://example.com/b'}),/page changed/);
  workspace.destroy();
});

test('reader image requests require explicit opt-in and never authorize other network types', async () => {
  const {workspace,event,network} = harness();
  const request = {webContentsId:workspace.window.webContents.id,resourceType:'image'};
  assert.equal(network(request).cancel,true);
  await workspace.request(event(),{command:'readerImages',enabled:true});
  assert.equal(network(request).cancel,false);
  assert.equal(network({...request,resourceType:'xhr'}).cancel,true);
  assert.equal(network({...request,webContentsId:-1}).cancel,false);
  workspace.destroy();
});

test('a successful flush acknowledgement cannot close a document still marked dirty', async () => {
  const {workspace} = harness();
  workspace.dirty = true;
  assert.equal(await workspace.close(),false);
  assert.equal(workspace.window.isDestroyed(),false);
  assert.equal(workspace.dirty,true);
  workspace.destroy();
});

test('Escape in either reading pane offers one cancellable archive prompt', async () => {
  const {workspace,electron} = harness();
  workspace.window = null;
  await workspace.ensureWindow();
  await workspace.showOriginal({enabled:true,bounds:{x:0,y:100,width:600,height:600}});
  const answer = deferred();
  let prompts = 0, prevented = 0;
  electron.dialog.showMessageBox = async (_owner, options) => {
    prompts++;
    assert.equal(options.buttons[2], 'Archive and close tab');
    assert.equal(options.cancelId, 0);
    return answer.promise;
  };
  const input = {type:'keyDown',key:'Escape'};
  const event = {preventDefault() { prevented++; }};
  workspace.original.webContents.emit('before-input-event', event, input);
  workspace.window.webContents.emit('before-input-event', event, input);
  assert.equal(prompts, 1);
  assert.equal(prevented, 2);
  assert.equal(await workspace.openSource({url:'https://example.com/b'}), false);
  answer.resolve({response:0});
  await tick();
  assert.equal(workspace.window.isDestroyed(), false);
  assert.equal(workspace.escapePrompt, false);
  workspace.window.webContents.emit('before-input-event', event, {...input,isAutoRepeat:true});
  assert.equal(prompts, 1);
  workspace.window.webContents.emit('before-input-event', event, input);
  await tick();
  assert.equal(prompts, 2, 'the notes pane can also trigger the popup');
  workspace.destroy();
});

test('Command W and Escape in both panes save before closing through the same choice', async () => {
  for (const pane of ['window', 'original']) for (const input of [
    {type:'keyDown',key:'w',meta:true}, {type:'keyDown',key:'Escape'}
  ]) {
    const {workspace,electron} = harness();
    workspace.window = null;
    await workspace.ensureWindow();
    await workspace.showOriginal({enabled:true,bounds:{x:0,y:100,width:600,height:600}});
    const owner = workspace.window;
    let prompts = 0;
    electron.dialog.showMessageBox = async (_owner, options) => {
      prompts++;
      assert.equal(options.checkboxLabel, 'Remember my choice');
      return {response:1};
    };
    workspace[pane].webContents.emit('before-input-event', {preventDefault() {}}, input);
    await waitForClose(workspace);
    assert.equal(prompts, 1);
    assert.equal(owner.isDestroyed(), true);
    assert.equal(owner.webContents.messages.some(message => message.event === 'flush'), true);
  }
});

test('window close and renderer close cannot bypass the close choice', async () => {
  for (const trigger of ['window', 'ipc']) {
    const {workspace,electron,event} = harness();
    workspace.window = null;
    await workspace.ensureWindow();
    let prompts = 0;
    electron.dialog.showMessageBox = async () => { prompts++; return {response:0}; };
    if (trigger === 'window') workspace.window.emit('close', {preventDefault() {}});
    else await workspace.request(event(), {command:'close'});
    await waitForClose(workspace);
    assert.equal(prompts, 1);
    assert.equal(workspace.window.isDestroyed(), false);
    workspace.destroy();
  }
});

test('remembered close choices survive reopening and can be reset with Shift Escape', async () => {
  for (const response of [1, 2]) {
    const {workspace,electron} = harness();
    electron.dialog.showMessageBox = async () => ({response, checkboxChecked:true});
    assert.equal(await workspace.confirmArchiveAndClose(), true);
    const reopened = harness(undefined, workspace.userData);
    let prompts = 0;
    reopened.electron.dialog.showMessageBox = async () => { prompts++; return {response:0}; };
    assert.equal(reopened.workspace.closeChoice, response === 1 ? 'window' : 'archive');
    assert.equal(await reopened.workspace.confirmArchiveAndClose(), true);
    assert.equal(prompts, 0);
    const reset = harness(undefined, workspace.userData);
    reset.electron.dialog.showMessageBox = async () => ({response:1, checkboxChecked:false});
    reset.workspace.handleInput({preventDefault() {}}, {type:'keyDown',key:'Escape',shift:true});
    await waitForClose(reset.workspace);
    assert.equal(reset.workspace.closeChoice, null);
    const next = harness(undefined, workspace.userData);
    assert.equal(next.workspace.closeChoice, null);
    next.workspace.destroy();
  }
});

test('cancel, failed saves, and invalid preferences never remember a destructive action', async () => {
  const {workspace,electron} = harness();
  electron.dialog.showMessageBox = async () => ({response:0, checkboxChecked:true});
  assert.equal(await workspace.confirmArchiveAndClose(), false);
  assert.equal(workspace.closeChoice, null);
  workspace.dirty = true;
  electron.dialog.showMessageBox = async () => ({response:2, checkboxChecked:true});
  assert.equal(await workspace.confirmArchiveAndClose(), false);
  assert.equal(workspace.closeChoice, null);
  workspace.closeChoice = 'archive';
  electron.dialog.showMessageBox = async () => { throw new Error('Should use remembered choice'); };
  assert.equal(await workspace.confirmArchiveAndClose(), false);
  assert.equal(workspace.window.isDestroyed(), false);
  writeFileSync(path.join(workspace.userData, 'reader-close-choice.json'), '{"choice":"delete"}');
  const invalid = harness(undefined, workspace.userData);
  assert.equal(invalid.workspace.closeChoice, null);
  invalid.workspace.destroy(); workspace.destroy();
});

test('Command Shift W in either pane archives once after saving without prompting', async () => {
  for (const pane of ['window', 'original']) {
    const archived = deferred();
    let called = 0;
    const {workspace,electron} = harness({request:async request => {
      called++;
      assert.equal(workspace.window.webContents.messages.at(-1).event, 'flush');
      assert.equal(request.command, 'readerArchiveClose');
      assert.equal(request.url, 'https://example.com/a');
      assert.equal(request.sourceId, 'pinned-session');
      return archived.promise;
    }});
    workspace.source.sourceId = 'pinned-session';
    workspace.window = null;
    await workspace.ensureWindow();
    await workspace.showOriginal({enabled:true,bounds:{x:0,y:100,width:600,height:600}});
    let prompts = 0, prevented = 0;
    electron.dialog.showMessageBox = async () => { prompts++; return {response:0}; };
    const contents = workspace[pane].webContents;
    const event = {preventDefault() { prevented++; }};
    const input = {type:'keyDown',key:'W',meta:true,shift:true};
    for (const ignored of [{meta:false},{alt:true},{control:true}]) {
      contents.emit('before-input-event', event, {...input,...ignored});
    }
    assert.equal(prevented, 0);
    contents.emit('before-input-event', event, {...input,isAutoRepeat:true});
    contents.emit('before-input-event', event, {...input,type:'keyUp'});
    await tick();
    assert.equal(called, 0);
    contents.emit('before-input-event', event, input);
    contents.emit('before-input-event', event, input);
    await tick();
    assert.equal(called, 1);
    assert.equal(prompts, 0);
    assert.equal(await workspace.openSource({url:'https://example.com/b'}), false);
    const closed = new Promise(resolve => workspace.window.once('closed', resolve));
    archived.resolve({archived:true});
    await closed;
    assert.equal(workspace.window, null);
  }
});

test('direct archive shortcut preserves notes on save failure and recovers from archive errors', async () => {
  let called = 0;
  const {workspace} = harness({request:async () => { called++; throw new Error('Archive failed'); }});
  workspace.dirty = true;
  assert.equal(await workspace.archiveAndClose(), false);
  assert.equal(called, 0);
  workspace.dirty = false;
  for (const blocked of ['escapePrompt', 'quitting', 'pendingOpens']) {
    workspace[blocked] = 1;
    assert.equal(await workspace.archiveAndClose(), false);
    workspace[blocked] = 0;
  }
  assert.equal(called, 0);
  assert.equal(await workspace.archiveAndClose(), false);
  assert.equal(called, 1);
  assert.equal(workspace.window.isDestroyed(), false);
  assert.equal(workspace.window.webContents.messages.at(-1).event, 'flushCancelled');
  assert.equal(workspace.window.webContents.messages.at(-2).message, 'Archive failed');
  assert.equal(workspace.closing, false);
  workspace.destroy();
});

test('archive confirmation flushes notes before acting on the pinned source', async () => {
  let called = 0;
  const {workspace,electron} = harness({request:async request => {
    called++;
    assert.equal(workspace.dirty, false);
    assert.equal(workspace.window.webContents.messages.at(-1).event, 'flush');
    assert.equal(request.command, 'readerArchiveClose');
    assert.equal(request.url, 'https://example.com/a');
    assert.equal(request.sourceId, 'pinned-session');
    return {archived:true};
  }});
  workspace.source.sourceId = 'pinned-session';
  electron.dialog.showMessageBox = async () => ({response:2});
  assert.equal(await workspace.confirmArchiveAndClose(), true);
  assert.equal(called, 1);
  assert.equal(workspace.window.isDestroyed(), true);
});

test('failed note save or archive keeps the workspace open and unlocks editing', async () => {
  let called = 0;
  const {workspace,electron} = harness({request:async () => { called++; throw new Error('Archive failed'); }});
  electron.dialog.showMessageBox = async () => ({response:2});
  workspace.dirty = true;
  assert.equal(await workspace.confirmArchiveAndClose(), false);
  assert.equal(called, 0, 'unsaved writing blocks archiving and tab closure');
  workspace.dirty = false;
  assert.equal(await workspace.confirmArchiveAndClose(), false);
  assert.equal(called, 1);
  assert.equal(workspace.window.isDestroyed(), false);
  assert.equal(workspace.window.webContents.messages.at(-1).event, 'flushCancelled');
  assert.equal(workspace.window.webContents.messages.at(-2).message, 'Archive failed');
  assert.equal(workspace.closing, false);
  workspace.destroy();
});

test('Close window from the Escape prompt leaves the browser and library alone', async () => {
  const {workspace,electron} = harness({request:async () => { throw new Error('Must not archive'); }});
  electron.dialog.showMessageBox = async () => ({response:1});
  assert.equal(await workspace.confirmArchiveAndClose(), true);
  assert.equal(workspace.window.isDestroyed(), true);
});

test('only the latest requested page wins when browser capture returns out of order', async () => {
  const a=deferred(),b=deferred();
  const {workspace} = harness({request: request => request.command === 'notesStatus' ? Promise.resolve({configured:false}) : request.command === 'a' ? a.promise : b.promise});
  const first=workspace.open({command:'a'}), second=workspace.open({command:'b'});
  assert.equal(workspace.busy,true);
  b.resolve({url:'https://example.com/b',title:'B'});
  assert.equal(await second,true);
  a.resolve({url:'https://example.com/a',title:'A'});
  assert.equal(await first,false);
  assert.equal(workspace.source.title,'B');
  assert.equal(workspace.busy,false);
  workspace.destroy();
});

test('starting a page capture does not invalidate the current document save', async () => {
  const save=deferred(),capture=deferred();
  const {workspace,event} = harness({request: request => request.command === 'noteSave' ? save.promise : capture.promise});
  const pendingSave=workspace.request(event(),{command:'noteSave',documentId:'note-a',text:'My writing',revision:'r1'});
  const pendingOpen=workspace.open({command:'readerCurrent'});
  save.resolve({documentId:'note-a',text:'My writing',revision:'r2'});
  assert.equal((await pendingSave).revision,'r2');
  workspace.destroy();
  capture.resolve({url:'https://example.com/new',title:'New'});
  assert.equal(await pendingOpen,false);
});

test('stale note responses cannot authorize documents after the active source changes', async () => {
  const note=deferred();
  const {workspace,event} = harness({request:()=>note.promise});
  const response=workspace.request(event(),{command:'noteLoad',url:workspace.source.url});
  workspace.documentGeneration++;
  note.resolve({documentId:'stale-note',text:'old'});
  await assert.rejects(response,/page changed/);
  assert.equal(workspace.documents.has('stale-note'),false);
  workspace.destroy();
});

test('quit cancels and drains pending capture before reporting it is safe to stop the helper', async () => {
  const capture=deferred();
  const {workspace} = harness({request:()=>capture.promise});
  const open=workspace.open({command:'readerCurrent'});
  let finished=false;
  const quit=workspace.prepareToQuit().then(value=>{finished=true;return value;});
  await tick();
  assert.equal(finished,false);
  capture.resolve({url:'https://example.com/late',title:'Late'});
  assert.equal(await open,false);
  assert.equal(await quit,true);
  assert.equal(workspace.source.title,'Page A');
  workspace.destroy();
});

test('Original view has no preload or Node access and blocks unsolicited navigation', async () => {
  const {workspace,event}=harness();
  await workspace.request(event(),{command:'original',enabled:true,bounds:{x:0,y:100,width:600,height:600}});
  const view=workspace.original,preferences=view.options.webPreferences;
  assert.equal(preferences.preload,undefined);
  assert.equal(preferences.nodeIntegration,false);
  assert.equal(preferences.sandbox,true);
  assert.equal(preferences.contextIsolation,true);
  assert.equal(preferences.session.permissionCheck(),false);
  let prevented=false;
  view.webContents.emit('will-navigate',{preventDefault(){prevented=true;}},'https://example.com/other');
  assert.equal(prevented,true);
  assert.equal(workspace.window.webContents.messages.at(-1).event,'originalNavigation');
  workspace.removeOriginal();
  const before=workspace.window.webContents.messages.length;
  view.webContents.emit('did-finish-load');
  assert.equal(workspace.window.webContents.messages.length,before,'old view must not send state into a replacement');
  workspace.destroy();
});

test('Original new-tab links offer the browser action without opening an app window or changing the note', async () => {
  const {workspace,event,electron}=harness();
  const opened = [];
  electron.shell.openExternal = async url => opened.push(url);
  workspace.preview = false;
  await workspace.request(event(),{command:'original',enabled:true,bounds:{x:0,y:100,width:600,height:600}});
  const view = workspace.original, source = workspace.source;
  for (const disposition of ['foreground-tab', 'background-tab', 'new-window']) {
    const url = `https://example.com/${disposition}`;
    assert.equal(view.webContents.windowOpenHandler({url,disposition}).action, 'deny');
    const message = workspace.window.webContents.messages.at(-1);
    assert.equal(message.event, 'originalNavigation');
    assert.equal(message.url, url);
  }
  assert.equal(opened.length, 0, 'the page cannot launch a browser without the workspace action');
  await workspace.request(event(),{command:'browser',url:workspace.window.webContents.messages.at(-1).url});
  assert.deepEqual(opened, ['https://example.com/new-window']);
  assert.equal(workspace.source, source);
  assert.equal(workspace.documents.has('note-a'), true);

  const before = workspace.window.webContents.messages.length;
  for (const url of ['javascript:alert(1)', 'file:///etc/passwd', 'data:text/html,test', 'obsidian://open', 'https://user:password@example.com', 'invalid']) {
    assert.equal(view.webContents.windowOpenHandler({url}).action, 'deny');
  }
  assert.equal(workspace.window.webContents.messages.length, before, 'unsupported destinations cannot create an open-link action');
  workspace.removeOriginal();
  view.webContents.windowOpenHandler({url:'https://example.com/stale-popup'});
  view.webContents.emit('will-navigate',{preventDefault(){}},'https://example.com/stale-navigation');
  assert.equal(workspace.window.webContents.messages.length, before, 'a removed view cannot offer stale links');
  workspace.destroy();
});

test('a crashed renderer preserves recovery and requires an explicit choice before closing', async () => {
  const {workspace,electron}=harness();
  workspace.rendererCrashed=true; workspace.dirty=true;
  assert.equal(await workspace.flush('quit'),false);
  assert.equal(workspace.dirty,true);
  electron.dialog.showMessageBox=async()=>({response:1});
  assert.equal(await workspace.flush('quit'),true);
  assert.equal(workspace.dirty,false);
  workspace.destroy();
});


test('optional Reader extraction is pinned to the open page and rejects stale responses', async () => {
  const capture = deferred(); let requested;
  const {workspace,event} = harness({request: request => { requested = request; return capture.promise; }});
  const pending = workspace.request(event(), {command:'readerExtract',url:'https://example.com/other'});
  assert.equal(requested.url, 'https://example.com/a');
  assert.equal(requested.command, 'readerExtract');
  workspace.documentGeneration++;
  capture.resolve({url:'https://example.com/a',article:{content:'Old article'}});
  await assert.rejects(pending, /page changed/);
  assert.equal(workspace.source.article,undefined);
  workspace.destroy();
});
