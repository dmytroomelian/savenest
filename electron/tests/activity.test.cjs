'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { JSDOM, VirtualConsole } = require('jsdom');

const rendererDirectory = path.resolve(__dirname, '../renderer');
const html = readFileSync(path.join(rendererDirectory, 'index.html'), 'utf8');
const scripts = ['launcher-model.js', 'activity.js', 'renderer.js']
  .map(name => readFileSync(path.join(rendererDirectory, name), 'utf8'));
const currentYear = new Date().getFullYear();
const flush = async (count = 4) => { for (let index = 0; index < count; index += 1) await new Promise(resolve => setTimeout(resolve, 0)); };
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const link = (id, extra = {}) => {
  const action = extra.action || (extra.finished === true ? 'finished' : 'saved');
  const eventID = extra.eventID || `link-${id}:${action}`;
  const occurredAt = extra.occurredAt || '2026-01-01T17:00:00.000Z';
  return {
    id: `link-${id}`, title: `Link ${id}`, url: `https://example.com/${id}`, domain: 'example.com',
    ...extra, eventID, action, occurredAt,
    saved: action === 'saved', finished: action === 'finished'
  };
};
function summaryValue(ui, label) {
  const card = [...ui.byID('activity-summary').querySelectorAll('.activity-card')]
    .find(node => node.querySelector('.activity-card-label')?.textContent === label);
  return card?.querySelector('.activity-card-value')?.textContent;
}

function launcher(t, initial = {}) {
  const errors = [], calls = [];
  const virtualConsole = new VirtualConsole();
  virtualConsole.on('jsdomError', error => errors.push(error));
  const dom = new JSDOM(html, { url: 'https://savenest.test/index.html', runScripts: 'outside-only', pretendToBeVisual: true, virtualConsole });
  const { window } = dom, { document } = window;
  let onEvent;
  let handler = request => makeResponse(request);
  const makeResponse = request => ({
    year: request.year,
    years: [...new Set([currentYear, currentYear - 1, currentYear - 2, request.year])].sort((a, b) => b - a),
    savedCount: 0, finishedCount: 0, unfinishedCount: 0, undatedFinishedCount: 0,
    days: daysFor(request.year), links: [], totalLinks: 0, offset: request.offset || 0, hasMore: false
  });
  window.savenest = {
    command: async request => {
      calls.push(JSON.parse(JSON.stringify(request)));
      return request.command === 'activity' ? handler(request) : true;
    },
    onEvent: callback => { onEvent = callback; }
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
  const calendar = window.SavenestActivity.calendar;
  const todayKey = calendar.formatDate(new Date());
  const daysFor = year => calendar.yearInfo(year).cells.filter(Boolean)
    .map(date => ({ date: calendar.formatDate(date), saved: 0, finished: 0 }));
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
    const button = [...document.querySelectorAll('#action-options button')]
      .find(node => node.querySelector('.action-title')?.textContent === title);
    assert.ok(button, `Actions must expose ${title}`);
    return button;
  };
  const openActivity = async () => { byID('open-activity').click(); await flush(); };
  return {
    window, document, calls, update, byID, key, action, openActivity, calendar, todayKey, daysFor,
    makeResponse: request => makeResponse(request),
    setActivity(next) { handler = next; },
    activityCalls: () => calls.filter(call => call.command === 'activity'),
    sendEvent(event) { onEvent(event); },
    route: () => document.body.dataset.view
  };
}

test('Activity opens from the footer and Actions, preserves scoped search, and Back returns to search', async t => {
  const ui = launcher(t, { scope: 'Saved', query: 'kept query', rows: [] });
  assert.equal(ui.window.LauncherModel.commands('heatmap')[0].ui, 'activity');
  assert.equal(ui.window.LauncherModel.commands('dashboard')[0].title, 'View activity');

  await ui.openActivity();
  assert.equal(ui.route(), 'activity');
  assert.equal(ui.byID('route-title').textContent, 'Activity');
  assert.equal(ui.byID('open-activity').disabled, false);
  assert.equal(ui.byID('primary').textContent.includes('Back to search'), true);
  assert.deepEqual(ui.calls[0], { command: 'view', view: 'activity' });
  const request = ui.activityCalls()[0];
  assert.equal(request.year, currentYear);
  assert.equal(request.kind, 'all');
  assert.equal(request.day, ui.todayKey);
  assert.equal(request.limit, 100);

  ui.byID('primary').click();
  await flush();
  assert.equal(ui.route(), 'root');
  assert.equal(ui.byID('search').value, 'kept query');
  assert.equal(ui.byID('scope').value, 'Saved');
  assert.deepEqual(ui.calls.at(-1), { command: 'view', view: 'root' });

  ui.byID('actions').click();
  ui.action('View activity').click();
  await flush();
  assert.equal(ui.route(), 'activity');
});

