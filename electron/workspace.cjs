'use strict';
const { BrowserWindow, WebContentsView, ipcMain, session, screen, shell, dialog } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const { WORKSPACE_URL, noteCommands, validateWorkspaceCommand, trustedWorkspaceSender, webURL, clampBounds } = require('./workspace-contracts.cjs');
const { glassWindowOptions } = require('./window-material.cjs');

class ReadingWorkspace {
  constructor({ native, preview, userData, appearance = () => 'black', onOpen = () => {}, onWindow = () => {} }) {
    Object.assign(this, { native, preview, userData, appearance, onOpen, onWindow });
    this.window = null; this.source = null; this.payload = null; this.dirty = false;
    this.original = null; this.generation = 0; this.documentGeneration = 0; this.pendingFlushes = new Map(); this.documents = new Set();
    this.operations = 0; this.closing = false; this.allowClose = false;
    this.pendingOpens = 0; this.openingChain = Promise.resolve(); this.operationWaiters = [];
    this.quitting = false; this.destroyed = false; this.imagesEnabled = false;
    this.rendererCrashed = false; this.crashConfirmation = null;
    ipcMain.handle('savenest:workspace', (event, input) => this.request(event, input));
    // Sanitizing an inert HTML fragment can still initiate image loads in Chromium.
    // Enforce the image opt-in at the network boundary, scoped to this local renderer.
    session.defaultSession.webRequest.onBeforeRequest({ urls: ['http://*/*', 'https://*/*'] }, (details, callback) => {
      const ownRequest = this.window && !this.window.isDestroyed() && details.webContentsId === this.window.webContents.id;
      callback({ cancel: Boolean(ownRequest && (!this.imagesEnabled || details.resourceType !== 'image')) });
    });
  }
  send(value) { if (this.window && !this.window.isDestroyed()) this.window.webContents.send('savenest:workspace-event', value); }
  get busy() { return this.dirty || this.operations > 0 || this.pendingOpens > 0 || this.closing || this.quitting || this.pendingFlushes.size > 0; }
  finishOperation() {
    this.operations--;
    if (!this.operations) this.operationWaiters.splice(0).forEach(resolve => resolve());
  }
  waitForOperations() {
    return this.operations ? new Promise(resolve => this.operationWaiters.push(resolve)) : Promise.resolve();
  }
  async ensureWindow() {
    if (this.rendererCrashed && this.window && !this.window.isDestroyed()) this.window.destroy();
    if (this.window && !this.window.isDestroyed()) return false;
    this.rendererCrashed = false;
    const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
    let saved;
    try { saved = JSON.parse(await fs.readFile(path.join(this.userData, 'reading-window.json'), 'utf8')); } catch {}
    const width = Math.min(area.width - 32, Math.max(640, Number(saved?.width) || 1240));
    const height = Math.min(area.height - 48, Math.max(480, Number(saved?.height) || 820));
    this.allowClose = false;
    this.window = new BrowserWindow({ width, height, minWidth: 640, minHeight: 480, show: false,
      title: this.preview ? 'Read & Note — SaveNest Preview' : 'Read & Note — SaveNest',
      titleBarStyle: 'hiddenInset', ...glassWindowOptions,
      webPreferences: { preload: path.join(__dirname, 'workspace-preload.cjs'), sandbox: true, nodeIntegration: false, contextIsolation: true, webSecurity: true, webviewTag: false }
    });
    this.onWindow(this.window);
    this.window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    this.window.webContents.on('will-navigate', event => event.preventDefault());
    this.window.webContents.on('will-attach-webview', event => event.preventDefault());
    this.window.webContents.on('render-process-gone', () => { this.dirty = true; this.rendererCrashed = true; });
    this.window.on('close', event => {
      if (!this.allowClose) { event.preventDefault(); void this.close(); }
    });
    this.window.on('closed', () => {
      this.removeOriginal(); this.window = null; this.imagesEnabled = false;
      for (const pending of this.pendingFlushes.values()) { clearTimeout(pending.timer); pending.resolve(false); }
      this.pendingFlushes.clear();
    });
    this.window.on('resize', () => { if (this.original && this.originalBounds) this.original.setBounds(clampBounds(this.originalBounds, this.window.getContentSize())); });
    await this.window.loadURL(WORKSPACE_URL);
    return true;
  }
  async open(request) {
    if (this.closing || this.quitting || this.destroyed) return false;
    const generation = ++this.generation;
    let source;
    this.operations++;
    try { source = await this.native.request(request); }
    finally { this.finishOperation(); }
    if (!source || !webURL(source.url)) throw new Error('This page is unavailable. Refresh your tabs and try again.');
    if (generation !== this.generation) return false;
    return this.openSource(source, generation);
  }
  openSource(source, generation = ++this.generation) {
    if (this.closing || this.quitting || this.destroyed) return Promise.resolve(false);
    this.pendingOpens++;
    // Serialize transitions: only one renderer flush and one source commit at a time.
    const opening = this.openingChain.then(() => this.applySource(source, generation));
    this.openingChain = opening.catch(() => {});
    return opening.finally(() => { this.pendingOpens--; });
  }
  async applySource(source, generation) {
    if (generation !== this.generation || this.closing || this.quitting || this.destroyed) return false;
    if (!source || !webURL(source.url)) throw new Error('This page is unavailable.');
    if (!await this.flush('switch')) { this.send({ event: 'flushCancelled' }); this.window?.focus(); return false; }
    if (generation !== this.generation) { this.send({ event: 'flushCancelled' }); return false; }
    this.operations++;
    try {
      const notes = await this.native.request({ command: 'notesStatus' });
      if (generation !== this.generation) return false;
      let document;
      if (notes.configured) document = await this.native.request({ command: 'noteLoad', url: source.url, title: source.title || source.url });
      if (generation !== this.generation) return false;
      this.removeOriginal(); this.imagesEnabled = false;
      this.source = source; this.documentGeneration++; this.documents.clear();
      if (document?.documentId) this.documents.add(document.documentId);
      this.payload = { source, notes, document, appearance: this.appearance(), preview: this.preview };
      this.dirty = false;
      const created = await this.ensureWindow();
      if (generation !== this.generation || this.destroyed) return false;
      if (!created) this.send({ event: 'source', ...this.payload });
      this.window.setTitle(`${source.title || 'Read & Note'} — SaveNest${this.preview ? ' Preview' : ''}`);
      this.window.show(); this.window.focus(); this.onOpen();
      return true;
    } catch (error) { this.send({ event: 'flushCancelled' }); throw error; }
    finally {
      this.finishOperation();
      if (generation !== this.generation && !this.closing && !this.quitting) this.send({ event: 'flushCancelled' });
    }
  }
  async request(event, input) {
    if (!trustedWorkspaceSender(event, this.window?.webContents)) throw new Error('Untrusted reading window.');
    const request = validateWorkspaceCommand(input);
    if (request.command === 'init') return this.payload;
    if (request.command === 'ready') return true;
    if (request.command === 'dirty') { this.dirty = request.dirty; return true; }
    if (request.command === 'flushed') {
      const pending = this.pendingFlushes.get(request.requestId);
      if (pending) { clearTimeout(pending.timer); this.pendingFlushes.delete(request.requestId); pending.resolve(request.ok && !this.dirty); }
      return true;
    }
    if (request.command === 'close') { void this.close(); return true; }
    if (request.command === 'readerImages') { this.imagesEnabled = request.enabled; return true; }
    if (request.command === 'browser') {
      const url = webURL(request.url || this.source?.url);
      if (!url) throw new Error('This page address is unavailable.');
      if (!this.preview) await shell.openExternal(url);
      return true;
    }
    if (request.command === 'readerExtract') {
      const generation = this.documentGeneration, owner = this.window;
      this.operations++;
      try {
        // Use the pinned source, never an arbitrary URL supplied by the renderer.
        const result = await this.native.request({ command: 'readerExtract', url: this.source.url });
        if (generation !== this.documentGeneration || owner !== this.window || this.destroyed) throw new Error('The page changed. Choose Reader again.');
        if (result.url !== this.source.url) throw new Error('The browser tab changed. Reopen this page.');
        this.source = { ...this.source, article: result.article, captureError: result.captureError };
        this.payload.source = this.source;
        return this.source;
      } finally { this.finishOperation(); }
    }
    if (request.command === 'original') return this.showOriginal(request);
    if (noteCommands.has(request.command)) {
      if (request.documentId && !this.documents.has(request.documentId)) throw new Error('This note is no longer open.');
      if (request.command === 'noteLoad' && request.url !== this.source?.url) throw new Error('The page changed. Reopen its note.');
      const generation = this.documentGeneration;
      const owner = this.window;
      this.operations++;
      try {
        const result = await this.native.request(request);
        if (generation !== this.documentGeneration || owner !== this.window || this.destroyed) throw new Error('The page changed. Reopen its note.');
        if (result?.documentId) this.documents.add(result.documentId);
        if (['notesChooseVault', 'notesChooseFolder'].includes(request.command)) this.payload.notes = result;
        if (result?.documentId && ['noteLoad', 'noteSave', 'noteSaveCopy', 'noteLocate'].includes(request.command) && !result.conflict && !result.missing) this.payload.document = result;
        return result;
      } finally { this.finishOperation(); }
    }
    throw new Error('Unknown workspace action.');
  }
  async showOriginal({ enabled, bounds }) {
    if (!enabled) { this.removeOriginal(); return true; }
    this.originalBounds = bounds;
    if (this.original) { this.original.setBounds(clampBounds(bounds, this.window.getContentSize())); return true; }
    const isolated = session.fromPartition(`reader-${randomUUID()}`, { cache: false });
    isolated.setPermissionRequestHandler((_contents, _permission, callback) => callback(false));
    isolated.setPermissionCheckHandler(() => false);
    isolated.on('will-download', event => event.preventDefault());
    const view = new WebContentsView({ webPreferences: { session: isolated, sandbox: true, nodeIntegration: false, contextIsolation: true, webSecurity: true, webviewTag: false, navigateOnDragDrop: false } });
    this.original = view;
    view.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
    view.webContents.on('will-attach-webview', event => event.preventDefault());
    let loadingInitial = true;
    view.webContents.on('will-navigate', (event, destination) => {
      // loadURL does not emit this event. All subsequent top-level navigation
      // belongs in the external browser, even if the first load is still pending.
      event.preventDefault();
      if (webURL(destination)) this.send({ event: 'originalNavigation', url: destination });
    });
    view.webContents.on('will-redirect', (event, destination) => { if (!loadingInitial || !webURL(destination)) event.preventDefault(); });
    view.webContents.on('did-finish-load', () => { loadingInitial = false; if (this.original === view) this.send({ event: 'originalState', loading: false }); });
    view.webContents.on('did-fail-load', (_event, code, _description, _url, mainFrame) => {
      if (this.original === view && mainFrame && code !== -3) this.send({ event: 'originalState', loading: false, error: 'This website could not load here. Open it in your browser.' });
    });
    this.window.contentView.addChildView(view);
    view.setBounds(clampBounds(bounds, this.window.getContentSize()));
    this.send({ event: 'originalState', loading: true });
    const url = this.preview ? 'data:text/html,<html><body style="font:18px Georgia;padding:40px;color:%232b3029;background:%23faf9f6"><h1>Original webpage</h1><p>This isolated preview uses a sample page. In the app, the original website loads here.</p></body></html>' : this.source.url;
    void view.webContents.loadURL(url).catch(() => {});
    return true;
  }
  removeOriginal() {
    if (!this.original) return;
    const view = this.original; this.original = null;
    if (this.window && !this.window.isDestroyed()) this.window.contentView.removeChildView(view);
    if (!view.webContents.isDestroyed()) view.webContents.close();
  }
  flush(reason) {
    if (!this.window || this.window.isDestroyed()) return Promise.resolve(!this.dirty);
    if (this.rendererCrashed) {
      if (!this.crashConfirmation) this.crashConfirmation = dialog.showMessageBox(this.window, {
        type: 'warning', message: 'The reading window stopped responding.',
        detail: 'Saved notes and recovery drafts remain on this Mac. Reopening the note restores its latest recovery draft; the last few keystrokes may not have reached disk.',
        buttons: ['Keep window', reason === 'switch' ? 'Reopen workspace' : 'Close window'], defaultId: 0, cancelId: 0
      }).then(result => { if (result.response !== 1) return false; this.dirty = false; return true; })
        .catch(() => false).finally(() => { this.crashConfirmation = null; });
      return this.crashConfirmation;
    }
    const requestId = randomUUID();
    return new Promise(resolve => {
      const timer = setTimeout(() => { this.pendingFlushes.delete(requestId); resolve(false); this.send({ event: 'flushCancelled' }); }, 15000);
      this.pendingFlushes.set(requestId, { resolve, timer });
      this.send({ event: 'flush', requestId, reason });
    });
  }
  async close() {
    if (this.closing || !this.window || this.window.isDestroyed()) return false;
    this.closing = true; ++this.generation;
    try {
      if (!await this.flush('close')) { this.send({ event: 'flushCancelled' }); return false; }
      await this.waitForOperations();
      if (!this.window || this.window.isDestroyed()) return true;
      const { width, height } = this.window.getBounds();
      // Window geometry must never prevent closing a safely saved document.
      try {
        await fs.mkdir(this.userData, { recursive: true });
        await fs.writeFile(path.join(this.userData, 'reading-window.json'), JSON.stringify({ width, height }));
      } catch {}
      this.removeOriginal(); this.allowClose = true; this.dirty = false; this.window.close();
      return true;
    } finally { this.closing = false; }
  }
  async prepareToQuit() {
    if (this.quitting) return false;
    this.quitting = true; ++this.generation;
    try {
      if (!await this.flush('quit')) { this.send({ event: 'flushCancelled' }); return false; }
      await this.waitForOperations();
      return true;
    } finally { this.quitting = false; }
  }
  destroy() {
    this.destroyed = true; ++this.generation;
    this.removeOriginal();
    for (const pending of this.pendingFlushes.values()) { clearTimeout(pending.timer); pending.resolve(false); }
    this.pendingFlushes.clear();
    if (this.window && !this.window.isDestroyed()) this.window.destroy();
  }
}
module.exports = { ReadingWorkspace };
