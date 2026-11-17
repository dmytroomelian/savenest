'use strict';
const $ = id => document.getElementById(id);
const model = window.LauncherModel;
const scopes = ['All', 'Open', 'Saved', 'History', 'Favorites', 'Notes', 'Archive'];
let state = { rows: [], query: '', scope: 'All', tags: [], loading: true, historySources: [] };
let items = [], focusedID = null, selected = new Set(), route = 'root', pendingQuery = null, searchTimer;
let editingID = null, editingRevision = null, captureID = null, editorBaseline = '', editorSaving = false, lastCaptureID = null, lastSelectionID = null;
let captureSelected = new Set(), selectionSaving = false, actionItems = [], filteredActions = [], actionIndex = 0, fatal = false;
let activity;
let lastNativeMessage = '', noticeSource = '', discardAction = null;
let shortcutReturnFocus = null;
let featuresReturnFocus = null;
let selectionAnchorID = null, rangeSelectionBase = null;
const pageShortcuts = {
  select: { key: ' ', shift: true, label: '⇧Space' },
  selectAll: { key: 'a', meta: true, shift: true, label: '⇧⌘A' },
  readerOpen: { key: 'Enter', meta: true, label: '⌘↵' },
  save: { key: 's', meta: true, label: '⌘S' },
  edit: { key: 'e', meta: true, label: '⌘E' },
  copy: { key: 'c', meta: true, shift: true, label: '⇧⌘C' },
  favorite: { key: 'f', meta: true, shift: true, label: '⇧⌘F' },
  archive: { key: 'e', meta: true, shift: true, label: '⇧⌘E' },
  delete: { key: 'Backspace', meta: true, label: '⌘⌫' },
  undo: { key: 'z', meta: true, alt: true, label: '⌥⌘Z' }
};
function matchesShortcut(event, shortcut) {
  return shortcut && (event.key.toLowerCase() === shortcut.key.toLowerCase()
    || (shortcut.alt && event.code === 'Key' + shortcut.key.toUpperCase()))
    && event.metaKey === Boolean(shortcut.meta) && event.shiftKey === Boolean(shortcut.shift)
    && event.altKey === Boolean(shortcut.alt) && event.ctrlKey === Boolean(shortcut.ctrl);
}
const symbols = {
  keyboard: 'M3 6h18v12H3zM6 9h.01M9 9h.01M12 9h.01M15 9h.01M18 9h.01M6 12h.01M9 12h.01M12 12h.01M15 12h.01M18 12h.01M8 15h8',
  reader: 'M3 4h18v16H3zM13 4v16M6 8h4M6 12h4M16 8h2M16 12h2',
  nest: 'M4 8l8 5 8-5M4 13l8 5 8-5M6 18l6 4 6-4M9 4l3 2 3-2',
  bookmark: 'M6 3h12v18l-6-4-6 4z', note: 'M5 3h14v18H5zM8 8h8M8 12h8M8 16h5',
  tabs: 'M3 7h18v14H3zM6 3h12M3 11h18', plus: 'M12 5v14M5 12h14',
  history: 'M3 11a9 9 0 1 1 2 7M3 4v7h7M12 7v6l4 2', star: 'M12 3l3 6 7 1-5 5 1 7-6-3-6 3 1-7-5-5 7-1z',
  archive: 'M3 3h18v5H3zM5 8v13h14V8M10 12h4', copy: 'M8 8h13v13H8zM3 16V3h13',
  settings: 'M12 3v3M12 18v3M3 12h3M18 12h3M5.6 5.6l2 2M16.4 16.4l2 2M5.6 18.4l2-2M16.4 7.6l2-2M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8',
  account: 'M12 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8M4 21v-2a8 8 0 0 1 16 0v2',
  tag: 'M3 3h9l9 9-9 9-9-9zM8 8h.01', refresh: 'M3 11a9 9 0 0 1 16-5l2 3M21 3v6h-6M21 13a9 9 0 0 1-16 5l-2-3M3 21v-6h6',
  export: 'M12 16V3M7 8l5-5 5 5M4 14v7h16v-7', import: 'M12 3v13M7 11l5 5 5-5M4 16v5h16v-5',
  undo: 'M3 10h10a7 7 0 0 1 7 7M3 10l6-6M3 10l6 6', search: 'M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14M15 15l6 6',
  compass: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M15.5 8.5l-2 5-5 2 2-5z',
  globe: 'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0M3 12h18M12 3c-5 5-5 13 0 18M12 3c5 5 5 13 0 18',
  activity: 'M4 5h16v16H4zM4 10h16M9 3v4M15 3v4M8 14h2M12 14h2M16 14h2M8 17h2M12 17h2'
};
function el(tag, className, text) {
  const node = document.createElement(tag); if (className) node.className = className;
  if (text !== undefined) node.textContent = text; return node;
}
function icon(name) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  for (const [key, value] of Object.entries({ viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.6', 'stroke-linecap': 'round', 'stroke-linejoin': 'round', 'aria-hidden': 'true' })) svg.setAttribute(key, value);
  const path = document.createElementNS(svg.namespaceURI, 'path'); path.setAttribute('d', symbols[name] || symbols.bookmark); svg.append(path); return svg;
}
const siteIcons = new Map();
const iconObserver = typeof IntersectionObserver === 'function' ? new IntersectionObserver(entries => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    const tile = entry.target;
    iconObserver.unobserve(tile);
    const url = tile.dataset.url;
    if (!siteIcons.has(url)) {
      if (siteIcons.size >= 512) siteIcons.delete(siteIcons.keys().next().value);
      siteIcons.set(url, window.savenest.command({ command: 'siteIcon', url }).catch(() => null));
    }
    void siteIcons.get(url).then(result => {
      if (!tile.isConnected || !result?.dataURL?.startsWith('data:image/png;base64,')) return;
      const image = el('img'); image.alt = ''; image.src = result.dataURL;
      image.onload = () => tile.replaceChildren(image);
    });
  }
}) : { observe() {}, unobserve() {}, disconnect() {} };
function pageIcon(tile, item) {
  tile.append(icon('globe')); tile.dataset.url = item.url;
  tile.setAttribute('aria-hidden', 'true'); iconObserver.observe(tile);
}
$('nest-mark').append(icon('nest'));
activity = window.SavenestActivity ? window.SavenestActivity.create({ command: request => window.savenest.command(request) }) : null;
function notice(message, error = false, source = 'local') {
  noticeSource = source; $('notice-text').textContent = message; $('notice').dataset.error = String(error); $('notice').hidden = !message;
}
async function run(command, values = {}) {
  try { return await window.savenest.command({ command, ...values }); }
  catch (error) { notice(cleanError(error), true); return false; }
}
function cleanError(error) { return error.message.replace(/^Error invoking remote method '[^']+': Error: /, ''); }
function focusSearch() { if (route === 'root' && !document.querySelector('dialog[open]')) $('search').focus(); }
function current() { return items.find(item => item.id === focusedID); }
function chosen() { return selected.size ? items.filter(item => item.kind === 'page' && selected.has(item.id)) : current() ? [current()] : []; }
function clearSelection() {
  selected.clear(); selectionAnchorID = null; rangeSelectionBase = null; updateSelection();
}
function toggleSelection(item = current()) {
  if (item?.kind !== 'page') return;
  selected.has(item.id) ? selected.delete(item.id) : selected.add(item.id);
  focusedID = item.id; selectionAnchorID = item.id; rangeSelectionBase = null; updateSelection();
}
function selectAllPages() {
  selected = new Set(items.filter(item => item.kind === 'page').map(item => item.id));
  selectionAnchorID = null; rangeSelectionBase = null; updateSelection();
}
function selectRange(id) {
  if (!rangeSelectionBase) {
    rangeSelectionBase = new Set(selected);
    selectionAnchorID = selectionAnchorID || focusedID || id;
  }
  const anchor = items.findIndex(item => item.id === selectionAnchorID), end = items.findIndex(item => item.id === id);
  selected = new Set(rangeSelectionBase);
  for (const item of items.slice(Math.max(0, Math.min(anchor, end)), Math.max(anchor, end) + 1)) {
    if (item.kind === 'page') selected.add(item.id);
  }
  focusedID = id; updateSelection(true);
}
function changeQuery(query, scope = state.scope) {
  clearTimeout(searchTimer); $('search').value = query; pendingQuery = query; focusedID = null; clearSelection();
  void run('search', { query, scope });
}
function setScope(scope) { state.scope = scope; changeQuery('', scope); renderRoot(); focusSearch(); }
function activityAvailable() {
  return !fatal && route !== 'editor' && route !== 'selection' && !state.captureDraft && !state.captureSelection;
}
function openActivity() {
  if (!activity || !activityAvailable() || route === 'activity') return;
  $('route-title').textContent = 'Activity';
  setRoute('activity');
  activity.open();
  $('route-back').focus();
}
function setRoute(value) {
  if (route === 'activity' && value !== 'activity' && activity) activity.close();
  route = value; document.body.dataset.view = value;
  $('search-header').hidden = value !== 'root'; $('route-header').hidden = value === 'root';
  for (const name of ['root', 'editor', 'sources', 'selection', 'activity']) $(name + '-view').hidden = value !== name;
  $('onboarding').hidden = value !== 'root' || !state.onboarding;
  $('usage-notice').hidden = value !== 'root' || !state.showUsageNotice;
  $('actions').hidden = value !== 'root';
  document.querySelector('.separator').hidden = value !== 'root';
  void run('view', { view: value }); updateFooter();
}
function formValues() { return { url: $('edit-url').value, title: $('edit-title').value, note: $('edit-note').value, tags: $('edit-tags').value }; }
function dirty() { return JSON.stringify(formValues()) !== editorBaseline; }
function openEditor(row = null, captured = false, url = '') {
  if (route === 'editor') { notice('Finish this draft before starting another.'); return; }
  if (route === 'activity') activity?.close();
  editingID = captured ? null : row?.id || null; captureID = captured ? row.id : null;
  editingRevision = row?.revision || 'missing';
  $('route-title').textContent = captured ? 'Save current tab with a note' : row ? 'Edit link' : 'Save a link';
  $('edit-url').value = row?.url || url; $('edit-url').readOnly = Boolean(row);
  $('edit-title').value = row?.title || ''; $('edit-note').value = row?.note || '';
  $('edit-tags').value = row?.tags?.join(', ') || ''; $('editor-error').textContent = '';
  editorBaseline = JSON.stringify(formValues()); editorSaving = false;
  setRoute('editor'); requestAnimationFrame(() => $(row || url ? 'edit-note' : 'edit-url').focus());
}
async function leaveEditor() {
  if (captureID) await run('cancelDraft'); captureID = null; editingID = null;
  setRoute('root'); renderRoot(); focusSearch();
}
function back() {
  if ($('action-dialog').open) { $('action-dialog').close(); return; }
  if (route === 'activity') { activity?.close(); setRoute('root'); renderRoot(); focusSearch(); }
  else if (route === 'editor') {
    if (editorSaving) return;
    if (dirty()) { discardAction = leaveEditor; $('discard-dialog').showModal(); }
    else void leaveEditor();
  } else if (route === 'selection') {
    if (selectionSaving) return;
    void run('cancelSelection'); setRoute('root'); focusSearch();
  }
  else if (route !== 'root') { setRoute('root'); renderRoot(); focusSearch(); }
  else if (selected.size) clearSelection();
  else if (state.scope !== 'All') setScope('All');
  else void run('dismiss');
}
function relativeVisit(value) {
  if (!value) return '';
  const minutes = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 60000));
  if (minutes < 60) return minutes < 2 ? 'Just visited' : `${minutes}m ago`;
  const hours = Math.floor(minutes / 60); return hours < 24 ? `${hours}h ago` : `${Math.floor(hours / 24)}d ago`;
}
function updateSyncStatus() {
  const sync = state.syncStatus;
  const visible = !fatal && !state.shortcutError && typeof sync?.label === 'string' && sync.label.length > 0
    && ['checking', 'active', 'offline', 'attention', 'restoring'].includes(sync.state);
  $('sync-status').hidden = !visible;
  $('status').hidden = visible;
  document.querySelector('.footer-mark').hidden = visible;
  if (visible) {
    $('sync-status').dataset.state = sync.state;
    if ($('sync-label').textContent !== sync.label) $('sync-label').textContent = sync.label;
  } else {
    delete $('sync-status').dataset.state;
    $('sync-label').textContent = '';
  }
}
function updateFooter() {
  updateSyncStatus();
  $('open-settings').disabled = fatal;
  $('shortcut-settings').disabled = fatal;
  $('open-activity').disabled = !activityAvailable();
  $('primary').disabled = fatal || editorSaving || state.busy || (route === 'root' && !current());
  if (route === 'activity') {
    $('primary').disabled = fatal;
    $('primary').replaceChildren(el('span', '', 'Back to search'), el('kbd', '', 'esc'));
    return;
  }
  if (route === 'editor') { $('primary').replaceChildren(el('span', '', editorSaving ? 'Saving…' : 'Save link'), el('kbd', '', '⌘↵')); return; }
  if (route === 'selection') { $('primary').replaceChildren(el('span', '', selectionSaving ? 'Saving…' : `Save ${captureSelected.size} tabs`), el('kbd', '', '⌘↵')); $('primary').disabled = fatal || selectionSaving || !captureSelected.size; return; }
  if (route === 'sources') { $('primary').replaceChildren(el('span', '', 'Back to search'), el('kbd', '', 'esc')); return; }
  $('primary').replaceChildren(el('span', '', model.primaryLabel(current())), el('kbd', '', '↵'));
  $('actions').replaceChildren(el('span', '', selected.size ? `Actions · ${selected.size}` : 'Actions'), el('kbd', '', '⌘K'));
  $('actions').disabled = fatal;
  $('selection-bar').hidden = !items.some(item => item.kind === 'page');
  $('selection-count').textContent = selected.size ? `${selected.size} selected` : '↑ ↓ to move';
  $('toggle-selection').hidden = current()?.kind !== 'page';
  $('toggle-selection').replaceChildren(el('span', '', selected.has(focusedID) ? 'Deselect link' : 'Select link'), el('kbd', '', pageShortcuts.select.label));
  $('clear-selection').hidden = !selected.size;
  $('select-all').disabled = fatal;
  $('toggle-selection').disabled = fatal;
}
function updateSelection(scroll = false) {
  for (const node of document.querySelectorAll('.row')) {
    const active = node.dataset.id === focusedID; node.classList.toggle('selected', active);
    node.classList.toggle('checked', selected.has(node.dataset.id));
    node.setAttribute('aria-selected', String(selected.size ? selected.has(node.dataset.id) : active));
    if (node.querySelector('.row-check')) node.querySelector('.row-check').checked = selected.has(node.dataset.id);
    if (active) { $('search').setAttribute('aria-activedescendant', node.id); if (scroll) node.scrollIntoView({ block: 'nearest' }); }
  }
  if (!focusedID) $('search').removeAttribute('aria-activedescendant');
  updateFooter();
}
function navigate(offset, extend = false) {
  if (!items.length) return;
  const index = items.findIndex(item => item.id === focusedID);
  const id = items[Math.max(0, Math.min(items.length - 1, index + offset))].id;
  if (extend) selectRange(id);
  else { focusedID = id; selectionAnchorID = id; rangeSelectionBase = null; updateSelection(true); }
}
function renderRoot() {
  const query = $('search').value;
  const ready = (state.resultsQuery ?? state.query) === query && (state.resultsScope ?? state.scope) === state.scope;
  const previousIndex = Math.max(0, items.findIndex(item => item.id === focusedID));
  items = model.rows({ ...state, canOpenActivity: activityAvailable(), rows: ready ? state.rows : [] }, query);
  const valid = new Set(items.map(item => item.id)); selected = new Set([...selected].filter(id => valid.has(id)));
  if (!valid.has(selectionAnchorID)) { selectionAnchorID = null; rangeSelectionBase = null; }
  if (rangeSelectionBase) rangeSelectionBase = new Set([...rangeSelectionBase].filter(id => valid.has(id)));
  if (!valid.has(focusedID)) focusedID = items[Math.min(previousIndex, items.length - 1)]?.id || null;
  $('scope').value = state.scope; $('back').hidden = state.scope === 'All'; $('nest-mark').hidden = state.scope !== 'All';
  $('search').placeholder = { All: 'Search tabs, saved links, history, or commands…', Open: 'Search open browser tabs…', Saved: 'Search saved links, notes, or #tags…', History: 'Search pages you visited…', Favorites: 'Search favorites…', Notes: 'Search notes…', Archive: 'Search archived links…' }[state.scope];
  iconObserver.disconnect();
  const nodes = []; let group = '';
  items.forEach((item, index) => {
    const next = item.kind === 'command' ? (query ? 'Commands' : 'Quick actions') : query ? 'Matching pages' : state.scope === 'History' ? 'Recently visited' : state.scope === 'All' ? 'Open tabs & recent links' : state.scope;
    if (next !== group) { nodes.push(el('div', 'group-label', next)); group = next; }
    const row = el('div', 'row'); row.id = 'result-' + index; row.dataset.id = item.id; row.dataset.kind = item.kind; row.setAttribute('role', 'option');
    const tile = el('span', 'row-icon' + (item.kind === 'page' ? ' page-icon' : ''));
    if (item.kind === 'command') tile.append(icon(item.symbol)); else pageIcon(tile, item);
    const text = el('div', 'row-text'), title = el('div', 'row-title', item.title);
    if (item.favorite) title.append(el('span', 'star', '★'));
    let detail = item.detail;
    if (item.kind === 'page') detail = [item.domain, item.isOpen ? item.browser : item.isHistory ? relativeVisit(item.lastVisited) : '', item.note || (item.tags?.length ? '#' + item.tags.join(' · #') : '')].filter(Boolean).join(' · ');
    text.append(title, el('div', 'row-meta', detail)); row.append(tile, text);
    const accessory = el('div', 'row-accessory');
    if (item.kind === 'page') {
      if (item.isOpen) accessory.append(el('span', 'source-label open', 'Open'));
      if (item.isSaved) accessory.append(el('span', 'source-label', item.archived ? 'Archived' : 'Saved'));
      if (item.isHistory && !item.isOpen && !item.isSaved) accessory.append(el('span', 'source-label', 'History'));
      const check = el('input', 'row-check'); check.type = 'checkbox'; check.setAttribute('aria-label', 'Select ' + item.title); check.tabIndex = -1;
      check.onclick = event => event.stopPropagation();
      check.title = 'Select link (⇧Space)';
      check.onchange = () => { toggleSelection(item); focusSearch(); };
      accessory.append(check);
      const read = el('button', 'row-read'); read.append(icon('reader')); read.title = 'Read & note (⌘↵)'; read.setAttribute('aria-label', 'Read & note: ' + item.title);
      read.onclick = event => { event.stopPropagation(); void run('readerOpen', { ids: [item.id] }); };
      read.ondblclick = event => event.stopPropagation();
      accessory.append(read);
    } else accessory.append(el('span', 'source-label', 'Command'));
    if (index < 9) accessory.append(el('kbd', '', '⌘' + (index + 1)));
    const more = el('button', 'row-more', '⋯'); more.setAttribute('aria-label', 'Actions for ' + item.title); more.tabIndex = -1;
    more.onclick = event => { event.stopPropagation(); if (!selected.has(item.id)) clearSelection(); focusedID = item.id; updateSelection(); showActions(); };
    accessory.append(more); row.append(accessory);
    row.onclick = event => {
      if (event.shiftKey && item.kind === 'page') selectRange(item.id);
      else if (event.metaKey && item.kind === 'page') toggleSelection(item);
      else { clearSelection(); focusedID = item.id; selectionAnchorID = item.id; updateSelection(); }
      focusSearch();
    };
    row.ondblclick = event => { if (!event.metaKey && !event.shiftKey) void execute(item); };
    row.oncontextmenu = event => { event.preventDefault(); if (!selected.has(item.id)) clearSelection(); focusedID = item.id; updateSelection(); showActions(); };
    nodes.push(row);
  });
  $('results').replaceChildren(...nodes); $('results').setAttribute('aria-busy', String(state.loading || state.loadingHistory));
  if (!items.length) {
    const empty = el('div', 'empty'); const paused = state.scope === 'History' && !state.historyEnabled;
    empty.append(icon(paused ? 'history' : 'search'), el('h2', '', paused ? 'History search is paused' : state.loading || state.loadingHistory ? 'Gathering your pages…' : 'No matching pages'), el('p', '', paused ? 'Enable local history search to find pages you visited.' : state.scope === 'History' ? 'Try another search or check which browser histories Savenest can read.' : 'Try a title, website, word from a note, or #tag.'));
    if (state.scope === 'History') { const sources = el('button', '', 'Browser history sources'); sources.onclick = openSources; empty.append(sources); }
    $('results').append(empty);
  }
  updateSelection();
}
function renderSources() {
  $('history-enabled').checked = Boolean(state.historyEnabled);
  const nodes = (state.historySources || []).map(source => {
    const row = el('div', 'source'), detail = el('div');
    detail.append(el('strong', '', `${source.browser} · ${source.profile}`), el('p', '', source.issue || 'Local history available'));
    row.append(icon('history'), detail, el('span', 'source-count', source.issue ? 'Needs access' : `${source.count} pages`)); return row;
  });
  if (!nodes.length) nodes.push(el('p', 'subtle', state.preview ? 'Preview uses sample visits. Your browser history is not read.' : !state.historyEnabled ? 'History is paused and cleared from Savenest’s memory.' : state.loadingHistory ? 'Checking local browser profiles…' : 'No readable history found. Open a supported browser, then refresh.'));
  $('sources').replaceChildren(...nodes); $('history-refresh').disabled = state.loadingHistory || !state.historyEnabled;
}
function openSources() { $('route-title').textContent = 'Browser history sources'; setRoute('sources'); renderSources(); $('history-enabled').focus(); }
function renderState() {
  document.documentElement.dataset.appearance = state.appearance || 'black'; $('preview').hidden = !state.preview; $('preview').textContent = state.notesStatus?.readerTest ? 'Reader test' : 'Preview';
  if (pendingQuery === state.query) pendingQuery = null;
  if (pendingQuery === null && $('search').value !== state.query) $('search').value = state.query;
  $('onboarding').hidden = route !== 'root' || !state.onboarding;
  $('usage-notice').hidden = route !== 'root' || !state.showUsageNotice;
  $('usage-notice-text').textContent = state.preview ? 'Preview: reporting is disabled. The app shares anonymous usage counts by default, with no saved content or account/device IDs.' : 'Anonymous usage counts are on. No saved content, account IDs, or device IDs are sent.';
  const total = state.totalCount > 200 ? `${state.totalCount} matches · refine your search` : `${state.openCount || 0} open · ${state.savedCount || 0} saved · ${state.historyCount || 0} history`;
  $('status').textContent = state.shortcutError ? 'Shortcut unavailable · open Settings' : state.loadingHistory ? 'Reading local history…' : state.loading ? 'Refreshing tabs…' : total;
  $('home').title = `${state.launcherShortcut || '⌘O'} opens Savenest · History stays on this Mac`;
  $('home').setAttribute('aria-label', state.shortcutError ? 'Open Settings to fix the launcher shortcut' : 'Back to root search');
  if ($('shortcuts-dialog').open) renderShortcuts();
  if ($('features-dialog').open) renderFeatures(true);
  if (state.message !== lastNativeMessage) {
    lastNativeMessage = state.message;
    if (state.message) notice(state.message, state.error, 'native');
    else if (noticeSource === 'native') $('notice').hidden = true;
  }
  renderRoot(); if (route === 'sources') renderSources();
  if ($('action-dialog').open) {
    const activeAction = filteredActions[actionIndex]?.id;
    actionItems = availableActions(); renderActions();
    const nextIndex = filteredActions.findIndex(item => item.id === activeAction);
    if (nextIndex >= 0) { actionIndex = nextIndex; renderActions(); }
  }
  if (state.captureDraft && state.captureDraft.id !== lastCaptureID && (route === 'root' || route === 'activity')) {
    lastCaptureID = state.captureDraft.id; openEditor(state.captureDraft, true);
  }
  if (state.captureSelection && state.captureSelection.id !== lastSelectionID && (route === 'root' || route === 'activity')) {
    if (route === 'activity') activity?.close();
    lastSelectionID = state.captureSelection.id; captureSelected = new Set(state.captureSelection.links.map(link => link.id));
    $('route-title').textContent = 'Save selected browser tabs';
    $('capture-tabs').replaceChildren(...state.captureSelection.links.map(link => {
      const label = el('label', 'capture-tab'), check = el('input'); check.type = 'checkbox'; check.checked = true;
      check.onchange = () => { check.checked ? captureSelected.add(link.id) : captureSelected.delete(link.id); updateFooter(); };
      const text = el('span'); text.append(el('strong', '', link.title), el('small', '', new URL(link.url).hostname)); label.append(check, text); return label;
    }));
    setRoute('selection');
  }
  updateFooter();
}
async function execute(item) {
  if (!item || fatal) return;
  if (item.kind === 'page') { await run('open', { ids: [item.id] }); return; }
  if (item.ui === 'add') openEditor(null, false, item.url || '');
  else if (item.ui === 'sources') openSources();
  else if (item.ui === 'shortcuts') showShortcuts();
  else if (item.ui === 'features') showFeatures();
  else if (item.ui === 'activity') openActivity();
  else if (item.scope) setScope(item.scope);
  else if (item.command) await run(item.command, item.action ? { action: item.action } : {});
}
function availableActions() {
  const rows = chosen(), single = rows.length === 1;
  $('actions-context').textContent = single ? rows[0].title : rows.length ? `${rows.length} selected pages` : 'All Savenest actions';
  const actions = [];
  const group = single ? 'Selected page' : 'Selected pages';
  const add = (title, command, targets, shortcut = pageShortcuts[command], danger = false) => {
    if (targets.length) actions.push({ id: 'context:' + command, group, title, shortcut, key: shortcut?.label || '', danger,
      run: () => run(command, { ids: targets.map(row => row.id) }) });
  };
  if (single && rows[0].kind === 'command') actions.push({ id: 'context:run', group: 'Selected command', title: 'Run command', key: '↵', run: () => execute(rows[0]) });
  else {
    if (single) add(rows[0].isOpen ? 'Switch to tab' : 'Open link', 'open', rows, { key: 'Enter', label: '↵' });
    if (single) add('Read & note', 'readerOpen', rows);
    add('Save to library', 'save', rows.filter(row => !row.isSaved));
    if (single) actions.push({ id: 'context:edit', group, title: 'Edit title, note & tags', shortcut: pageShortcuts.edit, key: pageShortcuts.edit.label, run: () => openEditor(rows[0]) });
    add(single ? 'Copy URL' : 'Copy URLs', 'copy', rows);
    add('Save & close tabs', 'saveClose', rows.filter(row => row.isOpen));
    const saved = rows.filter(row => row.isSaved), unarchived = saved.filter(row => !row.archived);
    add(saved.every(row => row.favorite) ? 'Remove from favorites' : 'Mark as favorite', 'favorite', saved);
    add(single ? 'Archive link' : 'Archive saved links', 'archive', unarchived);
    add(single ? 'Restore from archive' : 'Restore saved links', 'restore', saved.filter(row => row.archived), unarchived.length ? null : pageShortcuts.archive);
    if (single) add('Email link…', 'share', rows.filter(row => row.isSaved));
    add('Close browser tabs…', 'close', rows.filter(row => row.isOpen), null, true);
    add(single ? 'Delete saved link…' : 'Delete saved links…', 'delete', saved, pageShortcuts.delete, true);
  }
  const selectionAction = (id, title, shortcut, perform) => actions.push({ id: 'selection:' + id, group: 'Selection', title, shortcut, key: shortcut?.label || '', run: perform });
  if (current()?.kind === 'page') selectionAction('toggle', selected.has(focusedID) ? 'Deselect link' : 'Select link', pageShortcuts.select, () => toggleSelection());
  if (items.some(item => item.kind === 'page')) selectionAction('all', 'Select all visible links', pageShortcuts.selectAll, selectAllPages);
  if (selected.size) selectionAction('clear', 'Clear selection', null, clearSelection);
  for (const item of model.actionCatalog({ ...state, canOpenActivity: activityAvailable() })) actions.push({ ...item, shortcut: item.command === 'undo' ? pageShortcuts.undo : undefined, run: () => execute(item) });
  return actions;
}
function showActions() {
  if (route !== 'root' || fatal) return;
  actionItems = availableActions();
  $('action-search').value = ''; actionIndex = 0; renderActions();
  if (!$('action-dialog').open) $('action-dialog').showModal();
  $('action-search').focus();
}
function renderActions() {
  const words = $('action-search').value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  filteredActions = actionItems.filter(item => words.every(word => `${item.title} ${item.keywords || ''} ${item.group}`.toLowerCase().includes(word)));
  actionIndex = Math.min(actionIndex, Math.max(0, filteredActions.length - 1));
  const nodes = []; let group = '';
  filteredActions.forEach((item, index) => {
    if (item.group !== group) { nodes.push(el('div', 'action-group', item.group)); group = item.group; }
    const button = el('button', `${item.danger ? 'danger ' : ''}${index === actionIndex ? 'active' : ''}`);
    button.type = 'button'; button.dataset.actionId = item.id;
    const label = el('span', 'action-label');
    if (item.symbol) label.append(icon(item.symbol));
    label.append(el('span', 'action-title', item.title)); button.append(label);
    if (item.key) button.append(el('kbd', '', item.key));
    button.onclick = () => { $('action-dialog').close(); void item.run(); }; nodes.push(button);
  });
  if (!nodes.length) nodes.push(el('p', 'action-empty', 'No matching actions. Try “saved”, “settings”, or “shortcuts”.'));
  $('action-options').replaceChildren(...nodes);
}
function renderShortcuts() {
  const groups = [
    ['In the launcher', [
      ['Open Actions', '⌘K'], ['Keyboard shortcuts', '⌘/'], ['Open Settings', '⌘,'],
      ['Move between results', '↑ ↓'], ['Open or run a result', '↵'], ['Run result 1–9', '⌘1–9'],
      ['Next / previous search scope', '⌃Tab / ⌃⇧Tab'], ['Focus search', '⌘F'],
      ['Add a link', '⌘N'], ['Refresh tabs and history', '⌘R'], ['Back or close', 'esc']
    ]],
    ['Select links', [
      ['Select / deselect a link', pageShortcuts.select.label], ['Select a range', '⇧↑ / ⇧↓'],
      ['Select all visible links', pageShortcuts.selectAll.label], ['Clear selection', 'esc'],
      ['Add / remove a clicked link', '⌘Click'], ['Select a clicked range', '⇧Click']
    ]],
    ['With links highlighted or selected', [
      ['Read & note one link', pageShortcuts.readerOpen.label], ['Save to library', pageShortcuts.save.label],
      ['Edit one link’s title, note and tags', pageShortcuts.edit.label], ['Copy URLs', pageShortcuts.copy.label],
      ['Mark / unmark favorite', pageShortcuts.favorite.label], ['Archive / restore saved links', pageShortcuts.archive.label],
      ['Delete saved links…', pageShortcuts.delete.label], ['Undo last library change', pageShortcuts.undo.label]
    ]],
    ['While editing a link', [['Save changes', '⌘↵']]]
  ];
  const bindings = state.shortcuts || [{ title: 'Open Savenest', key: state.launcherShortcut || '⌘O', error: state.shortcutError }];
  const nodes = [];
  for (const [title, rows] of groups) {
    nodes.push(el('h3', 'shortcut-group', title));
    for (const [label, key] of rows) { const row = el('div', 'shortcut-row'); row.append(el('span', '', label), el('kbd', '', key)); nodes.push(row); }
  }
  nodes.push(el('h3', 'shortcut-group', 'From any app'));
  if (state.preview) nodes.push(el('p', 'shortcut-note', 'Your configured shortcuts are shown below. Global shortcuts are inactive in this preview.'));
  for (const binding of bindings) {
    const row = el('div', 'shortcut-row'), text = el('span', '', binding.title);
    if (binding.error) text.append(el('small', 'error', binding.error));
    row.append(text, binding.key ? el('kbd', '', binding.key) : el('span', 'shortcut-unassigned', 'Not assigned')); nodes.push(row);
  }
  $('shortcut-list').replaceChildren(...nodes);
}
function showShortcuts() {
  shortcutReturnFocus = document.activeElement;
  if ($('action-dialog').open) $('action-dialog').close();
  renderShortcuts();
  if (!$('shortcuts-dialog').open) $('shortcuts-dialog').showModal();
  $('shortcuts-close').focus();
}
function featureBadge(label) { return el('span', 'feature-badge' + (label === 'Beta' ? ' beta' : ''), label); }
function featureActionButton(item, className = 'feature-action') {
  const button = el('button', className, item.action.label); button.type = 'button'; button.dataset.featureAction = item.id;
  button.onclick = () => { closeFeatures(); void invokeFeatureAction(item.action); };
  return button;
}
function featureKey(item) {
  if (!item.shortcut) return '';
  const binding = (state.shortcuts || []).find(entry => entry.id === item.shortcut);
  return binding && binding.assigned !== false && binding.key ? binding.key : '';
}
function featureCard(item) {
  const card = el('article', 'feature-card'); card.dataset.featureId = item.id;
  const head = el('div', 'feature-head'); head.append(el('h4', 'feature-title', item.title));
  for (const badge of item.badges || []) head.append(featureBadge(badge));
  const key = featureKey(item);
  if (key) head.append(el('span', 'feature-key', key));
  card.append(head, el('p', 'feature-description', item.description));
  if (item.action) card.append(featureActionButton(item));
  return card;
}
function socialFeatureCard(catalog) {
  const item = catalog.socialCapture, status = catalog.statusFor(state.socialCapture, state.preview);
  const card = el('article', 'feature-card social-capture'); card.dataset.featureId = item.id;
  const head = el('div', 'feature-head'); head.append(el('h4', 'feature-title', item.title));
  for (const badge of item.badges || []) head.append(featureBadge(badge));
  card.append(head, el('p', 'feature-description', item.summary));
  const points = el('ul', 'social-points');
  for (const point of item.points) points.append(el('li', '', point));
  card.append(points, el('p', 'social-evidence', item.evidence));
  const row = el('div', 'social-status-row');
  row.append(el('span', 'feature-status ' + status.tone, status.label), el('span', 'social-status-detail', status.detail));
  row.append(featureActionButton(item, 'feature-action social-cta'));
  card.append(row);
  return card;
}
function renderFeatures(preserve = false) {
  const catalog = window.FeaturesCatalog;
  if (!catalog) { $('features-list').replaceChildren(el('p', 'feature-empty', 'Feature guide unavailable.')); return; }
  const list = $('features-list');
  const focusedAction = preserve ? document.activeElement?.dataset?.featureAction : null;
  const scrollTop = preserve ? list.scrollTop : 0;
  const search = $('features-search');
  const searchFocused = document.activeElement === search;
  const selection = searchFocused ? {
    start: search.selectionStart, end: search.selectionEnd, direction: search.selectionDirection
  } : null;
  const restoreSearch = () => {
    if (document.activeElement !== search) search.focus();
    if (selection && (search.selectionStart !== selection.start || search.selectionEnd !== selection.end || search.selectionDirection !== selection.direction)) {
      search.setSelectionRange(selection.start, selection.end, selection.direction);
    }
  };
  const words = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const matches = (item, extra = '') => {
    const haystack = `${item.title} ${item.description || item.summary || ''} ${item.keywords || ''} ${(item.badges || []).join(' ')} ${extra}`.toLowerCase();
    return words.every(word => haystack.includes(word));
  };
  const nodes = []; let count = 0;
  if (matches(catalog.socialCapture, 'save from other apps beta pro')) { nodes.push(socialFeatureCard(catalog)); count += 1; }
  for (const group of catalog.groups) {
    const cards = group.items.filter(item => matches(item, group.title)).map(featureCard);
    if (!cards.length) continue;
    const section = el('section', 'feature-group'); section.setAttribute('aria-labelledby', 'feature-group-' + group.id);
    const title = el('h3', 'feature-group-title', group.title); title.id = 'feature-group-' + group.id;
    section.append(title, ...cards); nodes.push(section); count += cards.length;
  }
  if (!nodes.length) nodes.push(el('p', 'feature-empty', words.length ? 'No matching features. Try “save”, “search”, “Pro”, or “social”.' : 'No features to show.'));
  list.replaceChildren(...nodes);
  $('features-count').textContent = count ? `${count} ${count === 1 ? 'feature' : 'features'}` : '';
  list.scrollTop = preserve ? scrollTop : 0;
  if (!preserve) return;
  if (focusedAction) {
    const next = [...list.querySelectorAll('.feature-action')].find(node => node.dataset.featureAction === focusedAction);
    if (next) next.focus(); else restoreSearch();
  } else if (searchFocused) restoreSearch();
}
function showFeatures() {
  if (fatal) return;
  const catalog = window.FeaturesCatalog;
  if (!catalog) { notice('The feature guide is unavailable.', true); return; }
  featuresReturnFocus = document.activeElement;
  if ($('action-dialog').open) $('action-dialog').close();
  $('features-search').value = ''; renderFeatures();
  if (!$('features-dialog').open) $('features-dialog').showModal();
  $('features-search').focus();
}
function closeFeatures() { if ($('features-dialog').open) $('features-dialog').close(); }
async function invokeFeatureAction(action) {
  if (!action) return;
  if (action.ui === 'add') { openEditor(null, false, action.url || ''); return; }
  if (action.ui === 'shortcuts') { showShortcuts(); return; }
  if (action.scope) { setScope(action.scope); return; }
  if (action.command) await run(action.command, action.action ? { action: action.action } : {});
}
$('editor-form').onsubmit = async event => {
  event.preventDefault(); if (editorSaving) return;
  editorSaving = true; $('editor-error').textContent = ''; updateFooter();
  const values = formValues(), tags = values.tags.split(',').map(value => value.trim()).filter(Boolean);
  const dismissAfterSave = !editingID;
  try {
    const request = { title: values.title, note: values.note, tags };
    if (captureID) Object.assign(request, { command: 'saveDraft', ids: [captureID] });
    else if (editingID) Object.assign(request, { command: 'edit', ids: [editingID], revision: editingRevision });
    else Object.assign(request, { command: 'add', url: values.url });
    const ok = await window.savenest.command(request);
    if (ok) {
      editorBaseline = JSON.stringify(formValues()); captureID = null; editingID = null;
      setRoute('root'); renderRoot(); focusSearch();
      // Finish quick-add/capture flows only after persistence succeeds. Editing
      // an existing result stays in the launcher so browsing can continue.
      if (dismissAfterSave) await run('dismiss');
    }
  } catch (error) { $('editor-error').textContent = cleanError(error); }
  finally { editorSaving = false; updateFooter(); }
};
$('search').oninput = () => {
  pendingQuery = $('search').value; focusedID = null; clearSelection(); clearTimeout(searchTimer); renderRoot();
  if (noticeSource !== 'fatal') $('notice').hidden = true;
  searchTimer = setTimeout(() => void run('search', { query: $('search').value, scope: state.scope }), 45);
};
$('scope').onchange = () => setScope($('scope').value);
$('back').onclick = () => setScope('All'); $('route-back').onclick = back;
$('home').onclick = () => { if (state.shortcutError) void run('settings'); else if (route !== 'root') back(); else { setScope('All'); focusSearch(); } };
$('actions').onclick = showActions;
$('toggle-selection').onclick = () => { toggleSelection(); focusSearch(); };
$('select-all').onclick = () => { selectAllPages(); focusSearch(); };
$('clear-selection').onclick = () => { clearSelection(); focusSearch(); };
$('open-settings').onclick = () => void run('settings');
$('open-activity').onclick = openActivity;
$('show-shortcuts').onclick = showShortcuts;
$('show-features').onclick = showFeatures;
$('features-close').onclick = closeFeatures;
$('features-search').oninput = () => renderFeatures();
$('features-dialog').onkeydown = event => {
  if (!['ArrowDown', 'ArrowUp'].includes(event.key) || event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.target === $('features-search') && event.key === 'ArrowUp') return;
  const stops = [$('features-search'), ...$('features-dialog').querySelectorAll('.feature-action:not(:disabled)')];
  const index = stops.indexOf(document.activeElement); if (index < 0) return;
  const next = index + (event.key === 'ArrowDown' ? 1 : -1);
  if (next >= 0 && next < stops.length) { event.preventDefault(); stops[next].focus(); }
};
$('features-dialog').onclose = () => {
  if (featuresReturnFocus?.isConnected && !featuresReturnFocus.closest('dialog')) featuresReturnFocus.focus();
  else focusSearch();
};
$('shortcuts-close').onclick = () => $('shortcuts-dialog').close();
$('shortcut-settings').onclick = () => { $('shortcuts-dialog').close(); void run('settings'); };
$('shortcuts-dialog').onclose = () => { if (shortcutReturnFocus?.isConnected && !shortcutReturnFocus.closest('dialog')) shortcutReturnFocus.focus(); else focusSearch(); };
$('primary').onclick = async () => {
  if (route === 'activity') back();
  else if (route === 'editor') $('editor-form').requestSubmit();
  else if (route === 'sources') back();
  else if (route === 'selection') {
    if (selectionSaving) return;
    selectionSaving = true; updateFooter();
    try { if (await run('saveSelection', { ids: [...captureSelected] })) { setRoute('root'); focusSearch(); } }
    finally { selectionSaving = false; updateFooter(); }
  }
  else void execute(current());
};
$('usage-off').onclick = () => void run('analyticsEnabled', { enabled: false });
$('usage-privacy').onclick = () => void run('privacy');
$('usage-dismiss').onclick = () => void run('usageNoticeDismiss');
$('onboarding-done').onclick = () => void run('onboardingDone');
$('history-enabled').onchange = () => void run('historyEnabled', { enabled: $('history-enabled').checked });
$('history-refresh').onclick = () => void run('refresh'); $('history-access').onclick = () => void run('historyAccess');
$('dismiss-notice').onclick = () => { $('notice').hidden = true; if (state.error) void run('dismissMessage'); };
$('action-search').oninput = () => { actionIndex = 0; renderActions(); };
$('action-dialog').onclose = focusSearch;
$('keep-editing').onclick = () => { $('discard-dialog').close(); $('edit-note').focus(); };
$('discard').onclick = () => { $('discard-dialog').close(); const action = discardAction; discardAction = null; void action?.(); };
function handlePageShortcut(event) {
  if (event.key === 'Enter' && !event.metaKey) return false;
  const action = availableActions().find(item => matchesShortcut(event, item.shortcut));
  if (!action) return false;
  event.preventDefault();
  if (!event.repeat) { if ($('action-dialog').open) $('action-dialog').close(); void action.run(); }
  return true;
}
document.addEventListener('keydown', event => {
  if (event.isComposing || event.keyCode === 229) return;
  if ($('shortcuts-dialog').open) {
    if (event.key === 'Escape' || (event.metaKey && event.key === '/')) { event.preventDefault(); $('shortcuts-dialog').close(); }
    return;
  }
  if ($('features-dialog').open) {
    if (event.key === 'Escape') { event.preventDefault(); closeFeatures(); }
    else if (event.metaKey && event.key === '/') event.preventDefault();
    return;
  }
  if ($('discard-dialog').open) return;
  if (fatal) return;
  if ($('action-dialog').open) {
    if (event.key === 'Escape') { event.preventDefault(); $('action-dialog').close(); }
    else if (['ArrowDown', 'ArrowUp'].includes(event.key)) { event.preventDefault(); actionIndex = Math.max(0, Math.min(filteredActions.length - 1, actionIndex + (event.key === 'ArrowDown' ? 1 : -1))); renderActions(); $('action-options').querySelector('.active')?.scrollIntoView({ block: 'nearest' }); $('action-search').focus(); }
    else if (event.key === 'Enter' && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && document.activeElement?.tagName !== 'BUTTON') { event.preventDefault(); const action = filteredActions[actionIndex]; if (action && !event.repeat) { $('action-dialog').close(); void action.run(); } }
    else if (event.metaKey && event.key.toLowerCase() === 'k') { event.preventDefault(); $('action-dialog').close(); }
    else if (event.metaKey && event.key === '/') { event.preventDefault(); showShortcuts(); }
    else if (event.key !== 'Enter' || event.metaKey) handlePageShortcut(event);
    return;
  }
  if (event.key === 'Escape') { event.preventDefault(); back(); return; }
  if (event.metaKey && event.key === '/') { event.preventDefault(); showShortcuts(); return; }
  if (route !== 'root') { if (event.metaKey && event.key === 'Enter') { event.preventDefault(); $('primary').click(); } return; }
  // Keep native keyboard activation for focused controls, including privacy actions.
  if (!event.metaKey && !event.ctrlKey && !event.altKey && ['Enter', ' '].includes(event.key) && document.activeElement?.tagName === 'BUTTON') return;
  if (event.metaKey && event.key.toLowerCase() === 'k') { event.preventDefault(); showActions(); }
  else if (event.ctrlKey && event.key === 'Tab') { event.preventDefault(); setScope(scopes[(scopes.indexOf(state.scope) + (event.shiftKey ? scopes.length - 1 : 1)) % scopes.length]); }
  else if (event.metaKey && /^[1-9]$/.test(event.key)) { event.preventDefault(); void execute(items[Number(event.key) - 1]); }
  else if (document.activeElement !== $('scope') && handlePageShortcut(event)) return;
  else if (['ArrowDown', 'ArrowUp'].includes(event.key) && !event.metaKey && !event.ctrlKey && !event.altKey && document.activeElement !== $('scope')) { event.preventDefault(); navigate(event.key === 'ArrowDown' ? 1 : -1, event.shiftKey); }
  else if (event.key === 'Enter' && !event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey && document.activeElement !== $('scope')) { event.preventDefault(); void execute(current()); }
});
window.savenest.onEvent(message => {
  if (message.event === 'state' && !fatal) { state = message.state; renderState(); }
  if (message.event === 'focus') {
    if (route === 'activity') activity?.refresh();
    if (message.reset && route === 'root') setScope('All');
    focusSearch();
  }
  if (message.event === 'activityChanged') activity?.changed();
  if (message.event === 'add') openEditor();
  if (message.event === 'editorSaved' && captureID && !editorSaving) { captureID = null; setRoute('root'); focusSearch(); }
  if (message.event === 'selectionClosed' && route === 'selection') { setRoute('root'); focusSearch(); }
  if (message.event === 'error') notice(message.message, true);
  if (message.event === 'fatal') {
    fatal = true; notice(message.message, true, 'fatal'); $('status').textContent = 'Connection unavailable';
    $('results').setAttribute('aria-busy', 'false'); document.querySelectorAll('input,textarea,select').forEach(node => node.disabled = true); updateFooter();
  }
});
void run('snapshot');
