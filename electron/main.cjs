'use strict';
const { app, BrowserWindow, Menu, Tray, nativeImage, nativeTheme, ipcMain, protocol, session, dialog, screen, autoUpdater } = require('electron');
const path = require('node:path');
const fs = require('node:fs/promises');
const { NativeClient } = require('./native-client.cjs');
const { createUpdater, canRestartSafely } = require('./updater.cjs');
const { APP_URL, validateCommand, trustedSender, assetName } = require('./contracts.cjs');
const { ReadingWorkspace } = require('./workspace.cjs');
const { glassWindowOptions, updateWindowMaterial } = require('./window-material.cjs');

const preview = !app.isPackaged && process.argv.includes('--preview');
const smoke = preview && process.argv.includes('--smoke-test');
const readerLive = preview && !smoke && process.argv.includes('--reader-live');
const root = path.join(__dirname, '..');
app.setName(readerLive ? 'Savenest Reader Test' : preview ? 'Savenest Preview' : 'Savenest');
app.setPath('userData', preview ? path.join(root, 'build', smoke ? 'electron-test-profile' : readerLive ? 'electron-reader-test-profile' : 'electron-preview-profile') : path.join(app.getPath('appData'), 'SaveNest Electron'));
app.enableSandbox();
protocol.registerSchemesAsPrivileged([{ scheme: 'savenest-ui', privileges: { standard: true, secure: true, supportFetchAPI: true } }]);

let win, tray, native, updater, workspace, latestState, fatalError, quitting = false, preparingQuit = false;
let currentView = 'root';
let hiddenAt = 0, showing = null, modalDepth = 0, blurTimer;
const callbacks = [];

function refreshWindowMaterials() {
  const appearance = latestState?.appearance || 'black';
  const theme = appearance === 'cream' ? 'light' : 'dark';
  if (nativeTheme.themeSource !== theme) nativeTheme.themeSource = theme;
  const options = { appearance, reducedTransparency: nativeTheme.prefersReducedTransparency, highContrast: nativeTheme.shouldUseHighContrastColors };
  updateWindowMaterial(win, options);
  updateWindowMaterial(workspace?.window, options);
}

function send(event) { if (win && !win.isDestroyed()) win.webContents.send('savenest:event', event); }
function position(launcher = win) {
  if (!launcher || launcher.isDestroyed()) return;
  const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
  const [width, height] = launcher.getSize();
  launcher.setPosition(Math.round(area.x + (area.width - width) / 2), Math.round(area.y + Math.min(area.height * 0.2, Math.max(16, area.height - height - 24))));
}
async function show() {
  const launcher = win;
  if (!launcher || launcher.isDestroyed() || quitting || showing === launcher) return;
  if (launcher.isVisible()) { launcher.focus(); send({ event: 'focus', reset: false }); return; }
  showing = launcher;
  try {
    if (native && !fatalError) await command({ command: 'panelWillShow' });
    if (launcher !== win || launcher.isDestroyed() || quitting) return;
    position(launcher); launcher.show(); launcher.focus();
    send({ event: 'focus', reset: Boolean(hiddenAt && Date.now() - hiddenAt > 60000) });
    if (native && !fatalError) { void command({ command: 'resume' }); void command({ command: 'synchronize' }); }
  } finally { if (showing === launcher) showing = null; }
}
function hide(restore = false) {
  if (!win || win.isDestroyed()) return;
  hiddenAt = Date.now(); win.hide();
  if (native && !fatalError) {
    void command({ command: 'suspend' });
    if (restore) void command({ command: 'restoreFocus' });
  }
}
function toggle() {
  if (win && !win.isDestroyed() && win.isVisible() && win.isFocused()) hide(true);
  else void show();
}

