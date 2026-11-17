const test = require('node:test');
const assert = require('node:assert/strict');
const { createServiceQueue, registerServices } = require('../services.cjs');
const { validateCommand } = require('../contracts.cjs');
const tick = () => new Promise(resolve => setImmediate(resolve));

test('Services waits for startup, preserves order, and continues after a busy editor', async () => {
  const seen = [], errors = [];
  let release;
  const first = new Promise(resolve => { release = resolve; });
  const queue = createServiceQueue({
    capture: async url => {
      seen.push(url);
      if (url.endsWith('/1')) await first;
      if (url.endsWith('/2')) throw new Error('Finish the open editor.');
    }, onError: error => errors.push(error.message)
  });
  queue.receive('https://example.com/1'); queue.receive('https://example.com/2');
  assert.deepEqual(seen, []);
  queue.ready(); queue.ready();
  await tick(); assert.deepEqual(seen, ['https://example.com/1']);
  queue.receive('https://example.com/3');
  release(); await tick();
  assert.deepEqual(seen, ['https://example.com/1', 'https://example.com/2', 'https://example.com/3']);
  assert.deepEqual(errors, ['Finish the open editor.']);
});

test('Services bounds startup requests and rejects oversized input', async () => {
  const seen = [], errors = [];
  const queue = createServiceQueue({ capture: async value => seen.push(value), onError: error => errors.push(error.message) });
  queue.receive(null); queue.receive('é'.repeat(4097));
  for (let i = 0; i < 11; i++) queue.receive(`https://example.com/${i}`);
  assert.equal(errors.length, 3);
  queue.ready(); await tick();
  assert.equal(seen.length, 10);
});

test('Preview never loads a Services provider; renderer cannot forge a Services request', () => {
  registerServices({ preview: true, app: null, root: null, receive: () => assert.fail('Preview registered Services.') });
  assert.throws(() => validateCommand({ command: 'serviceCapture', url: 'https://example.com' }), /Unknown/);
});