test('Activity entry is unavailable for drafts and tab selections and cannot abandon them', async t => {
  const draft = launcher(t, { captureDraft: { id: 'draft:1', title: 'Draft', url: 'https://example.com/draft', note: '', tags: [] } });
  assert.equal(draft.route(), 'editor');
  assert.equal(draft.byID('open-activity').disabled, true);
  draft.byID('open-activity').click();
  await flush();
  assert.equal(draft.route(), 'editor');
  assert.equal(draft.activityCalls().length, 0);

  const selection = launcher(t, { captureSelection: { id: 'selection:1', links: [{ id: 'tab:1', title: 'Tab', url: 'https://example.com/tab' }] } });
  assert.equal(selection.route(), 'selection');
  assert.equal(selection.byID('open-activity').disabled, true);
  selection.byID('open-activity').click();
  await flush();
  assert.equal(selection.route(), 'selection');
  assert.equal(selection.activityCalls().length, 0);
});

test('daily filters and year changes request matching data and select a usable day', async t => {
  const ui = launcher(t, {});
  const previous = currentYear - 1;
  const savedDay = `${previous}-03-05`, finishedDay = `${previous}-06-07`;
  ui.setActivity(request => {
    const response = ui.makeResponse(request);
    const days = ui.daysFor(request.year);
    if (request.year === previous) {
      for (const day of days) {
        if (day.date === savedDay) day.saved = 2;
        if (day.date === finishedDay) day.finished = 1;
      }
      response.savedCount = 2; response.finishedCount = 1;
    } else {
      for (const day of days) if (day.date === ui.todayKey) { day.saved = 3; day.finished = 2; }
      response.savedCount = 3; response.finishedCount = 2;
    }
    response.days = days;
    if (request.day) {
      const day = days.find(value => value.date === request.day);
      response.totalLinks = day && (day.saved + day.finished) ? 1 : 0;
      response.links = response.totalLinks ? [link('day', { finished: Boolean(day?.finished) })] : [];
    }
    return response;
  });
  await ui.openActivity();
  assert.equal(summaryValue(ui, `Saved in ${currentYear}`), '3');
  assert.equal(summaryValue(ui, `Finished in ${currentYear}`), '2');

  ui.byID('activity-filters').querySelector('[data-kind="saved"]').click();
  await flush();
  let request = ui.activityCalls().at(-1);
  assert.equal(request.kind, 'saved');
  assert.equal(request.day, ui.todayKey);
  assert.equal(ui.byID('activity-filters').querySelector('[data-kind="saved"]').getAttribute('aria-pressed'), 'true');

  const select = ui.byID('activity-year');
  select.value = String(previous);
  select.dispatchEvent(new ui.window.Event('change', { bubbles: true }));
  await flush(6);
  const yearRequests = ui.activityCalls().slice(-2);
  assert.equal(yearRequests[0].year, previous);
  assert.equal(yearRequests[0].kind, 'saved');
  assert.equal(yearRequests[0].day, undefined);
  assert.equal(yearRequests[1].year, previous);
  assert.equal(yearRequests[1].kind, 'saved');
  assert.equal(yearRequests[1].day, savedDay);
  const selected = ui.byID('activity-grid').querySelector(`[data-date="${savedDay}"]`);
  assert.equal(selected.getAttribute('aria-pressed'), 'true');
  assert.match(ui.byID('activity-day-title').textContent, new RegExp(String(previous)));
});