function createLauncherWindow() {
  clearTimeout(blurTimer);
  currentView = 'root';
  hiddenAt = 0;
  const launcher = new BrowserWindow({
    width: 760, height: 520, show: false, frame: false, type: 'panel',
    resizable: false, minimizable: false, maximizable: false, fullscreenable: false,
    alwaysOnTop: true, skipTaskbar: true, roundedCorners: true, hasShadow: true,
    title: preview ? 'Savenest Preview' : 'Savenest', ...glassWindowOptions,
    webPreferences: { preload: path.join(__dirname, 'preload.cjs'), nodeIntegration: false, contextIsolation: true, sandbox: true, webSecurity: true, webviewTag: false }
  });
  win = launcher;
  refreshWindowMaterials();
  launcher.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  launcher.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  launcher.webContents.on('will-navigate', event => event.preventDefault());
  launcher.webContents.on('will-attach-webview', event => event.preventDefault());
  launcher.webContents.on('render-process-gone', () => {
    if (quitting || launcher.isDestroyed() || launcher !== win) return;
    fatalError = 'The window stopped responding. Quit and reopen Savenest.';
    dialog.showErrorBox('Savenest', fatalError);
  });
  launcher.on('close', event => { if (!quitting && launcher === win) { event.preventDefault(); hide(true); } });
  launcher.on('blur', () => {
    if (launcher !== win || launcher.isDestroyed()) return;
    clearTimeout(blurTimer);
    blurTimer = setTimeout(() => {
      if (launcher !== win || launcher.isDestroyed() || quitting) return;
      if (!smoke && !modalDepth && !launcher.isFocused()) hide();
    }, 120);
  });
  launcher.on('focus', () => {
    if (launcher === win && !launcher.isDestroyed() && !quitting && native && latestState) void command({ command: 'synchronize' });
  });
  return launcher;
}

async function recoverAfterInstallError() {
  quitting = false;
  if (!win || win.isDestroyed()) {
    const launcher = createLauncherWindow();
    await launcher.loadURL(APP_URL);
    if (fatalError) send({ event: 'fatal', message: fatalError });
  }
  await show();
}
async function command(input) {
  if (['readerCurrent', 'readerOpen'].includes(input.command)) {
    try { return await workspace.open(input); }
    catch (error) { send({ event: 'error', message: error.message }); return false; }
  }
  try { return await native.request(input); }
  catch (error) { send({ event: 'error', message: error.message }); return false; }
}
function incomingURL(url) {
  if (preview || typeof url !== 'string' || url.length > 16384 || !url.startsWith('savenest://')) return;
  if (native && latestState) void command({ command: 'callback', url });
  else if (callbacks.length < 10) callbacks.push(url);
}
app.on('open-url', (event, url) => { event.preventDefault(); incomingURL(url); });

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_event, argv) => { argv.filter(v => v.startsWith('savenest://')).forEach(incomingURL); show(); });
  app.on('activate', show);
  app.on('window-all-closed', () => {});
  app.on('before-quit', event => {
    if (!quitting && (workspace?.busy || (workspace?.window && !workspace.window.isDestroyed()))) {
      event.preventDefault();
      if (preparingQuit) return;
      preparingQuit = true;
      void workspace.prepareToQuit().then(saved => {
        if (saved) { quitting = true; app.quit(); }
        else { workspace.send({ event: 'flushCancelled' }); workspace.window?.focus(); }
      }).finally(() => { preparingQuit = false; });
      return;
    }
    quitting = true; workspace?.destroy(); native?.stop(); tray?.destroy();
  });
  app.whenReady().then(start).catch(error => { dialog.showErrorBox('Savenest could not start', error.message); app.exit(1); });
}

