(function (root) {
  'use strict';

  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const MONTHS_LONG = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const WEEKDAYS_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

  function pad(value, size = 2) { return String(value).padStart(size, '0'); }
  function makeDate(year, month, day) {
    const value = new Date(0);
    value.setHours(0, 0, 0, 0);
    value.setFullYear(year, month, day);
    value.setHours(0, 0, 0, 0);
    return value;
  }
  function startOfDay(value) {
    const date = new Date(value.getTime());
    date.setHours(0, 0, 0, 0);
    return date;
  }
  function addDays(value, amount) {
    const date = new Date(value.getTime());
    date.setDate(date.getDate() + amount);
    date.setHours(0, 0, 0, 0);
    return date;
  }
  function formatDate(value) {
    return `${pad(value.getFullYear(), 4)}-${pad(value.getMonth() + 1)}-${pad(value.getDate())}`;
  }
  function parseDate(raw) {
    if (typeof raw !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(raw)) return null;
    const year = Number(raw.slice(0, 4)), month = Number(raw.slice(5, 7)), day = Number(raw.slice(8, 10));
    if (year < 1 || year > 9998 || month < 1 || month > 12 || day < 1) return null;
    const date = makeDate(year, month - 1, day);
    return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day ? date : null;
  }
  function dateLabel(value) {
    return `${WEEKDAYS_LONG[value.getDay()]}, ${MONTHS_LONG[value.getMonth()]} ${value.getDate()}, ${value.getFullYear()}`;
  }
  function mondayIndex(value) { return (value.getDay() + 6) % 7; }
  function daysInMonth(year, month) { return makeDate(year, month + 1, 0).getDate(); }
  function daysInYear(year) {
    let total = 0;
    for (let month = 0; month < 12; month += 1) total += daysInMonth(year, month);
    return total;
  }
  function yearInfo(year) {
    const first = makeDate(year, 0, 1), last = makeDate(year, 11, 31);
    const count = daysInYear(year), offset = mondayIndex(first), lastOffset = 6 - mondayIndex(last);
    const weeks = (offset + count + lastOffset) / 7;
    const cells = [];
    let cursor = addDays(first, -offset);
    for (let index = 0; index < weeks * 7; index += 1) {
      cells.push(cursor.getFullYear() === year ? new Date(cursor.getTime()) : null);
      cursor = addDays(cursor, 1);
    }
    const monthStarts = [];
    let daysBefore = 0;
    for (let month = 0; month < 12; month += 1) {
      monthStarts.push({ month, week: Math.floor((offset + daysBefore) / 7) });
      daysBefore += daysInMonth(year, month);
    }
    return { year, first, last, offset, weeks, cells, monthStarts, count };
  }
  function lastValidDate(year, today) {
    if (year < today.getFullYear()) return makeDate(year, 11, 31);
    if (year > today.getFullYear()) return null;
    return startOfDay(today);
  }
  function dayCount(day, kind) {
    if (!day) return 0;
    const saved = Number(day.saved) || 0, finished = Number(day.finished) || 0;
    return kind === 'saved' ? saved : kind === 'finished' ? finished : saved + finished;
  }
  function intensity(count) { return count <= 0 ? 0 : count === 1 ? 1 : count <= 3 ? 2 : count <= 7 ? 3 : 4; }
  function eventAction(link) {
    if (link && (link.action === 'saved' || link.action === 'finished')) return link.action;
    return link && link.finished && !link.saved ? 'finished' : 'saved';
  }
  function eventTime(raw) {
    const value = new Date(raw);
    return Number.isNaN(value.getTime()) ? '' : value.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
  }
  function eventStamp(raw) {
    const value = new Date(raw);
    return Number.isNaN(value.getTime()) ? '' : `${dateLabel(value)} at ${eventTime(raw)}`;
  }
  function cleanError(error) {
    return String(error && error.message || error || 'Savenest could not load activity.')
      .replace(/^Error invoking remote method '[^']+': Error: /, '');
  }

  function create(options = {}) {
    const doc = options.document || root.document;
    const command = options.command || (request => root.savenest.command(request));
    const node = id => doc.getElementById(id);
    const nodes = {
      view: node('activity-view'), filters: node('activity-filters'), year: node('activity-year'),
      summary: node('activity-summary'), undated: node('activity-undated'), months: node('activity-months'),
      weekdays: node('activity-weekdays'), grid: node('activity-grid'), hover: node('activity-hover'),
      dayTitle: node('activity-day-title'), dayCount: node('activity-day-count'), links: node('activity-links'),
      more: node('activity-more'), status: node('activity-status'), retry: node('activity-retry')
    };
    if (!nodes.view || !nodes.grid) throw new Error('Activity view is unavailable.');
    const today = startOfDay(new Date());
    const state = {
      open: false, initialized: false, year: today.getFullYear(), loadedYear: null, kind: 'all',
      selected: formatDate(today), roving: formatDate(today), years: [today.getFullYear()],
      days: [], links: [], totalLinks: 0, hasMore: false, offset: 0,
      savedCount: 0, finishedCount: 0, unfinishedCount: 0, undatedFinishedCount: 0,
      loading: false, loadingMore: false, error: '', token: 0, retry: null
    };
    const counts = new Map();

    function el(tag, className, text) {
      const value = doc.createElement(tag);
      if (className) value.className = className;
      if (text !== undefined) value.textContent = text;
      return value;
    }
    function normalize(raw) {
      const data = raw && typeof raw === 'object' ? raw : {};
      return {
        year: Number.isInteger(data.year) ? data.year : state.year,
        years: Array.isArray(data.years) ? data.years.filter(value => Number.isInteger(value)) : state.years,
        savedCount: Number(data.savedCount) || 0,
        finishedCount: Number(data.finishedCount) || 0,
        unfinishedCount: Number(data.unfinishedCount) || 0,
        undatedFinishedCount: Number(data.undatedFinishedCount) || 0,
        days: Array.isArray(data.days) ? data.days.filter(day => day && parseDate(day.date)) : [],
        links: Array.isArray(data.links) ? data.links.filter(link => link && link.id && link.eventID) : [],
        totalLinks: Number(data.totalLinks) || 0,
        hasMore: Boolean(data.hasMore)
      };
    }
    function eventIcon(action) {
      const svg = doc.createElementNS('http://www.w3.org/2000/svg', 'svg');
      svg.setAttribute('viewBox', '0 0 16 16');
      svg.setAttribute('width', '14');
      svg.setAttribute('height', '14');
      svg.setAttribute('class', 'activity-link-icon');
      svg.setAttribute('aria-hidden', 'true');
      svg.setAttribute('focusable', 'false');
      const path = doc.createElementNS('http://www.w3.org/2000/svg', 'path');
      path.setAttribute('d', action === 'finished' ? 'M3.5 8.3 6.4 11.2 12.5 4.8' : 'M4.5 2.5h7v11l-3.5-2.6-3.5 2.6z');
      path.setAttribute('fill', 'none');
      path.setAttribute('stroke', 'currentColor');
      path.setAttribute('stroke-width', '1.4');
      path.setAttribute('stroke-linecap', 'round');
      path.setAttribute('stroke-linejoin', 'round');
      svg.append(path);
      return svg;
    }
    function refreshCounts() {
      counts.clear();
      for (const day of state.days) counts.set(day.date, { saved: Number(day.saved) || 0, finished: Number(day.finished) || 0 });
    }
    function countsFor(key) { return counts.get(key) || { saved: 0, finished: 0 }; }
    function summaryCard(label, value, detail) {
      const card = el('div', 'activity-card');
      card.append(el('span', 'activity-card-value', String(value)), el('span', 'activity-card-label', label));
      if (detail) card.append(el('span', 'activity-card-detail', detail));
      return card;
    }
    function renderSummary() {
      const hasYear = state.loadedYear === state.year;
      nodes.summary.replaceChildren(
        summaryCard(`Saved in ${state.year}`, hasYear ? state.savedCount : '—'),
        summaryCard(`Finished in ${state.year}`, hasYear ? state.finishedCount : '—'),
        summaryCard('Still to finish (all time)', state.unfinishedCount)
      );
      nodes.undated.hidden = state.undatedFinishedCount <= 0;
      nodes.undated.textContent = state.undatedFinishedCount > 0
        ? `${state.undatedFinishedCount} archived link${state.undatedFinishedCount === 1 ? '' : 's'} ${state.undatedFinishedCount === 1 ? 'has' : 'have'} no recorded finish date. Older archive dates are unknown, so those finishes are not placed on the calendar.`
        : '';
    }
    function renderFilters() {
      for (const button of nodes.filters.querySelectorAll('[data-kind]')) {
        const active = button.dataset.kind === state.kind;
        button.setAttribute('aria-pressed', String(active));
        button.classList.toggle('selected', active);
      }
    }
    function renderYears() {
      const years = new Set(state.years.filter(value => Number.isInteger(value) && value >= 1 && value <= 9998));
      years.add(state.year);
      const list = [...years].sort((a, b) => b - a);
      nodes.year.replaceChildren(...list.map(value => {
        const option = el('option', '', String(value));
        option.value = String(value);
        return option;
      }));
      nodes.year.value = String(state.year);
    }
    function renderMonths(info) {
      nodes.months.replaceChildren(...info.monthStarts.map(({ month, week }) => {
        const label = el('span', 'activity-month', MONTHS[month]);
        label.style.left = `${week * 12}px`;
        return label;
      }));
    }
    function renderWeekdays() {
      nodes.weekdays.replaceChildren(...WEEKDAYS.map(day => el('span', '', day)));
    }
    function showHover(key, value) {
      const date = parseDate(key);
      if (!date) return;
      const current = value || countsFor(key);
      nodes.hover.textContent = `${dateLabel(date)} · ${current.saved} saved · ${current.finished} finished`;
    }
    function updateRoving() {
      for (const cell of nodes.grid.querySelectorAll('[data-date]')) cell.tabIndex = cell.dataset.date === state.roving ? 0 : -1;
    }
    function renderCalendar() {
      const info = yearInfo(state.year);
      const todayKey = formatDate(startOfDay(new Date()));
      const minKey = formatDate(info.first);
      const maxDate = lastValidDate(state.year, startOfDay(new Date()));
      const maxKey = maxDate ? formatDate(maxDate) : minKey;
      navLimits = { minKey, maxKey };
      const validRoving = state.roving && parseDate(state.roving)?.getFullYear() === state.year && state.roving <= todayKey;
      if (!validRoving) {
        const selectedValid = state.selected && parseDate(state.selected)?.getFullYear() === state.year && state.selected <= todayKey;
        state.roving = selectedValid ? state.selected : maxDate ? maxKey : minKey;
      }
      renderMonths(info);
      renderWeekdays();
      const cells = info.cells.map(cell => {
        if (!cell) {
          const blank = el('div', 'activity-cell activity-blank');
          blank.setAttribute('aria-hidden', 'true');
          return blank;
        }
        const key = formatDate(cell), value = countsFor(key);
        const future = key > todayKey;
        const count = dayCount(value, state.kind);
        const button = el('button', `activity-cell level-${intensity(count)}${future ? ' future' : ''}`);
        button.type = 'button';
        button.dataset.date = key;
        button.dataset.saved = String(value.saved);
        button.dataset.finished = String(value.finished);
        button.dataset.count = String(count);
        button.setAttribute('aria-pressed', String(key === state.selected));
        button.setAttribute('aria-label', `${dateLabel(cell)}: ${value.saved} saved, ${value.finished} finished${future ? ', future date' : ''}`);
        button.tabIndex = key === state.roving ? 0 : -1;
        button.disabled = future;
        if (key === state.selected) button.classList.add('selected');
        button.onclick = () => selectDay(key);
        button.onmouseenter = () => showHover(key, value);
        button.onmouseleave = () => showHover(state.selected, countsFor(state.selected));
        button.onfocus = () => {
          state.roving = key;
          updateRoving();
          showHover(key, value);
        };
        return button;
      });
      nodes.grid.replaceChildren(...cells);
      showHover(state.selected, countsFor(state.selected));
    }
    let navLimits = { minKey: '', maxKey: '' };
    function renderDay() {
      const date = parseDate(state.selected) || makeDate(state.year, 0, 1);
      nodes.dayTitle.textContent = dateLabel(date);
      nodes.dayCount.textContent = state.totalLinks
        ? `${state.totalLinks} event${state.totalLinks === 1 ? '' : 's'}`
        : '';
      const events = state.links.map(link => {
        const action = eventAction(link);
        const title = link.title || link.domain || link.url || 'Untitled link';
        const button = el('button', 'activity-link');
        button.type = 'button';
        button.dataset.id = link.id;
        button.dataset.eventId = link.eventID;
        button.dataset.action = action;
        button.title = `Open ${title}`;
        const line = el('span', 'activity-link-line');
        line.append(
          el('span', 'activity-link-action', action === 'finished' ? 'Finished' : 'Saved'),
          el('span', 'activity-link-title', title)
        );
        const text = el('span', 'activity-link-text');
        text.append(line, el('span', 'activity-link-domain', link.domain || ''));
        const time = doc.createElement('time');
        time.className = 'activity-link-time';
        if (link.occurredAt) {
          time.dateTime = link.occurredAt;
          time.textContent = eventTime(link.occurredAt);
          time.title = eventStamp(link.occurredAt);
        }
        button.append(eventIcon(action), text, time);
        button.onclick = () => openLink(link);
        return button;
      });
      if (!events.length && !state.loading) {
        const yearActive = state.days.some(day => dayCount(day, 'all') > 0);
        const message = !yearActive
          ? state.kind === 'saved' ? `No links saved in ${state.year}.`
            : state.kind === 'finished' ? `No links finished in ${state.year}.`
              : `No activity in ${state.year}.`
          : state.kind === 'saved' ? 'No links saved on this day.'
            : state.kind === 'finished' ? 'No links finished on this day.'
              : 'No activity on this day.';
        events.push(el('p', 'activity-empty', message));
      }
      nodes.links.replaceChildren(...events);
      nodes.more.hidden = !state.hasMore;
      nodes.more.disabled = state.loadingMore;
      nodes.more.textContent = state.loadingMore ? 'Loading…' : 'Show more';
    }
    function renderStatus() {
      if (state.error) {
        nodes.status.hidden = false;
        nodes.status.textContent = `Could not load activity. ${state.error}`;
        nodes.retry.hidden = false;
      } else if (state.loading) {
        nodes.status.hidden = false;
        nodes.status.textContent = 'Loading activity…';
        nodes.retry.hidden = true;
      } else {
        nodes.status.hidden = true;
        nodes.status.textContent = '';
        nodes.retry.hidden = true;
      }
    }
    function renderAll() {
      const focused = doc.activeElement;
      const focusedDay = focused && nodes.grid.contains(focused) && focused.dataset.date ? focused.dataset.date : null;
      const focusedEvent = focused && nodes.links.contains(focused) && focused.dataset.eventId ? focused.dataset.eventId : null;
      refreshCounts();
      renderFilters();
      renderYears();
      renderSummary();
      renderCalendar();
      renderDay();
      renderStatus();
      if (focusedDay) {
        const cell = [...nodes.grid.querySelectorAll('[data-date]')].find(value => value.dataset.date === focusedDay);
        if (cell && !cell.disabled) cell.focus();
      } else if (focusedEvent) {
        const event = [...nodes.links.querySelectorAll('[data-event-id]')]
          .find(value => value.dataset.eventId === focusedEvent);
        if (event) event.focus();
      }
    }

    async function request(values) {
      return command({ command: 'activity', ...values });
    }
    function apply(raw) {
      const data = normalize(raw);
      state.year = data.year;
      state.loadedYear = data.year;
      state.years = data.years;
      state.savedCount = data.savedCount;
      state.finishedCount = data.finishedCount;
      state.unfinishedCount = data.unfinishedCount;
      state.undatedFinishedCount = data.undatedFinishedCount;
      state.days = data.days;
      state.links = data.links;
      state.totalLinks = data.totalLinks;
      state.hasMore = data.hasMore;
      state.offset = data.links.length;
      if (!state.selected || parseDate(state.selected)?.getFullYear() !== state.year) {
        state.selected = formatDate(makeDate(state.year, 0, 1));
        state.roving = state.selected;
      }
    }
    function latestActivityDay(days, kind) {
      let best = null;
      for (const day of days) {
        if (dayCount(day, kind) <= 0) continue;
        const date = parseDate(day.date);
        if (!best || date > best.date) best = { date, key: day.date };
      }
      return best ? best.key : null;
    }
    function fail(error, token) {
      if (token !== state.token) return;
      state.loading = false;
      state.loadingMore = false;
      state.error = cleanError(error);
      renderAll();
    }
    async function loadCurrent({ clearLinks = false } = {}) {
      const token = ++state.token;
      state.loading = true;
      state.loadingMore = false;
      state.error = '';
      state.retry = () => loadCurrent({ clearLinks: true });
      if (clearLinks) { state.links = []; state.totalLinks = 0; state.hasMore = false; state.offset = 0; }
      renderAll();
      try {
        const raw = await request({ year: state.year, kind: state.kind, day: state.selected, offset: 0, limit: 100 });
        if (token !== state.token || !state.open) return;
        apply(raw);
        state.loading = false;
        renderAll();
      } catch (error) { fail(error, token); }
    }
    async function selectYear(year) {
      if (!Number.isInteger(year) || year < 1 || year > 9998) return;
      state.year = year;
      state.selected = formatDate(makeDate(year, 0, 1));
      state.roving = state.selected;
      state.days = [];
      state.links = []; state.totalLinks = 0; state.hasMore = false; state.offset = 0;
      state.loading = true; state.loadingMore = false; state.error = '';
      state.retry = () => selectYear(year);
      const token = ++state.token;
      renderAll();
      try {
        const yearRaw = await request({ year: state.year, kind: state.kind, offset: 0, limit: 100 });
        if (token !== state.token || !state.open) return;
        const yearData = normalize(yearRaw);
        state.loadedYear = year;
        state.years = yearData.years;
        state.days = yearData.days;
        state.savedCount = yearData.savedCount;
        state.finishedCount = yearData.finishedCount;
        state.unfinishedCount = yearData.unfinishedCount;
        state.undatedFinishedCount = yearData.undatedFinishedCount;
        state.selected = latestActivityDay(yearData.days, state.kind) || formatDate(makeDate(year, 0, 1));
        state.roving = state.selected;
        refreshCounts();
        renderAll();
        const dayRaw = await request({ year: state.year, kind: state.kind, day: state.selected, offset: 0, limit: 100 });
        if (token !== state.token || !state.open) return;
        apply(dayRaw);
        state.loading = false;
        renderAll();
      } catch (error) { fail(error, token); }
    }
    function selectKind(kind) {
      if (!['all', 'saved', 'finished'].includes(kind) || kind === state.kind) return;
      state.kind = kind;
      void loadCurrent({ clearLinks: true });
    }
    function selectDay(key) {
      if (!parseDate(key) || key === state.selected) return;
      if (key < navLimits.minKey || key > navLimits.maxKey) return;
      state.selected = key;
      state.roving = key;
      void loadCurrent({ clearLinks: true });
    }
    function focusDay(date) {
      let key = formatDate(date);
      if (key < navLimits.minKey) key = navLimits.minKey;
      if (key > navLimits.maxKey) key = navLimits.maxKey;
      const cell = [...nodes.grid.querySelectorAll('[data-date]')].find(value => value.dataset.date === key);
      if (!cell || cell.disabled) return;
      state.roving = key;
      updateRoving();
      cell.focus();
      showHover(key, countsFor(key));
    }
    function onGridKeydown(event) {
      if (event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return;
      const cell = event.target.closest && event.target.closest('[data-date]');
      if (!cell) return;
      const date = parseDate(cell.dataset.date);
      if (!date) return;
      let next = null;
      if (event.key === 'ArrowUp') next = addDays(date, -1);
      else if (event.key === 'ArrowDown') next = addDays(date, 1);
      else if (event.key === 'ArrowLeft') next = addDays(date, -7);
      else if (event.key === 'ArrowRight') next = addDays(date, 7);
      else if (event.key === 'Home') next = parseDate(navLimits.minKey);
      else if (event.key === 'End') next = parseDate(navLimits.maxKey);
      else if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        event.stopPropagation();
        selectDay(cell.dataset.date);
        return;
      }
      if (!next) return;
      event.preventDefault();
      event.stopPropagation();
      focusDay(next);
    }
    async function loadMore() {
      if (!state.open || state.loading || state.loadingMore || !state.hasMore) return;
      const token = ++state.token;
      state.loadingMore = true;
      state.error = '';
      renderDay();
      renderStatus();
      try {
        const raw = await request({ year: state.year, kind: state.kind, day: state.selected, offset: state.links.length, limit: 100 });
        if (token !== state.token || !state.open) return;
        const data = normalize(raw);
        const unique = new Map(state.links.map(link => [link.eventID, link]));
        for (const link of data.links) if (!unique.has(link.eventID)) unique.set(link.eventID, link);
        state.links = [...unique.values()];
        state.totalLinks = data.totalLinks || state.links.length;
        state.hasMore = data.hasMore;
        state.offset = state.links.length;
        state.loadingMore = false;
        renderDay();
        renderStatus();
      } catch (error) { fail(error, token); }
    }
    async function openLink(link) {
      if (!link || !link.id) return;
      try { await command({ command: 'activityOpen', ids: [link.id] }); }
      catch (error) {
        state.error = cleanError(error);
        renderStatus();
      }
    }
    function refresh() {
      if (!state.open) return;
      void loadCurrent();
    }
    function open() {
      if (!state.open) {
        state.open = true;
        if (!state.initialized) {
          const now = startOfDay(new Date());
          state.year = now.getFullYear();
          state.selected = formatDate(now);
          state.roving = state.selected;
          state.initialized = true;
        }
      }
      void loadCurrent({ clearLinks: !state.loading });
    }
    function close() {
      state.open = false;
      state.token += 1;
      state.loading = false;
      state.loadingMore = false;
    }
    function changed() {
      if (state.open) refresh();
    }

    nodes.filters.addEventListener('click', event => {
      const button = event.target.closest && event.target.closest('[data-kind]');
      if (button) selectKind(button.dataset.kind);
    });
    nodes.year.addEventListener('change', () => selectYear(Number(nodes.year.value)));
    nodes.more.addEventListener('click', () => void loadMore());
    nodes.retry.addEventListener('click', () => { if (state.retry) void state.retry(); });
    nodes.grid.addEventListener('keydown', onGridKeydown);

    return { open, close, refresh, changed, state, selectKind, selectYear, selectDay, loadMore };
  }

  const api = { create, calendar: { makeDate, startOfDay, addDays, formatDate, parseDate, dateLabel, daysInMonth, daysInYear, yearInfo, lastValidDate, dayCount, intensity } };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.SavenestActivity = api;
})(globalThis);