test('Activity paginates 250 unique events in batches of 100 and renders titles as text', async t => {
  const ui = launcher(t, {});
  ui.setActivity(request => {
    const response = ui.makeResponse(request);
    if (!request.day) return response;
    const offset = request.offset || 0;
    const count = Math.max(0, Math.min(100, 250 - offset));
    response.links = Array.from({ length: count }, (_, index) => {
      const number = offset + index;
      return link(String(number), { title: number === 0 ? '<img src=x onerror=alert(1)>' : `Saved ${number}` });
    });
    response.totalLinks = 250;
    response.offset = offset;
    response.hasMore = offset + count < 250;
    return response;
  });
  await ui.openActivity();
  assert.equal(ui.byID('activity-links').querySelectorAll('.activity-link').length, 100);
  assert.equal(ui.byID('activity-links').querySelector('img'), null);
  assert.equal(ui.byID('activity-links').textContent.includes('<img src=x onerror=alert(1)>'), true);
  ui.byID('activity-more').click();
  await flush();
  assert.equal(ui.byID('activity-links').querySelectorAll('.activity-link').length, 200);
  ui.byID('activity-more').click();
  await flush();
  assert.equal(ui.byID('activity-links').querySelectorAll('.activity-link').length, 250);
  assert.equal(new Set([...ui.byID('activity-links').querySelectorAll('.activity-link')].map(node => node.dataset.id)).size, 250);
  assert.deepEqual(ui.activityCalls().map(call => call.offset), [0, 100, 200]);
  assert.equal(ui.byID('activity-more').hidden, true);
});

test('daily events show action, local time and safe titles without pills', async t => {
  const ui = launcher(t, {});
  const savedAt = '2026-06-10T16:00:00.000Z';
  const finishedAt = '2026-06-10T23:30:00.000Z';
  ui.setActivity(request => {
    const response = ui.makeResponse(request);
    if (!request.day) return response;
    response.links = [
      link('shared', { action: 'finished', eventID: 'link-shared:finished', occurredAt: finishedAt, title: '<b>Finished title</b>' }),
      link('shared', { action: 'saved', eventID: 'link-shared:saved', occurredAt: savedAt, title: 'Saved title' })
    ];
    response.totalLinks = 2;
    return response;
  });
  await ui.openActivity();
  const rows = [...ui.byID('activity-links').querySelectorAll('.activity-link')];
  assert.equal(rows.length, 2);
  assert.equal(ui.byID('activity-day-count').textContent, '2 events');
  assert.equal(rows[0].dataset.eventId, 'link-shared:finished');
  assert.equal(rows[0].dataset.id, 'link-shared');
  assert.equal(rows[0].dataset.action, 'finished');
  assert.equal(rows[0].querySelector('.activity-link-action').textContent, 'Finished');
  assert.equal(rows[0].querySelector('.activity-link-title').textContent, '<b>Finished title</b>');
  assert.equal(rows[0].querySelector('.activity-link-domain').textContent, 'example.com');
  const normalize = value => String(value).replace(/\s+/g, ' ').trim();
  const expected = iso => normalize(new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }));
  for (const [index, iso] of [[0, finishedAt], [1, savedAt]]) {
    const time = rows[index].querySelector('time.activity-link-time');
    assert.equal(time.dateTime, iso);
    assert.equal(normalize(time.textContent), expected(iso));
    assert.match(time.title, /2026/);
    assert.match(time.title, / at /);
  }
  assert.equal(ui.byID('activity-links').querySelectorAll('svg.activity-link-icon[width="14"]').length, 2);
  assert.equal(ui.byID('activity-links').querySelector('.activity-badge'), null);
  assert.equal(ui.byID('activity-links').querySelector('.activity-link-badges'), null);
  rows[1].focus();
  ui.sendEvent({ event: 'activityChanged' });
  await flush();
  assert.equal(ui.document.activeElement.dataset.eventId, 'link-shared:saved',
    'refresh must retain the second event, not jump to the first event for the same link');
});