async function start() {
  if (process.platform !== 'darwin') throw new Error('Savenest currently requires macOS 14 or later.');
  app.dock?.hide();
  session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  protocol.handle('savenest-ui', async request => {
    const name = assetName(request.url);
    if (!name || request.method !== 'GET') return new Response('Not found', { status: 404 });
    const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };
    const workspaceAsset = name.startsWith('workspace.');
    const policy = workspaceAsset
      ? "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https: http:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
      : "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
    return new Response(await fs.readFile(path.join(__dirname, 'renderer', name)), {
      headers: { 'Content-Type': types[path.extname(name)], 'Content-Security-Policy': policy }
    });
  });
  createLauncherWindow();
  nativeTheme.on('updated', refreshWindowMaterials);
  ipcMain.handle('savenest:command', async (event, input) => {
    if (!win || win.isDestroyed() || !trustedSender(event, win.webContents)) throw new Error('Untrusted Savenest window.');
    const request = validateCommand(input);
    if (fatalError) throw new Error(fatalError);
    if (['readerCurrent', 'readerOpen'].includes(request.command)) return workspace.open(request);
    if (request.command === 'dismiss') { hide(true); return true; }
    if (request.command === 'view') {
      currentView = request.view;
      const area = screen.getDisplayNearestPoint(screen.getCursorScreenPoint()).workArea;
      const height = request.view === 'editor' ? 610 : 520;
      win.setSize(Math.min(760, area.width - 32), Math.min(height, area.height - 48));
      return true;
    }
    if (request.command === 'snapshot' && latestState) send({ event: 'state', state: latestState });
    if (['delete', 'close'].includes(request.command)) {
      const ids = request.ids || [];
      const eligible = latestState?.rows.filter(row => ids.includes(row.id) && (request.command === 'delete' ? row.isSaved : row.isOpen)) || [];
      if (!eligible.length) return false;
      const deleting = request.command === 'delete';
      modalDepth += 1;
      let choice;
      try { choice = await dialog.showMessageBox(win, {
        type: 'warning', message: `${deleting ? 'Delete' : 'Close'} ${eligible.length} ${deleting ? 'saved link(s)' : 'browser tab(s)'}?`,
        detail: deleting ? 'The saved notes and tags will be removed. Undo remains available until the next library change.' : 'Unsaved changes in these browser tabs may be lost.',
        buttons: ['Cancel', deleting ? 'Delete' : 'Close tabs'], defaultId: 0, cancelId: 0
      }); } finally { modalDepth -= 1; }
      if (choice.response !== 1) return false;
    }
    return native.request(request);
  });
  updater = createUpdater({ app, autoUpdater, dialog,
    release: app.isPackaged && require('../package.json').saveNestRelease === true,
    onStatus: status => {
      void native?.request({ command: 'updateStatus', ...status }).catch(() => {});
      const item = Menu.getApplicationMenu()?.getMenuItemById('check-updates');
      if (item) item.enabled = status.enabled && !['checking', 'downloading'].includes(status.updateState);
    },
    canRestart: async () => {
      if (!native || fatalError || workspace?.busy) return false;
      try { await native.request({ command: 'snapshot' }); } catch { return false; }
      return canRestartSafely({ view: currentView, state: latestState, failed: Boolean(fatalError) });
    },
    beforeInstall: () => { quitting = true; },
    onInstallError: recoverAfterInstallError
  });
  createMenu();
  const helper = app.isPackaged ? path.join(process.resourcesPath, 'SaveNest.app') : path.join(root, 'build/electron-native/SaveNest.app');
  native = new NativeClient(path.join(helper, 'Contents/MacOS/SaveNest'), { preview, readerLive });
  workspace = new ReadingWorkspace({ native, preview: preview && !readerLive, userData: app.getPath('userData'), appearance: () => latestState?.appearance || 'black', onOpen: () => hide(), onWindow: refreshWindowMaterials });
  native.on('event', message => {
    if (message.event === 'state') {
      latestState = message.state;
      refreshWindowMaterials();
      workspace.send({ event: 'appearance', appearance: latestState.appearance });
      while (callbacks.length) void command({ command: 'callback', url: callbacks.shift() });
    }
    if (message.event === 'checkForUpdates') void updater.check();
    else if (message.event === 'readerCurrent') void command({ command: 'readerCurrent' });
    else if (message.event === 'readerSource') void workspace.openSource(message.source).catch(error => send({ event: 'error', message: error.message }));
    else if (message.event === 'show') void show();
    else if (message.event === 'toggle') toggle();
    else if (message.event === 'hide') hide();
    else if (message.event === 'quit' && !quitting && !smoke) app.quit();
    else send(message);
  });
  native.on('failure', message => { if (!quitting) { fatalError = message; send({ event: 'fatal', message }); } });
  // Settings belongs to the helper; only this host can configure its updater.
  // Keep these messages outside the renderer's command allowlist.
  void native.request({ command: 'updateStatus', ...updater.status }).catch(() => {});
  await win.loadURL(APP_URL);
  if (fatalError) send({ event: 'fatal', message: fatalError });
  if (!smoke) {
    const iconPath = path.join(helper, 'Contents/Resources/AppIcon.icns');
    const icon = nativeImage.createFromPath(iconPath).resize({ width: 18, height: 18 });
    if (!icon.isEmpty()) {
      tray = new Tray(icon); tray.setToolTip('Savenest');
      tray.setContextMenu(Menu.buildFromTemplate([
        { label: 'Open Savenest', click: show },
        { label: 'Read & note current tab', click: () => void command({ command: 'readerCurrent' }) },
        { label: 'Save current tab', click: () => void command({ command: 'capture', action: 'quick' }) },
        { label: 'Save with a note…', click: () => void command({ command: 'capture', action: 'note' }) },
        { type: 'separator' },
        { label: 'Account…', click: () => void command({ command: 'account' }) },
        { label: 'Settings…', click: () => void command({ command: 'settings' }) },
        { role: 'quit' }
      ]));
    }
  }
  if (app.isPackaged) app.setAsDefaultProtocolClient('savenest');
  await show();
  if (preview && process.argv.includes('--reader') && !smoke) await workspace.open({ command: 'readerCurrent' });
  if (smoke) {
    try {
      await fs.rm(path.join(root, 'build/smoke-result.json'), { force: true });
      await require('./workspace-smoke.cjs').run({ workspace, native, root });
      // An install can close launcher windows before Squirrel reports a failure.
      // Recover the same host, then exercise the recreated UI with its live helper.
      const originalNative = native, originalWorkspace = workspace;
      quitting = true;
      win.destroy();
      await recoverAfterInstallError();
      if (native !== originalNative || workspace !== originalWorkspace || native.closed) throw new Error('Update recovery replaced or disconnected the native session.');
      await require('./smoke.cjs').run({ win, native, root, show, toggle });
      await fs.writeFile(path.join(root, 'build/smoke-result.json'), JSON.stringify({
        version: require('../package.json').version, completedAt: new Date().toISOString(),
        checks: ['workspace', 'launcher', 'native updater bridge']
      }, null, 2));
      console.log('Electron launcher and reading workspace checks passed.'); quitting = true; app.exit(0);
    }
    catch (error) { console.error(error); native.stop(); app.exit(1); }
  }
}

