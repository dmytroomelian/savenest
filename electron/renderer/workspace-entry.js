import { EditorState, StateField, Compartment } from '@codemirror/state';
import { EditorView, Decoration, WidgetType, keymap, placeholder, drawSelection } from '@codemirror/view';
import { history, historyKeymap, defaultKeymap } from '@codemirror/commands';
import { markdown } from '@codemirror/lang-markdown';
import { syntaxTree } from '@codemirror/language';
import { search, searchKeymap, openSearchPanel } from '@codemirror/search';
import DOMPurify from 'dompurify';

const $ = id => document.getElementById(id);
const api = window.workspace;
let source = null, notes = {}, documentModel = null, editor = null;
let generation = 0, editVersion = 0, baseline = '', conflict = null, sourceMode = false;
let saveTimer, draftTimer, savePromise = null, ioQueue = Promise.resolve(), checking = false;
let viewGeneration = 0;
let original = false, switching = false, configured = false, imagesLoaded = false, copiedQuickNote = false;
let lastDirty = false, destroyed = false, split = 55, noticeURL = null;
const editable = new Compartment(), livePreview = new Compartment();
const scrollPositions = new Map();

function cleanError(error) { return String(error?.message || error).replace(/^Error invoking remote method '[^']+': Error: /, ''); }
function request(command, values = {}) { return api.request({ command, ...values }); }
function quietRequest(command, values = {}) { return request(command, values).catch(() => false); }
function notice(message, url = null) {
  noticeURL = null;
  if (url) { try { const parsed = new URL(url); if (['https:', 'http:'].includes(parsed.protocol) && !parsed.username && !parsed.password) noticeURL = parsed.href; } catch {} }
  $('workspace-notice-text').textContent = message; $('workspace-notice').hidden = !message; $('notice-open-link').hidden = !noticeURL;
}
function setStatus(text, state = '') { $('save-status-text').textContent = text; $('save-status').dataset.state = state; $('retry-save').hidden = state !== 'error' || !documentModel || Boolean(conflict); }
function text() { return editor?.state.doc.toString() || ''; }
function dirty() { return Boolean(documentModel && text() !== baseline); }
function announceDirty() {
  const value = dirty() || Boolean(savePromise) || Boolean(conflict);
  if (value !== lastDirty) { lastDirty = value; void quietRequest('dirty', { dirty: value }); }
}
function enqueueIO(operation) { const next = ioQueue.catch(() => {}).then(operation); ioQueue = next; return next; }
function wordCount(value) { return value.replace(/^---\n[\s\S]*?\n---(?:\n|$)/, '').trim().split(/\s+/u).filter(Boolean).length; }
function updateEditorFooter() { const count = wordCount(text()); $('word-count').textContent = count ? `${count.toLocaleString()} ${count === 1 ? 'word' : 'words'}` : ''; }
function updateControls() {
  const exists = Boolean(documentModel?.exists);
  $('open-obsidian').disabled = !exists || switching;
  $('source-toggle').disabled = !documentModel || switching;
  $('copy-quick-note').hidden = !source?.quickNote || !documentModel || copiedQuickNote;
  $('copy-quick-note').disabled = switching;
  $('note-location').disabled = switching || !configured;
  $('choose-vault').disabled = switching;
  for (const id of ['reload-note', 'save-copy', 'locate-note']) $(id).disabled = switching;
  $('note-path').textContent = configured ? [documentModel?.vaultName || notes.vaultName || 'Obsidian', documentModel?.folder ?? notes.folder ?? ''].filter(Boolean).join(' / ') : 'Connect your Obsidian vault';
  $('note-location').title = exists ? documentModel.path : configured ? 'Choose the folder for new notes' : 'Connect your Obsidian vault';
  $('editor-mode').textContent = sourceMode ? 'Markdown source' : 'Markdown';
  editor?.dispatch({ effects: editable.reconfigure(EditorView.editable.of(Boolean(documentModel) && !switching)) });
}

class PropertiesHint extends WidgetType {
  toDOM() {
    const row = document.createElement('div'); row.className = 'md-properties';
    const button = document.createElement('button'); button.textContent = 'Page reference'; button.title = 'View the note’s source properties';
    button.onclick = () => { if (!sourceMode) $('source-toggle').click(); }; row.append(button); return row;
  }
  ignoreEvent() { return true; }
}
class TaskBox extends WidgetType {
  constructor(checked, position) { super(); this.checked = checked; this.position = position; }
  eq(other) { return other.checked === this.checked && other.position === this.position; }
  toDOM(view) {
    const input = document.createElement('input'); input.type = 'checkbox'; input.checked = this.checked; input.className = 'md-task';
    input.setAttribute('aria-label', this.checked ? 'Mark task incomplete' : 'Mark task complete');
    input.addEventListener('change', () => {
      if (switching) return;
      view.dispatch({ changes: { from: this.position + 1, to: this.position + 2, insert: input.checked ? 'x' : ' ' } });
    }); return input;
  }
  ignoreEvent() { return true; }
}
function decorations(state) {
  const ranges = [], active = state.doc.lineAt(state.selection.main.head).number;
  let fence = false, frontmatter = false;
  const metadata = /^---\n[\s\S]*?\n---(?:\n|$)/.exec(state.doc.toString());
  const selection = state.selection.main;
  const foldedMetadata = metadata && selection.from >= metadata[0].length ? metadata[0].length : 0;
  if (foldedMetadata) ranges.push(Decoration.replace({ block: true, widget: new PropertiesHint() }).range(0, foldedMetadata));
  for (let n = 1; n <= state.doc.lines; n++) {
    const line = state.doc.line(n), value = line.text;
    if (line.from < foldedMetadata) continue;
    if (n === 1 && value === '---') frontmatter = true;
    if (frontmatter) {
      ranges.push(Decoration.line({ class: 'md-frontmatter' }).range(line.from));
      if (n > 1 && value === '---') frontmatter = false;
      continue;
    }
    if (/^\s*(```|~~~)/.test(value)) { fence = !fence; ranges.push(Decoration.line({ class: 'md-code' }).range(line.from)); continue; }
    if (fence) { ranges.push(Decoration.line({ class: 'md-code' }).range(line.from)); continue; }
    const heading = /^(#{1,6})\s/.exec(value);
    if (heading) ranges.push(Decoration.line({ class: 'md-heading md-h' + Math.min(heading[1].length, 3) }).range(line.from));
    if (/^\s*>/.test(value)) ranges.push(Decoration.line({ class: 'md-quote' }).range(line.from));
    if (/^\s*([-*_])(?:\s*\1){2,}\s*$/.test(value)) ranges.push(Decoration.line({ class: 'md-rule' }).range(line.from));
    const task = /^\s*[-*+] (\[[ xX]\])/.exec(value);
    if (n !== active) {
      const linkPattern = /(?<!!)\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g;
      for (const match of value.matchAll(linkPattern)) {
        const start = line.from + match.index, labelEnd = start + 1 + match[1].length;
        ranges.push(Decoration.replace({}).range(start, start + 1));
        ranges.push(Decoration.replace({}).range(labelEnd, start + match[0].length));
      }
    }
    if (task && n !== active) {
      const from = line.from + task[0].length - 3;
      ranges.push(Decoration.replace({ widget: new TaskBox(task[1].toLowerCase() === '[x]', from) }).range(from, from + 3));
    }
  }
  syntaxTree(state).iterate({ enter(node) {
    const { from, to, name } = node;
    if (to <= foldedMetadata) return false;
    if (from === to) return;
    const nodeClass = { StrongEmphasis: 'md-strong', Emphasis: 'md-emphasis', InlineCode: 'md-inline-code', Link: 'md-link' }[name];
    if (nodeClass) ranges.push(Decoration.mark({ class: nodeClass }).range(from, to));
    if (['HeaderMark', 'EmphasisMark', 'CodeMark', 'QuoteMark'].includes(name)) {
      const line = state.doc.lineAt(from);
      if (line.number !== active && (name !== 'CodeMark' || node.node.parent?.name === 'InlineCode')) ranges.push(Decoration.replace({}).range(from, to));
      else ranges.push(Decoration.mark({ class: 'md-marker' }).range(from, to));
    }
  } });
  return Decoration.set(ranges, true);
}
const liveField = StateField.define({
  create: decorations,
  update(value, transaction) { return transaction.docChanged || transaction.selection || syntaxTree(transaction.startState) !== syntaxTree(transaction.state) ? decorations(transaction.state) : value; },
  provide: field => EditorView.decorations.from(field)
});
function wrapSelection(before, after = before) {
  if (!editor || switching) return false;
  const range = editor.state.selection.main, selected = editor.state.sliceDoc(range.from, range.to);
  editor.dispatch({ changes: { from: range.from, to: range.to, insert: before + selected + after }, selection: { anchor: range.from + before.length, head: range.to + before.length } });
  editor.focus(); return true;
}
function linkSelection() { return wrapSelection('[', '](https://)'); }
function createEditor(value) {
  editor?.destroy();
  editor = new EditorView({ parent: $('editor-host'), state: EditorState.create({ doc: value, extensions: [
    history(), drawSelection(), markdown(), search({ top: true }), EditorView.lineWrapping,
    EditorView.contentAttributes.of({ 'aria-label': 'Write your Markdown note', spellcheck: 'true', autocapitalize: 'sentences' }),
    placeholder('What would you like to remember?'), editable.of(EditorView.editable.of(!switching)),
    livePreview.of(sourceMode ? [] : liveField),
    keymap.of([
      { key: 'Mod-s', run: () => { void saveDocument(); return true; } },
      { key: 'Mod-b', run: () => wrapSelection('**') }, { key: 'Mod-i', run: () => wrapSelection('*') },
      { key: 'Mod-k', run: linkSelection }, ...searchKeymap, ...historyKeymap, ...defaultKeymap
    ]),
    EditorView.updateListener.of(update => {
      if (update.docChanged) {
        editVersion++; announceDirty(); updateEditorFooter();
        if (!conflict) setStatus(dirty() ? 'Unsaved changes' : documentModel?.exists ? 'Saved to Obsidian' : 'Ready to write', dirty() ? '' : 'saved');
        scheduleSave();
      }
      if (update.selectionSet || update.docChanged || update.viewportChanged) positionSelectionTools();
    })
  ] }) });
  $('editor-host').classList.toggle('source-mode', sourceMode);
  editor.scrollDOM.addEventListener('scroll', () => { $('selection-tools').hidden = true; });
}
function positionSelectionTools() {
  if (!editor || sourceMode || switching || editor.state.selection.main.empty || !editor.hasFocus) { $('selection-tools').hidden = true; return; }
  requestAnimationFrame(() => {
    if (!editor || editor.state.selection.main.empty || switching) { $('selection-tools').hidden = true; return; }
    const point = editor.coordsAtPos(editor.state.selection.main.from), pane = $('notes-pane').getBoundingClientRect();
    if (!point || point.top < pane.top + 80 || point.top > pane.bottom - 40) { $('selection-tools').hidden = true; return; }
    $('selection-tools').style.left = Math.max(14, Math.min(pane.width - 145, point.left - pane.left)) + 'px';
    $('selection-tools').style.top = Math.max(67, point.top - pane.top - 39) + 'px';
    $('selection-tools').hidden = false;
  });
}
function installDocument(value, { focus = true } = {}) {
  if (!value?.documentId) throw new Error('The note could not be opened. Choose your vault and try again.');
  documentModel = value; baseline = value.recovered ? (value.diskText ?? value.savedText ?? '') : value.text || ''; conflict = null; editVersion = 0;
  createEditor(value.text || '');
  $('editor-host').hidden = false; $('note-loading').hidden = true; $('note-setup').hidden = true;
  $('conflict-banner').hidden = true; $('recovery-banner').hidden = !value.recovered;
  updateControls(); updateEditorFooter(); announceDirty();
  setStatus(value.recovered ? 'Recovered writing — saving…' : value.exists ? 'Saved to Obsidian' : 'Your note will be created when you write', value.exists && !value.recovered ? 'saved' : '');
  if (focus) {
    const at = editor.state.doc.length;
    editor.dispatch({ selection: { anchor: at } }); editor.focus();
    if (innerWidth < 900) compactPane('notes');
  }
  if (value.conflict || value.missing) showConflict({ ...value, text: value.diskText ?? value.text, revision: value.diskRevision ?? value.revision });
  else if (value.recovered && dirty()) scheduleSave();
}
function scheduleSave() {
  clearTimeout(saveTimer); clearTimeout(draftTimer);
  if (!documentModel || switching || !dirty()) return;
  draftTimer = setTimeout(() => { void persistDraft().catch(error => { setStatus('Couldn’t protect unsaved changes', 'error'); notice(cleanError(error)); }); }, 180);
  if (!conflict) saveTimer = setTimeout(() => { void saveDocument(); }, 600);
}
async function persistDraft() {
  if (!documentModel || !dirty()) return;
  const payload = { documentId: documentModel.documentId, text: text(), revision: documentModel.revision };
  return enqueueIO(() => request('noteDraft', payload));
}
function showConflict(value) {
  conflict = value; $('conflict-banner').hidden = false;
  $('conflict-banner').querySelector('strong').textContent = value.missing ? 'This note moved or was deleted' : 'Changed in Obsidian';
  $('conflict-detail').textContent = value.missing ? 'Locate the file, or keep your writing in a new copy.' : 'This file changed outside Savenest. Keep the disk version or save your writing separately.';
  $('reload-note').hidden = Boolean(value.missing); $('locate-note').hidden = !value.missing;
  setStatus('Your writing is safe here — choose a version'); announceDirty();
}
async function saveDocument() {
  clearTimeout(saveTimer); clearTimeout(draftTimer);
  if (savePromise) { await savePromise; return !dirty() && !conflict; }
  if (conflict) return false;
  if (!documentModel || !dirty()) return true;
  const token = generation, body = text(), id = documentModel.documentId, revision = documentModel.revision;
  setStatus('Saving…');
  const operation = (async () => {
    try {
      await enqueueIO(() => request('noteDraft', { documentId: id, text: body, revision }));
      const saved = await enqueueIO(() => request('noteSave', { documentId: id, text: body, revision }));
      if (generation !== token) return false;
      if (saved?.conflict || saved?.missing) { showConflict(saved); return false; }
      if (!saved?.revision) throw new Error('The note was not saved. Try again.');
      documentModel = { ...documentModel, ...saved }; baseline = body;
      setStatus(dirty() ? 'Unsaved changes' : 'Saved to Obsidian', dirty() ? '' : 'saved');
      $('recovery-banner').hidden = true; updateControls(); return !dirty();
    } catch (error) {
      if (generation === token) { setStatus('Couldn’t save — your writing is kept here', 'error'); notice(cleanError(error)); }
      return false;
    }
  })();
  savePromise = operation; announceDirty();
  try { return await operation; }
  finally { savePromise = null; announceDirty(); if (generation === token && dirty() && !conflict && $('save-status').dataset.state !== 'error' && !switching) scheduleSave(); }
}
async function flush() {
  clearTimeout(saveTimer); clearTimeout(draftTimer); $('selection-tools').hidden = true;
  switching = true; updateControls();
  if (savePromise) await savePromise;
  const ok = !conflict && await saveDocument();
  await ioQueue.catch(() => {});
  return ok && !dirty();
}
async function checkExternal() {
  if (checking || switching || savePromise || !documentModel?.exists || conflict) return;
  checking = true; const token = generation, version = editVersion, id = documentModel.documentId;
  try {
    const result = await request('noteCheck', { documentId: id, revision: documentModel.revision });
    if (token !== generation || switching || savePromise || !result?.changed && !result?.missing) return;
    if (result.missing || dirty() || version !== editVersion) { await persistDraft(); showConflict(result); return; }
    const selection = editor.state.selection.main.head, scroll = editor.scrollDOM.scrollTop;
    installDocument({ ...documentModel, ...result, text: result.text ?? text() }, { focus: false });
    editor.dispatch({ selection: { anchor: Math.min(selection, editor.state.doc.length) } });
    editor.scrollDOM.scrollTop = scroll;
    setStatus('Updated from Obsidian', 'saved');
  } catch (error) { if (token === generation) setStatus('Can’t check this note — ' + cleanError(error), 'error'); }
  finally { checking = false; }
}
async function chooseVault() {
  const token = generation;
  try {
    const result = await request('notesChooseVault');
    if (token !== generation || !result?.configured) return;
    notes = result; configured = true; updateControls();
    $('note-setup').hidden = true; $('note-loading').hidden = false;
    const loaded = await request('noteLoad', { url: source.url, title: source.title });
    if (token === generation) installDocument(loaded);
  } catch (error) { if (token !== generation) return; $('note-loading').hidden = true; $('note-setup').hidden = Boolean(documentModel); notice(cleanError(error)); setStatus('Choose a vault to start writing'); }
}
function renderArticle() {
  imagesLoaded = false; original = false;
  $('article-loading').hidden = true; $('reader-scroll').hidden = false; $('original-frame').hidden = true; $('original-note').hidden = true;
  $('reader-mode').setAttribute('aria-pressed', 'true'); $('original-mode').setAttribute('aria-pressed', 'false');
  $('window-title').textContent = source?.title || 'Read & note'; document.title = (source?.title || 'Read & note') + ' — Savenest';
  let domain = ''; try { domain = new URL(source.url).hostname.replace(/^www\./, ''); } catch {}
  $('source-domain').textContent = domain;
  const article = source?.article;
  $('article').hidden = !article?.content && !article?.textContent;
  $('reader-empty').hidden = !$('article').hidden;
  $('load-images').hidden = true; $('reading-time').textContent = ''; $('reading-time').hidden = false;
  if ($('article').hidden) { $('reader-error').textContent = source?.captureError || 'Reader view isn’t available for this page. Your note is still here.'; return; }
  $('article-title').textContent = article.title || source.title;
  $('article-byline').textContent = article.byline || '';
  const fragment = DOMPurify.sanitize(article.content || '', {
    RETURN_DOM_FRAGMENT: true,
    ALLOWED_TAGS: ['article', 'section', 'div', 'main', 'p', 'br', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'a', 'img', 'figure', 'figcaption', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'caption', 'span', 'pre', 'code', 'kbd', 'samp', 'ol', 'ul', 'li', 'dl', 'dt', 'dd', 'blockquote', 'hr', 'em', 'strong', 'b', 'i', 'u', 's', 'del', 'ins', 'sub', 'sup', 'small', 'abbr', 'cite', 'q', 'time'],
    ALLOWED_ATTR: ['href', 'src', 'alt', 'title', 'width', 'height', 'colspan', 'rowspan'],
    FORBID_TAGS: ['style', 'form', 'input', 'textarea', 'button', 'select', 'iframe', 'video', 'audio', 'source', 'picture', 'svg', 'math'],
    FORBID_ATTR: ['style', 'srcset', 'id', 'name', 'class']
  });
  for (const img of fragment.querySelectorAll('img')) {
    let value = img.getAttribute('src'); img.removeAttribute('src'); img.removeAttribute('srcset');
    try { const url = new URL(value, source.url); if (value && ['http:', 'https:'].includes(url.protocol) && !url.username && !url.password) { img.dataset.imageSrc = url.href; $('load-images').hidden = false; } } catch {}
  }
  for (const link of fragment.querySelectorAll('a')) {
    try {
      const url = new URL(link.getAttribute('href'), source.url);
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) link.removeAttribute('href'); else { link.href = url.href; link.rel = 'noopener noreferrer'; }
    } catch { link.removeAttribute('href'); }
  }
  $('article-content').replaceChildren(fragment);
  if (!$('article-content').textContent.trim() && article.textContent) $('article-content').textContent = article.textContent;
  const count = wordCount(article.textContent || $('article-content').textContent);
  $('reading-time').textContent = `${Math.max(1, Math.ceil(count / 220))} min read`;
  $('reader-scroll').scrollTop = scrollPositions.get(source.url)?.article || 0;
}
async function acceptSource(data) {
  const token = ++generation;
  ++viewGeneration;
  clearTimeout(saveTimer); clearTimeout(draftTimer);
  if (source) scrollPositions.set(source.url, { article: $('reader-scroll').scrollTop, note: editor?.scrollDOM.scrollTop || 0 });
  const modeLabel = data.preview ? 'Sample preview' : data.notes?.readerTest ? 'Reader test' : '';
  $('workspace-mode').textContent = modeLabel; $('workspace-mode').hidden = !modeLabel;
  $('workspace-mode').title = data.preview ? 'Disposable sample vault. Your personal notes stay untouched.' : data.notes?.readerTest ? 'Notes save to the vault you choose. Your installed Savenest library stays untouched.' : '';
  source = data.source; notes = data.notes || {}; configured = Boolean(notes.configured); documentModel = null; baseline = ''; conflict = null; copiedQuickNote = false;
  switching = false; checking = false; sourceMode = false; notice(''); $('source-toggle').setAttribute('aria-pressed', 'false');
  editor?.destroy(); editor = null; $('editor-host').replaceChildren(); $('editor-host').hidden = true;
  $('note-setup').querySelector('h2').textContent = 'A place for your thoughts.';
  $('note-setup').querySelector('p').textContent = 'Connect your Obsidian vault to write beside this page. Notes stay as Markdown files on your Mac.';
  $('conflict-banner').hidden = true; $('recovery-banner').hidden = true; $('note-setup').hidden = configured; $('note-loading').hidden = !configured;
  $('selection-tools').hidden = true; document.documentElement.dataset.appearance = data.appearance || document.documentElement.dataset.appearance || 'black';
  renderArticle(); updateControls(); announceDirty();
  await setOriginal(true);
  if (generation !== token) return;
  setStatus(configured ? 'Opening your note…' : 'Choose a vault to start writing');
  if (!configured) { $('choose-vault').focus(); return; }
  try {
    const loaded = data.document || await request('noteLoad', { url: source.url, title: source.title });
    if (generation !== token) return;
    installDocument(loaded);
    const scroll = scrollPositions.get(source.url)?.note;
    if (scroll !== undefined) requestAnimationFrame(() => { if (generation === token && editor) editor.scrollDOM.scrollTop = scroll; });
  } catch (error) {
    if (generation !== token) return;
    $('note-loading').hidden = true; $('note-setup').hidden = false;
    $('note-setup').querySelector('h2').textContent = 'Let’s reconnect your note.';
    $('note-setup').querySelector('p').textContent = cleanError(error);
    setStatus('Couldn’t open this note', 'error');
  }
}
function originalBounds() {
  const rect = $('original-frame').getBoundingClientRect();
  return { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.max(0, Math.round(rect.width)), height: Math.max(0, Math.round(rect.height)) };
}
async function updateOriginal() {
  const enabled = original && !(innerWidth < 900 && $('workspace').dataset.pane === 'notes');
  try { await request('original', { enabled, bounds: originalBounds() }); }
  catch (error) { notice(cleanError(error)); }
}
async function setOriginal(enabled) {
  const viewToken = ++viewGeneration, token = generation;
  original = enabled; $('reader-scroll').hidden = enabled; $('original-frame').hidden = !enabled; $('original-note').hidden = !enabled;
  $('reader-mode').setAttribute('aria-pressed', String(!enabled)); $('original-mode').setAttribute('aria-pressed', String(enabled));
  $('reading-time').hidden = enabled; $('load-images').hidden = enabled || imagesLoaded || !$('article-content').querySelector('img[data-image-src]');
  await updateOriginal();
  if (enabled || source?.article || token !== generation || viewToken !== viewGeneration) return;
  $('reader-empty').hidden = true; $('article-loading').hidden = false;
  try {
    const captured = await request('readerExtract');
    if (token !== generation || viewToken !== viewGeneration) return;
    source = captured;
  } catch (error) {
    if (token !== generation || viewToken !== viewGeneration) return;
    source = { ...source, captureError: cleanError(error) };
  }
  if (token === generation && viewToken === viewGeneration) renderArticle();
}
function compactPane(pane) {
  $('workspace').dataset.pane = pane;
  $('show-preview').setAttribute('aria-pressed', String(pane === 'preview')); $('show-notes').setAttribute('aria-pressed', String(pane === 'notes'));
  void updateOriginal();
}
function setSplit(value) {
  split = Math.max(30, Math.min(70, value)); document.documentElement.style.setProperty('--split', split + '%');
  $('divider').setAttribute('aria-valuenow', String(Math.round(split)));
  try { localStorage.setItem('read-note-split', String(split)); } catch {}
  void updateOriginal();
}

$('reader-mode').onclick = $('reader-retry').onclick = () => void setOriginal(false);
$('original-mode').onclick = $('empty-original').onclick = () => void setOriginal(true);
$('show-preview').onclick = () => compactPane('preview'); $('show-notes').onclick = () => compactPane('notes');
$('open-browser').onclick = $('empty-browser').onclick = () => { void request('browser').catch(error => notice(cleanError(error))); };
$('choose-vault').onclick = () => void chooseVault();
$('open-obsidian').onclick = async () => {
  if (!documentModel) return;
  if (!await saveDocument()) return;
  try { await request('noteOpen', { documentId: documentModel.documentId }); } catch (error) { notice(cleanError(error)); }
};
$('note-location').onclick = async () => {
  try {
    if (dirty() && !await saveDocument()) return;
    if (documentModel?.exists) await request('noteReveal', { documentId: documentModel.documentId });
    else { const result = await request('notesChooseFolder'); if (result?.configured) { notes = result; updateControls(); } }
  } catch (error) { notice(cleanError(error)); }
};
$('source-toggle').onclick = () => {
  if (!editor) return;
  sourceMode = !sourceMode; editor.dispatch({ effects: livePreview.reconfigure(sourceMode ? [] : liveField) });
  $('editor-host').classList.toggle('source-mode', sourceMode); $('source-toggle').setAttribute('aria-pressed', String(sourceMode));
  $('source-toggle').setAttribute('aria-label', sourceMode ? 'Show live preview' : 'Show Markdown source');
  $('source-toggle').title = sourceMode ? 'Show live preview' : 'Show Markdown source';
  updateControls(); editor.focus();
};
$('copy-quick-note').onclick = () => {
  if (!editor || !source?.quickNote || switching) return;
  const end = editor.state.doc.length, value = (text().endsWith('\n\n') ? '' : '\n\n') + source.quickNote + '\n';
  editor.dispatch({ changes: { from: end, insert: value }, selection: { anchor: end + value.length }, scrollIntoView: true });
  copiedQuickNote = true; updateControls(); editor.focus();
};
$('load-images').onclick = async () => {
  try {
    const result = await request('readerImages', { enabled: true });
    if (result === false) throw new Error('Images could not be loaded. Open the original page to view them.');
    for (const img of $('article-content').querySelectorAll('img[data-image-src]')) { img.referrerPolicy = 'no-referrer'; img.loading = 'lazy'; img.src = img.dataset.imageSrc; }
    imagesLoaded = true; $('load-images').hidden = true;
  } catch (error) { notice(cleanError(error)); }
};
$('article-content').onclick = event => {
  const link = event.target.closest('a[href]'); if (!link) return;
  event.preventDefault(); void request('browser', { url: link.href }).catch(error => notice(cleanError(error)));
};
$('reload-note').onclick = async () => {
  if (switching || !conflict || conflict.missing || !documentModel) return;
  const token = generation;
  const restored = { ...documentModel, ...conflict, text: conflict.text || '', recovered: false, conflict: false, missing: false };
  clearTimeout(saveTimer); clearTimeout(draftTimer);
  switching = true; updateControls();
  // Lock editing while discarding recovery so new typing cannot be replaced by the disk version.
  try {
    await enqueueIO(() => request('noteDiscardDraft', { documentId: restored.documentId }));
    if (generation === token) installDocument(restored);
  } catch (error) { if (generation === token) notice(cleanError(error)); }
  finally { if (generation === token) { switching = false; updateControls(); scheduleSave(); } }
};
$('save-copy').onclick = async () => {
  if (!documentModel) return;
  switching = true; updateControls();
  try { const saved = await enqueueIO(() => request('noteSaveCopy', { documentId: documentModel.documentId, text: text() })); switching = false; installDocument(saved); }
  catch (error) { switching = false; updateControls(); notice(cleanError(error)); setStatus('Couldn’t save a copy', 'error'); }
};
$('locate-note').onclick = async () => {
  if (!documentModel) return;
  const token = generation;
  try { const located = await request('noteLocate', { documentId: documentModel.documentId }); if (generation !== token || !located?.documentId) return; documentModel = { ...documentModel, ...located }; showConflict({ ...located, changed: true, missing: false }); }
  catch (error) { notice(cleanError(error)); }
};
$('retry-save').onclick = () => void saveDocument();
$('dismiss-recovery').onclick = () => { $('recovery-banner').hidden = true; };
$('dismiss-notice').onclick = () => notice('');
$('notice-open-link').onclick = async () => { const url = noticeURL; if (!url) return; try { await request('browser', { url }); notice(''); } catch (error) { notice(cleanError(error)); } };
$('format-bold').onmousedown = $('format-italic').onmousedown = $('format-link').onmousedown = $('format-code').onmousedown = event => event.preventDefault();
$('format-bold').onclick = () => wrapSelection('**'); $('format-italic').onclick = () => wrapSelection('*');
$('format-link').onclick = linkSelection; $('format-code').onclick = () => wrapSelection('`');
$('divider').onpointerdown = event => { $('divider').setPointerCapture(event.pointerId); document.body.classList.add('resizing'); };
$('divider').onpointermove = event => { if (!$('divider').hasPointerCapture(event.pointerId)) return; const rect = $('workspace').getBoundingClientRect(); setSplit((event.clientX - rect.left) / rect.width * 100); };
$('divider').onpointerup = event => { $('divider').releasePointerCapture(event.pointerId); document.body.classList.remove('resizing'); };
$('divider').onlostpointercapture = () => document.body.classList.remove('resizing');
$('divider').onkeydown = event => {
  if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); setSplit(split + (event.key === 'ArrowLeft' ? -2 : 2)); }
  if (event.key === 'Home') { event.preventDefault(); setSplit(55); }
};
window.addEventListener('resize', () => { void updateOriginal(); positionSelectionTools(); });
window.addEventListener('keydown', event => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') { event.preventDefault(); void saveDocument(); }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'w') { event.preventDefault(); void quietRequest('close'); }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'f' && editor) { event.preventDefault(); compactPane('notes'); openSearchPanel(editor); }
  if (event.key === 'Escape') { notice(''); $('selection-tools').hidden = true; }
});
window.addEventListener('blur', () => { $('selection-tools').hidden = true; if (dirty()) void persistDraft().catch(() => {}); });
window.addEventListener('beforeunload', () => { destroyed = true; clearTimeout(saveTimer); clearTimeout(draftTimer); });
api.onEvent(async event => {
  if (event.event === 'source') await acceptSource(event);
  if (event.event === 'appearance') document.documentElement.dataset.appearance = event.appearance;
  if (event.event === 'error') notice(event.message);
  if (event.event === 'find' && editor) { compactPane('notes'); openSearchPanel(editor); }
  if (event.event === 'originalState') {
    $('original-frame').querySelector('.original-message').textContent = event.error || (event.loading ? 'Loading the original page…' : '');
    if (event.error) notice(event.error);
  }
  if (event.event === 'originalNavigation' && event.url) notice('Open this link in your browser?', event.url);
  if (event.event === 'flushCancelled') { switching = false; updateControls(); }
  if (event.event === 'flush') {
    let ok = false;
    try { ok = await flush(); } catch (error) { notice(cleanError(error)); }
    if (!ok) { switching = false; updateControls(); }
    await quietRequest('flushed', { requestId: event.requestId, ok });
  }
});
try { const value = Number(localStorage.getItem('read-note-split')); if (value >= 30 && value <= 70) split = value; } catch {}
document.documentElement.style.setProperty('--split', split + '%');
$('divider').setAttribute('aria-valuenow', String(Math.round(split)));
setInterval(() => { if (!destroyed) void checkExternal(); }, 2000);
request('init').then(async data => {
  await acceptSource(data);
  if (data.preview) window.workspaceTest = {
    getState: () => ({ source, notes, document: documentModel, dirty: dirty(), conflict, sourceMode, original, text: text(), status: $('save-status-text').textContent }),
    setText: value => { if (!editor) throw new Error('Connect a vault first.'); editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: value } }); },
    save: saveDocument, check: checkExternal, chooseVault, setOriginal
  };
  await quietRequest('ready');
}).catch(error => { $('article-loading').hidden = true; $('reader-empty').hidden = false; $('reader-error').textContent = cleanError(error); $('note-loading').hidden = true; setStatus('Couldn’t open workspace', 'error'); });