test('both actions for one link survive pagination and focus restoration', async t => {
  const ui = launcher(t, {});
  const sharedFinished = link('shared', { action: 'finished', eventID: 'link-shared:finished', occurredAt: '2026-06-10T23:30:00.000Z' });
  const sharedSaved = link('shared', { action: 'saved', eventID: 'link-shared:saved', occurredAt: '2026-06-10T16:00:00.000Z' });
  ui.setActivity(request => {
    const response = ui.makeResponse(request);
    if (!request.day) return response;
    const offset = request.offset || 0;
    response.links = offset === 0
      ? [sharedFinished, ...Array.from({ length: 99 }, (_, index) => link(String(index)))]
      : [sharedSaved];
    response.totalLinks = 101;
    response.hasMore = offset === 0;
    return response;
  });
  await ui.openActivity();
  assert.equal(ui.byID('activity-links').querySelectorAll('.activity-link').length, 100);
  assert.equal(ui.byID('activity-links').querySelectorAll('[data-id="link-shared"]').length, 1);
  ui.byID('activity-more').click();
  await flush();
  assert.equal(ui.byID('activity-links').querySelectorAll('.activity-link').length, 101);
  const shared = [...ui.byID('activity-links').querySelectorAll('[data-id="link-shared"]')];
  assert.equal(shared.length, 2);
  assert.deepEqual(shared.map(node => node.dataset.eventId), ['link-shared:finished', 'link-shared:saved']);
  shared[0].focus();
  assert.equal(ui.document.activeElement, shared[0]);
  ui.sendEvent({ event: 'activityChanged' });
  await flush();
  assert.equal(ui.byID('activity-links').querySelectorAll('.activity-link').length, 100);
  assert.equal(ui.document.activeElement.dataset.eventId, 'link-shared:finished');
});

test('out-of-order Activity responses cannot replace newer filter results', async t => {
  const ui = launcher(t, {});
  const first = deferred(), second = deferred();
  let count = 0;
  ui.setActivity(request => {
    count += 1;
    return count === 1 ? first.promise : second.promise;
  });
  ui.byID('open-activity').click();
  await flush();
  ui.byID('activity-filters').querySelector('[data-kind="saved"]').click();
  await flush();
  const secondResponse = ui.makeResponse({ year: currentYear, kind: 'saved' });
  secondResponse.savedCount = 99;
  second.resolve(secondResponse);
  await flush();
  assert.equal(summaryValue(ui, `Saved in ${currentYear}`), '99');
  const firstResponse = ui.makeResponse({ year: currentYear });
  firstResponse.savedCount = 1;
  first.resolve(firstResponse);
  await flush();
  assert.equal(summaryValue(ui, `Saved in ${currentYear}`), '99');
});

test('changing filters during a year request uses the new year and ignores the old year response', async t => {
  const ui = launcher(t, {});
  await ui.openActivity();
  const previous = currentYear - 1;
  const yearRequest = deferred();
  const requests = [];
  ui.setActivity(request => {
    requests.push(request);
    if (requests.length === 1) return yearRequest.promise;
    const response = ui.makeResponse(request);
    response.savedCount = 5;
    return response;
  });
  const select = ui.byID('activity-year');
  select.value = String(previous);
  select.dispatchEvent(new ui.window.Event('change', { bubbles: true }));
  await flush(1);
  ui.byID('activity-filters').querySelector('[data-kind="saved"]').click();
  await flush(4);
  assert.equal(requests[0].year, previous);
  assert.equal(requests[0].day, undefined);
  assert.equal(requests[1].year, previous);
  assert.equal(requests[1].kind, 'saved');
  assert.equal(requests[1].day, `${previous}-01-01`);
  const old = ui.makeResponse({ year: previous });
  old.savedCount = 777;
  yearRequest.resolve(old);
  await flush();
  assert.equal(summaryValue(ui, `Saved in ${previous}`), '5');
});

test('a loading or failed year never relabels previous-year totals', async t => {
  const ui = launcher(t, {});
  ui.setActivity(request => ({ ...ui.makeResponse(request), savedCount: 17, finishedCount: 6 }));
  await ui.openActivity();
  assert.equal(summaryValue(ui, `Saved in ${currentYear}`), '17');
  const pending = deferred();
  ui.setActivity(() => pending.promise);
  const previous = currentYear - 1;
  ui.byID('activity-year').value = String(previous);
  ui.byID('activity-year').dispatchEvent(new ui.window.Event('change'));
  await flush();
  assert.equal(summaryValue(ui, `Saved in ${previous}`), '—');
  assert.equal(summaryValue(ui, `Finished in ${previous}`), '—');
  pending.reject(new Error('Connection unavailable'));
  await flush();
  assert.equal(summaryValue(ui, `Saved in ${previous}`), '—');
  assert.match(ui.byID('activity-status').textContent, /Connection unavailable/);
});

