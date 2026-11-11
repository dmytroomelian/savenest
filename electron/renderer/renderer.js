'use strict';
const $ = id => document.getElementById(id);
const model = window.LauncherModel;
const scopes = ['All', 'Open', 'Saved', 'History', 'Favorites', 'Notes', 'Archive'];
let state = { rows: [], query: '', scope: 'All', tags: [], loading: true, historySources: [] };
let items = [], focusedID = null, selected = new Set(), route = 'root', pendingQuery = null, searchTimer;
let editingID = null, captureID = null, editorBaseline = '', editorSaving = false, lastCaptureID = null, lastSelectionID = null;
let captureSelected = new Set(), selectionSaving = false, actionItems = [], filteredActions = [], actionIndex = 0, fatal = false;
let lastNativeMessage = '', noticeSource = '', discardAction = null;
let shortcutReturnFocus = null;
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
  undo: 'M3 10h10a7 7 0 0 1 7 7M3 10l6-6M3 10l6 6', search: 'M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14M15 15l6 6'
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
$('nest-mark').append(icon('nest'));
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
function changeQuery(query, scope = state.scope) {
  clearTimeout(searchTimer); $('search').value = query; pendingQuery = query; focusedID = null; selected.clear();
  void run('search', { query, scope });
}
function setScope(scope) { state.scope = scope; changeQuery('', scope); renderRoot(); focusSearch(); }
function setRoute(value) {
  route = value; document.body.dataset.view = value;
  $('search-header').hidden = value !== 'root'; $('route-header').hidden = value === 'root';
  for (const name of ['root', 'editor', 'sources', 'selection']) $(name + '-view').hidden = value !== name;
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
  editingID = captured ? null : row?.id || null; captureID = captured ? row.id : null;
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
  if (route === 'editor') {
    if (editorSaving) return;
    if (dirty()) { discardAction = leaveEditor; $('discard-dialog').showModal(); }
    else void leaveEditor();
  } else if (route === 'selection') {
    if (selectionSaving) return;
    void run('cancelSelection'); setRoute('root'); focusSearch();
  }
  else if (route !== 'root') { setRoute('root'); renderRoot(); focusSearch(); }
  else if (state.scope !== 'All') setScope('All');
  else void run('dismiss');
}
function relativeVisit(value) {
  if (!value) return '';
  const minutes = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 60000));
  if (minutes < 60) return minutes < 2 ? 'Just visited' : `${minutes}m ago`;
  const hours = Math.floor(minutes / 60); return hours < 24 ? `${hours}h ago` : `${Math.floor(hours / 24)}d ago`;
}
function updateFooter() {
  $('open-settings').disabled = fatal;
  $('shortcut-settings').disabled = fatal;
  $('primary').disabled = fatal || editorSaving || state.busy || (route === 'root' && !current());
  if (route === 'editor') { $('primary').replaceChildren(el('span', '', editorSaving ? 'Saving…' : 'Save link'), el('kbd', '', '⌘↵')); return; }
  if (route === 'selection') { $('primary').replaceChildren(el('span', '', selectionSaving ? 'Saving…' : `Save ${captureSelected.size} tabs`), el('kbd', '', '⌘↵')); $('primary').disabled = fatal || selectionSaving || !captureSelected.size; return; }
  if (route === 'sources') { $('primary').replaceChildren(el('span', '', 'Back to search'), el('kbd', '', 'esc')); return; }
  $('primary').replaceChildren(el('span', '', model.primaryLabel(current())), el('kbd', '', '↵'));
  $('actions').replaceChildren(el('span', '', selected.size ? `Actions · ${selected.size}` : 'Actions'), el('kbd', '', '⌘K'));
  $('actions').disabled = fatal;
}
function updateSelection(scroll = false) {
  for (const node of document.querySelectorAll('.row')) {
    const active = node.dataset.id === focusedID; node.classList.toggle('selected', active);
    node.setAttribute('aria-selected', String(active || selected.has(node.dataset.id)));
    if (node.querySelector('.row-check')) node.querySelector('.row-check').checked = selected.has(node.dataset.id);
    if (active) { $('search').setAttribute('aria-activedescendant', node.id); if (scroll) node.scrollIntoView({ block: 'nearest' }); }
  }
  if (!focusedID) $('search').removeAttribute('aria-activedescendant');
  updateFooter();
}
function navigate(offset) {
  if (!items.length) return;
  const index = items.findIndex(item => item.id === focusedID);
  focusedID = items[Math.max(0, Math.min(items.length - 1, index + offset))].id; updateSelection(true);
}
function renderRoot() {
  const query = $('search').value;
  const ready = (state.resultsQuery ?? state.query) === query && (state.resultsScope ?? state.scope) === state.scope;
  items = model.rows({ ...state, rows: ready ? state.rows : [] }, query);
  const valid = new Set(items.map(item => item.id)); selected = new Set([...selected].filter(id => valid.has(id)));
  if (!valid.has(focusedID)) focusedID = items[0]?.id || null;
  $('scope').value = state.scope; $('back').hidden = state.scope === 'All'; $('nest-mark').hidden = state.scope !== 'All';
  $('search').placeholder = { All: 'Search tabs, saved links, history, or commands…', Open: 'Search open browser tabs…', Saved: 'Search saved links, notes, or #tags…', History: 'Search pages you visited…', Favorites: 'Search favorites…', Notes: 'Search notes…', Archive: 'Search archived links…' }[state.scope];
  const nodes = []; let group = '';
  items.forEach((item, index) => {
    const next = item.kind === 'command' ? (query ? 'Commands' : 'Quick actions') : query ? 'Matching pages' : state.scope === 'History' ? 'Recently visited' : state.scope === 'All' ? 'Open tabs & recent links' : state.scope;
    if (next !== group) { nodes.push(el('div', 'group-label', next)); group = next; }
    const row = el('div', 'row'); row.id = 'result-' + index; row.dataset.id = item.id; row.dataset.kind = item.kind; row.setAttribute('role', 'option');
    const tile = el('span', 'row-icon' + (item.kind === 'page' ? ' page-icon' : ''));
    if (item.kind === 'command') tile.append(icon(item.symbol)); else tile.textContent = (item.domain || '?')[0].toUpperCase();
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
      check.onchange = () => { check.checked ? selected.add(item.id) : selected.delete(item.id); focusedID = item.id; updateSelection(); focusSearch(); };
      accessory.append(check);
      const read = el('button', 'row-read'); read.append(icon('reader')); read.title = 'Read & note'; read.setAttribute('aria-label', 'Read & note: ' + item.title);
      read.onclick = event => { event.stopPropagation(); void run('readerOpen', { ids: [item.id] }); };
      read.ondblclick = event => event.stopPropagation();
      accessory.append(read);
    } else accessory.append(el('span', 'source-label', 'Command'));
    if (index < 9) accessory.append(el('kbd', '', '⌘' + (index + 1)));
    const more = el('button', 'row-more', '⋯'); more.setAttribute('aria-label', 'Actions for ' + item.title); more.tabIndex = -1;
    more.onclick = event => { event.stopPropagation(); selected.clear(); focusedID = item.id; updateSelection(); showActions(); };
    accessory.append(more); row.append(accessory);
    row.onclick = () => { selected.clear(); focusedID = item.id; updateSelection(); focusSearch(); };
    row.ondblclick = () => void execute(item);
    row.oncontextmenu = event => { event.preventDefault(); if (!selected.has(item.id)) selected.clear(); focusedID = item.id; updateSelection(); showActions(); };
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
  if (state.message !== lastNativeMessage) {
    lastNativeMessage = state.message;
    if (state.message) notice(state.message, state.error, 'native');
    else if (noticeSource === 'native') $('notice').hidden = true;
  }
  renderRoot(); if (route === 'sources') renderSources();
  if (state.captureDraft && state.captureDraft.id !== lastCaptureID && route === 'root') {
    lastCaptureID = state.captureDraft.id; openEditor(state.captureDraft, true);
  }
  if (state.captureSelection && state.captureSelection.id !== lastSelectionID && route === 'root') {
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
  else if (item.scope) setScope(item.scope);
  else if (item.command) await run(item.command, item.action ? { action: item.action } : {});
}
function showActions() {
  if (route !== 'root' || fatal) return;
  const rows = chosen(), single = rows.length === 1;
  $('actions-context').textContent = single ? rows[0].title : rows.length ? `${rows.length} selected pages` : 'All Savenest actions';
  actionItems = [];
  const group = single ? 'Selected page' : 'Selected pages';
  const add = (title, command, targets, key = '', danger = false) => { if (targets.length) actionItems.push({ id: 'context:' + command, group, title, key, danger, run: () => run(command, { ids: targets.map(row => row.id) }) }); };
  if (single && rows[0].kind === 'command') actionItems.push({ id: 'context:run', group: 'Selected command', title: 'Run command', key: '↵', run: () => execute(rows[0]) });
  else {
    if (single) add(rows[0].isOpen ? 'Switch to tab' : 'Open link', 'open', rows, '↵');
    if (single) add('Read & note', 'readerOpen', rows);
    add('Save to library', 'save', rows.filter(row => !row.isSaved), '⌘S');
    if (single) actionItems.push({ id: 'context:edit', group, title: 'Edit title, note & tags', key: '⌘E', run: () => openEditor(rows[0]) });
    add(single ? 'Copy URL' : 'Copy URLs', 'copy', rows, '⇧⌘C');
    add('Save & close tabs', 'saveClose', rows.filter(row => row.isOpen));
    add(single && rows[0].favorite ? 'Remove favorite' : 'Toggle favorite', 'favorite', rows.filter(row => row.isSaved));
    add('Archive saved links', 'archive', rows.filter(row => row.isSaved && !row.archived));
    add('Restore saved links', 'restore', rows.filter(row => row.isSaved && row.archived));
    if (single) add('Email link…', 'share', rows.filter(row => row.isSaved));
    add('Close browser tabs…', 'close', rows.filter(row => row.isOpen), '', true);
    add('Delete saved links…', 'delete', rows.filter(row => row.isSaved), '', true);
  }
  for (const item of model.actionCatalog(state)) actionItems.push({ ...item, run: () => execute(item) });
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
      ['Choose a result', '↑ ↓'], ['Open or run a result', '↵'], ['Run result 1–9', '⌘1–9'],
      ['Next / previous search scope', '⌃Tab / ⌃⇧Tab'], ['Focus search', '⌘F'],
      ['Add a link', '⌘N'], ['Refresh tabs and history', '⌘R'], ['Back or close', 'esc']
    ]],
    ['With a page selected', [
      ['Save selected pages', '⌘S'], ['Edit title, note and tags', '⌘E'], ['Copy selected URLs', '⇧⌘C']
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
$('editor-form').onsubmit = async event => {
  event.preventDefault(); if (editorSaving) return;
  editorSaving = true; $('editor-error').textContent = ''; updateFooter();
  const values = formValues(), tags = values.tags.split(',').map(value => value.trim()).filter(Boolean);
  const dismissAfterSave = !editingID;
  try {
    const request = { title: values.title, note: values.note, tags };
    if (captureID) Object.assign(request, { command: 'saveDraft', ids: [captureID] });
    else if (editingID) Object.assign(request, { command: 'edit', ids: [editingID] });
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
  pendingQuery = $('search').value; focusedID = null; selected.clear(); clearTimeout(searchTimer); renderRoot();
  if (noticeSource !== 'fatal') $('notice').hidden = true;
  searchTimer = setTimeout(() => void run('search', { query: $('search').value, scope: state.scope }), 45);
};
$('scope').onchange = () => setScope($('scope').value);
$('back').onclick = () => setScope('All'); $('route-back').onclick = back;
$('home').onclick = () => { if (state.shortcutError) void run('settings'); else if (route !== 'root') back(); else { setScope('All'); focusSearch(); } };
$('actions').onclick = showActions;
$('open-settings').onclick = () => void run('settings');
$('show-shortcuts').onclick = showShortcuts;
$('shortcuts-close').onclick = () => $('shortcuts-dialog').close();
$('shortcut-settings').onclick = () => { $('shortcuts-dialog').close(); void run('settings'); };
$('shortcuts-dialog').onclose = () => { if (shortcutReturnFocus?.isConnected && !shortcutReturnFocus.closest('dialog')) shortcutReturnFocus.focus(); else focusSearch(); };
$('primary').onclick = async () => {
  if (route === 'editor') $('editor-form').requestSubmit();
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
document.addEventListener('keydown', event => {
  if (event.isComposing || event.keyCode === 229) return;
  if ($('shortcuts-dialog').open) {
    if (event.key === 'Escape' || (event.metaKey && event.key === '/')) { event.preventDefault(); $('shortcuts-dialog').close(); }
    return;
  }
  if ($('discard-dialog').open) return;
  if ($('action-dialog').open) {
    if (event.key === 'Escape') { event.preventDefault(); $('action-dialog').close(); }
    else if (['ArrowDown', 'ArrowUp'].includes(event.key)) { event.preventDefault(); actionIndex = Math.max(0, Math.min(filteredActions.length - 1, actionIndex + (event.key === 'ArrowDown' ? 1 : -1))); renderActions(); $('action-options').querySelector('.active')?.scrollIntoView({ block: 'nearest' }); $('action-search').focus(); }
    else if (event.key === 'Enter' && document.activeElement?.tagName !== 'BUTTON') { event.preventDefault(); const action = filteredActions[actionIndex]; if (action) { $('action-dialog').close(); void action.run(); } }
    else if (event.metaKey && event.key.toLowerCase() === 'k') { event.preventDefault(); $('action-dialog').close(); }
    else if (event.metaKey && event.key === '/') { event.preventDefault(); showShortcuts(); }
    return;
  }
  if (event.key === 'Escape') { event.preventDefault(); back(); return; }
  if (event.metaKey && event.key === '/') { event.preventDefault(); showShortcuts(); return; }
  if (route !== 'root') { if (event.metaKey && event.key === 'Enter') { event.preventDefault(); $('primary').click(); } return; }
  // Keep native keyboard activation for focused controls, including privacy actions.
  if (event.key === 'Enter' && document.activeElement?.tagName === 'BUTTON') return;
  const typing = ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName);
  if (event.metaKey && event.key.toLowerCase() === 'k') { event.preventDefault(); showActions(); }
  else if (event.ctrlKey && event.key === 'Tab') { event.preventDefault(); setScope(scopes[(scopes.indexOf(state.scope) + (event.shiftKey ? scopes.length - 1 : 1)) % scopes.length]); }
  else if (event.metaKey && /^[1-9]$/.test(event.key)) { event.preventDefault(); void execute(items[Number(event.key) - 1]); }
  else if (event.metaKey && event.key.toLowerCase() === 's' && current()?.kind === 'page') { event.preventDefault(); void run('save', { ids: chosen().map(item => item.id) }); }
  else if (event.metaKey && event.key.toLowerCase() === 'e' && current()?.kind === 'page') { event.preventDefault(); openEditor(current()); }
  else if (event.metaKey && event.shiftKey && event.key.toLowerCase() === 'c' && current()?.kind === 'page') { event.preventDefault(); void run('copy', { ids: chosen().map(item => item.id) }); }
  else if (event.metaKey && event.key === 'z' && !typing) { event.preventDefault(); void run('undo'); }
  else if (event.shiftKey && event.code === 'Space' && current()?.kind === 'page') { event.preventDefault(); const id = current().id; selected.has(id) ? selected.delete(id) : selected.add(id); updateSelection(); }
  else if (['ArrowDown', 'ArrowUp'].includes(event.key) && document.activeElement !== $('scope')) { event.preventDefault(); navigate(event.key === 'ArrowDown' ? 1 : -1); }
  else if (event.key === 'Enter' && document.activeElement !== $('scope')) { event.preventDefault(); void execute(current()); }
});
window.savenest.onEvent(message => {
  if (message.event === 'state' && !fatal) { state = message.state; renderState(); }
  if (message.event === 'focus') { if (message.reset && route === 'root') setScope('All'); focusSearch(); }
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
