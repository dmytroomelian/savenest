(function (root) {
  'use strict';
  const catalog = [
    { id: 'read-current', title: 'Read & note current tab', detail: 'Read a page beside its Obsidian note', symbol: 'reader', command: 'readerCurrent', keywords: 'read reader preview obsidian markdown notes current tab', home: true },
    { id: 'save-current', title: 'Save current tab', detail: 'Keep the page you were just viewing', symbol: 'bookmark', command: 'capture', action: 'quick', keywords: 'save bookmark capture current page', home: true },
    { id: 'save-note', title: 'Save with a note', detail: 'Capture the current tab and add a thought', symbol: 'note', command: 'capture', action: 'note', keywords: 'save note annotate current page', home: true },
    { id: 'add-link', title: 'Add a link', detail: 'Paste a URL, add notes and tags', symbol: 'plus', ui: 'add', keywords: 'new add save link url bookmark', home: true },
    { id: 'all-pages', title: 'Search all pages', detail: 'Search open tabs, saved links and browser history together', symbol: 'search', scope: 'All', keywords: 'all everything everywhere search pages' },
    { id: 'open-tabs', title: 'Search open tabs', detail: 'Switch to a page already open in a browser', symbol: 'tabs', scope: 'Open', keywords: 'tabs open windows switch browser' },
    { id: 'saved-links', title: 'Search saved links', detail: 'Your bookmarks, notes and tags', symbol: 'bookmark', scope: 'Saved', keywords: 'saved library bookmarks find' },
    { id: 'browser-history', title: 'Search browser history', detail: 'Find a page you visited in the last 90 days', symbol: 'history', scope: 'History', keywords: 'history visited recent browser past closed' },
    { id: 'favorites', title: 'Search favorites', detail: 'The links you starred', symbol: 'star', scope: 'Favorites', keywords: 'favorites starred pinned' },
    { id: 'notes', title: 'Search notes', detail: 'Find a thought attached to a link', symbol: 'note', scope: 'Notes', keywords: 'notes annotations thoughts' },
    { id: 'archive', title: 'Search archive', detail: 'Links tucked away for later', symbol: 'archive', scope: 'Archive', keywords: 'archived archive restore' },
    { id: 'save-selected', title: 'Save selected browser tabs', detail: 'Choose tabs from your browser window', symbol: 'tabs', command: 'capture', action: 'selected', keywords: 'save selected bulk tabs' },
    { id: 'save-window', title: 'Save all tabs in the current window', detail: 'Keep a whole browsing session', symbol: 'tabs', command: 'capture', action: 'window', keywords: 'save all window bulk tabs' },
    { id: 'close-duplicates', title: 'Close duplicate tabs', detail: 'Keep one copy of each page in every browser window', symbol: 'tabs', command: 'capture', action: 'duplicates', keywords: 'duplicates duplicate repeated close tabs' },
    { id: 'clipboard', title: 'Save copied link', detail: 'Save a URL from your clipboard', symbol: 'copy', command: 'saveClipboard', keywords: 'clipboard paste copied save link' },
    { id: 'history-sources', title: 'Browser history sources', detail: 'History access, connected profiles and privacy', symbol: 'history', ui: 'sources', keywords: 'history sources privacy access permission pause enable disable' },
    { id: 'settings', title: 'Settings', detail: 'Appearance, shortcuts and capture preferences', symbol: 'settings', command: 'settings', keywords: 'settings preferences hotkey keyboard shortcut theme appearance' },
    { id: 'shortcuts', title: 'Keyboard shortcuts', detail: 'Learn launcher keys and see your capture shortcuts', symbol: 'keyboard', ui: 'shortcuts', keywords: 'keyboard shortcuts keys help learn hotkeys' },
    { id: 'account', title: 'Account & Cloud', detail: 'Optional Cloud backup · Account and billing', symbol: 'account', command: 'account', keywords: 'account billing sign in login subscription payment' },
    { id: 'tags', title: 'Manage tags', detail: 'Rename or remove tags across your library', symbol: 'tag', command: 'tags', keywords: 'tags rename remove organize' },
    { id: 'refresh', title: 'Refresh tabs and history', detail: 'Read the latest browser state', symbol: 'refresh', command: 'refresh', keywords: 'refresh reload rescan sync' },
    { id: 'export', title: 'Export saved links', detail: 'Save a JSON backup of your library', symbol: 'export', command: 'export', keywords: 'export backup library' },
    { id: 'import', title: 'Import saved links', detail: 'Merge a SaveNest backup', symbol: 'import', command: 'import', keywords: 'import backup restore library' },
    { id: 'cleanup', title: 'Clean up browser tabs', detail: 'Review tabs from your cleanup websites', symbol: 'tabs', command: 'cleanup', keywords: 'cleanup clean close websites tabs' },
    { id: 'undo', title: 'Undo last library change', detail: 'Restore the previous saved-library state', symbol: 'undo', command: 'undo', keywords: 'undo revert restore last' }
  ];
  function folded(value) { return value.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().trim(); }
  function detectedURL(raw) {
    const value = raw.trim();
    if (!value || /\s/.test(value) || value.length > 16384) return null;
    const explicit = /^[a-z][a-z\d+.-]*:/i.test(value);
    if (!explicit && !/^[\w-]+(?:\.[\w-]+)+(?:[:/?#].*)?$/.test(value)) return null;
    try { const url = new URL(explicit ? value : 'https://' + value); return ['http:', 'https:'].includes(url.protocol) && url.hostname && !url.username && !url.password ? url.href : null; }
    catch { return null; }
  }
  function commands(query, state = {}) {
    const term = folded(query), words = term.split(/\s+/).filter(Boolean);
    const result = catalog.filter(item => item.id !== 'undo' || state.canUndo).map((item, index) => {
      if (!term) return item.home ? { ...item, rank: 100 - index } : null;
      const title = folded(item.title), haystack = title + ' ' + item.keywords;
      if (!words.every(word => haystack.includes(word))) return null;
      return { ...item, rank: (title === term ? 100 : title.startsWith(term) ? 60 : 20) - index / 100 };
    }).filter(Boolean).sort((a, b) => b.rank - a.rank);
    const url = detectedURL(query);
    if (url) result.unshift({ id: 'save-url', title: 'Save this link', detail: url, symbol: 'bookmark', ui: 'add', url, rank: 200 });
    return result.map(item => ({ ...item, id: 'command:' + item.id, kind: 'command' }));
  }
  function rows(state, query) {
    const commandsFound = state.scope === 'All' ? commands(query, state) : [];
    return [...commandsFound, ...(state.rows || []).map(item => ({ ...item, kind: 'page' }))];
  }
  function actionCatalog(state = {}) {
    const groups = ['SaveNest', 'Search', 'Save & read', 'Library'];
    const keys = { settings: '⌘,', shortcuts: '⌘/', 'add-link': '⌘N', refresh: '⌘R' };
    return catalog.filter(item => item.id !== 'undo' || state.canUndo).map(item => ({
      ...item, id: 'command:' + item.id, kind: 'command', key: keys[item.id] || '',
      group: ['settings', 'shortcuts', 'account'].includes(item.id) ? 'SaveNest' : item.scope ? 'Search'
        : item.home || item.command === 'capture' || item.command === 'saveClipboard' ? 'Save & read' : 'Library'
    })).sort((a, b) => groups.indexOf(a.group) - groups.indexOf(b.group)
      || (a.scope === 'Saved' ? -1 : b.scope === 'Saved' ? 1 : 0));
  }
  function primaryLabel(item) { return !item ? 'Open' : item.kind === 'command' ? (item.ui === 'add' || item.command === 'capture' ? 'Continue' : 'Run command') : item.isOpen ? 'Switch to tab' : 'Open link'; }
  const api = { catalog, commands, detectedURL, rows, primaryLabel, actionCatalog };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.LauncherModel = api;
})(globalThis);