test('changing filter invalidates pagination and re-enables Show more', async t => {
  const ui = launcher(t, {});
  const page = deferred();
  let calls = 0;
  ui.setActivity(request => {
    calls += 1;
    if (request.kind === 'saved') {
      const response = ui.makeResponse(request);
      response.links = [link('saved-a'), link('saved-b')];
      response.totalLinks = 2;
      response.hasMore = true;
      return response;
    }
    if (calls === 2) return page.promise;
    const response = ui.makeResponse(request);
    response.links = Array.from({ length: 100 }, (_, index) => link(String(index)));
    response.totalLinks = 250;
    response.hasMore = true;
    return response;
  });
  await ui.openActivity();
  ui.byID('activity-more').click();
  await flush(1);
  assert.equal(ui.byID('activity-more').disabled, true);
  ui.byID('activity-filters').querySelector('[data-kind="saved"]').click();
  await flush();
  assert.equal(ui.byID('activity-links').querySelectorAll('.activity-link').length, 2);
  assert.equal(ui.byID('activity-more').disabled, false);
  const stale = ui.makeResponse({ year: currentYear, kind: 'all' });
  stale.links = [link('stale')];
  stale.totalLinks = 101;
  stale.hasMore = true;
  page.resolve(stale);
  await flush();
  assert.equal(ui.byID('activity-links').querySelectorAll('.activity-link').length, 2);
  assert.equal(ui.byID('activity-more').disabled, false);
  ui.byID('activity-more').click();
  await flush();
  assert.equal(ui.activityCalls().at(-1).offset, 2);
});

test('keyboard selection and refreshes retain the focused day and link', async t => {
  const ui = launcher(t, {});
  ui.setActivity(request => {
    const response = ui.makeResponse(request);
    if (request.day) {
      response.links = [link('one'), link('two')];
      response.totalLinks = 2;
    }
    return response;
  });
  await ui.openActivity();
  const today = ui.byID('activity-grid').querySelector(`[data-date="${ui.todayKey}"]`);
  const yesterdayKey = ui.calendar.formatDate(ui.calendar.addDays(ui.calendar.parseDate(ui.todayKey), -1));
  const yesterday = ui.byID('activity-grid').querySelector(`[data-date="${yesterdayKey}"]`);
  yesterday.focus();
  ui.key('ArrowDown', yesterday);
  assert.equal(ui.document.activeElement.dataset.date, ui.todayKey);
  ui.key('ArrowUp', ui.document.activeElement);
  assert.equal(ui.document.activeElement.dataset.date, yesterdayKey);
  assert.equal(ui.byID('activity-grid').querySelectorAll('[data-date][tabindex="0"]').length, 1);
  ui.key('Enter', ui.document.activeElement);
  await flush();
  assert.equal(ui.activityCalls().at(-1).day, yesterdayKey);
  assert.equal(ui.document.activeElement.dataset.date, yesterdayKey);
  assert.equal(ui.byID('activity-grid').querySelector(`[data-date="${yesterdayKey}"]`).getAttribute('aria-pressed'), 'true');
  assert.match(ui.byID('activity-grid').querySelector(`[data-date="${yesterdayKey}"]`).getAttribute('aria-label'), /saved/);

  const before = ui.activityCalls().length;
  ui.update({ loading: false, rows: [] });
  await flush();
  assert.equal(ui.activityCalls().length, before, 'generic state snapshots must not reload Activity');
  ui.sendEvent({ event: 'activityChanged' });
  await flush();
  assert.equal(ui.activityCalls().length, before + 1);
  assert.equal(ui.document.activeElement.dataset.date, yesterdayKey);
  ui.sendEvent({ event: 'focus', reset: false });
  await flush();
  assert.equal(ui.activityCalls().length, before + 2);

  const firstLink = ui.byID('activity-links').querySelector('.activity-link');
  firstLink.focus();
  ui.sendEvent({ event: 'activityChanged' });
  await flush();
  assert.equal(ui.document.activeElement.dataset.eventId, firstLink.dataset.eventId);
});