function createMenu() {
  const action = (label, name, accelerator) => ({ label, accelerator, click: () => void command({ command: name }) });
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: 'Savenest', submenu: [
      { role: 'about' }, { id: 'check-updates', label: 'Check & Download Updates…', enabled: updater.enabled, click: () => void updater.check() }, action('Account…', 'account'), action('Settings…', 'settings', 'Command+,'),
      { type: 'separator' }, { role: 'hide' }, { role: 'hideOthers' }, { role: 'unhide' }, { type: 'separator' }, { role: 'quit' }
    ] },
    { label: 'File', submenu: [
      { label: 'Read & note current tab', click: () => void command({ command: 'readerCurrent' }) },
      { label: 'Add link…', accelerator: 'Command+N', click: () => { show(); send({ event: 'add' }); } },
      { label: 'Save current tab', click: () => void command({ command: 'capture', action: 'quick' }) },
      { label: 'Save with a note…', click: () => void command({ command: 'capture', action: 'note' }) },
      { label: 'Save selected tabs…', click: () => void command({ command: 'capture', action: 'selected' }) },
      { label: 'Save browser window', click: () => void command({ command: 'capture', action: 'window' }) },
      { type: 'separator' }, action('Import backup…', 'import'), action('Export backup…', 'export'), { role: 'close' }
    ] },
    { label: 'Edit', submenu: [{ role: 'undo' }, { role: 'redo' }, { type: 'separator' }, { role: 'cut' }, { role: 'copy' }, { role: 'paste' }, { role: 'selectAll' }, action('Undo library change', 'undo', 'Command+Shift+Z')] },
    { label: 'View', submenu: [
      { label: 'Search', accelerator: 'Command+F', click: () => { if (workspace?.window?.isFocused()) workspace.send({ event: 'find' }); else { show(); send({ event: 'focus' }); } } },
      action('Refresh tabs', 'refresh', 'Command+R'), { role: 'togglefullscreen' }
    ] },
    { label: 'Tools', submenu: [action('Manage tags…', 'tags'), action('Clean up tabs…', 'cleanup'), { label: 'Close duplicate tabs', click: () => void command({ command: 'capture', action: 'duplicates' }) }] },
    { label: 'Window', submenu: [{ role: 'minimize' }, { role: 'zoom' }, { label: 'Open Savenest', click: show }] }
  ]));
}