test('Activity shows truthful empty, legacy and error/retry states', async t => {
  const ui = launcher(t, {});
  const previous = currentYear - 1;
  ui.setActivity(request => {
    const response = ui.makeResponse(request);
    response.years = [currentYear, previous];
    response.undatedFinishedCount = 4;
    response.finishedCount = 2;
    return response;
  });
  await ui.openActivity();
  assert.match(ui.byID('activity-links').textContent, new RegExp(`No activity in ${currentYear}`));
  assert.match(ui.byID('activity-undated').textContent, /4 archived links/);
  assert.match(ui.byID('activity-undated').textContent, /Older archive dates are unknown/);

  const failing = launcher(t, {});
  let attempts = 0;
  failing.setActivity(() => {
    attempts += 1;
    if (attempts === 1) throw new Error('Helper unavailable');
    return failing.makeResponse({ year: currentYear });
  });
  await failing.openActivity();
  assert.match(failing.byID('activity-status').textContent, /Helper unavailable/);
  assert.equal(failing.byID('activity-retry').hidden, false);
  failing.byID('activity-retry').click();
  await flush();
  assert.equal(failing.byID('activity-status').hidden, true);
  assert.match(failing.byID('activity-summary').textContent, new RegExp(`Saved in ${currentYear}`));
  assert.equal(attempts, 2);

  const yearEmpty = launcher(t, {});
  yearEmpty.setActivity(request => yearEmpty.makeResponse(request));
  await yearEmpty.openActivity();
  assert.match(yearEmpty.byID('activity-links').textContent, new RegExp(`No activity in ${currentYear}`));
});

test('Activity calendar is Monday-first, leap-aware, supports 54-week years and disables future dates', async t => {
  const ui = launcher(t, {});
  await ui.openActivity();
  const months = [...ui.byID('activity-months').querySelectorAll('.activity-month')].map(node => node.textContent);
  assert.deepEqual(months, ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']);
  assert.equal(ui.byID('activity-weekdays').children.length, 7);
  const yearRows = ui.calendar.yearInfo(2012);
  assert.equal(yearRows.weeks, 54);
  assert.equal(yearRows.cells.length, 378);
  assert.equal(yearRows.cells.filter(Boolean).length, 366);
  assert.equal(ui.calendar.daysInYear(2024), 366);
  assert.equal(ui.calendar.daysInYear(2023), 365);
  assert(ui.calendar.parseDate('2024-02-29'));
  assert.equal(ui.calendar.parseDate('2023-02-29'), null);
  const today = ui.calendar.parseDate(ui.todayKey);
  const tomorrow = ui.calendar.formatDate(ui.calendar.addDays(today, 1));
  const future = ui.byID('activity-grid').querySelector(`[data-date="${tomorrow}"]`);
  if (future) {
    assert.equal(future.disabled, true);
    assert.match(future.getAttribute('aria-label'), /future date/);
  }
  const roving = ui.byID('activity-grid').querySelectorAll('[data-date][tabindex="0"]');
  assert.equal(roving.length, 1);
  assert.equal(ui.byID('activity-year').tabIndex, 0);
  assert(ui.byID('activity-filters').querySelector('button').tabIndex !== -1);
});

test('root page shortcuts do nothing while Activity is open', async t => {
  const ui = launcher(t, { scope: 'Saved', rows: [{ id: 'saved:one', title: 'Page', url: 'https://example.com', domain: 'example.com', isSaved: true }] });
  await ui.openActivity();
  const before = ui.calls.length;
  for (const [value, modifiers] of [['e', { metaKey: true }], ['f', { metaKey: true, shiftKey: true }], ['ArrowDown', {}], ['Enter', {}]]) {
    ui.key(value, ui.document.body, modifiers);
  }
  await flush();
  assert.equal(ui.calls.length, before);
  assert.equal(ui.route(), 'activity');
});
