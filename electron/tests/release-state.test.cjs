'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { createHash } = require('node:crypto');

const load = () => import('../../scripts/release-state.mjs');
const sha256 = text => createHash('sha256').update(text).digest('hex');
const ok = (stdout = '') => ({ code: 0, stdout, stderr: '', signal: null });

async function temporary(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'savenest-release-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return directory;
}

function fixture({ statuses = ['Accepted'], onCommand } = {}) {
  const calls = [];
  const pendingStatuses = [...statuses];
  const exec = async (command, args) => {
    const call = { command, args };
    calls.push(call);
    if (command === 'xcrun' && args.includes('submit')) {
      return ok(JSON.stringify({ id: 'sub-1', status: 'Submitted', message: 'Successfully uploaded file' }));
    }
    if (command === 'xcrun' && args[1] === 'info') {
      const status = pendingStatuses.length > 1 ? pendingStatuses.shift() : pendingStatuses[0];
      return ok(JSON.stringify({ id: 'sub-1', status, message: status === 'Invalid' ? 'The signature is invalid.' : undefined }));
    }
    if (command === 'ditto' && args[0] === '-x') {
      await fs.mkdir(path.join(args[3], 'SaveNest.app'), { recursive: true });
      return ok();
    }
    if (command === 'ditto' && args[0] === '-c') {
      await fs.writeFile(args.at(-1), 'final-zip-bytes');
      return ok();
    }
    if (onCommand) return onCommand(call);
    return ok();
  };
  return { calls, exec };
}

async function notarySetup(t, options = {}) {
  const release = await load();
  const directory = await temporary(t);
  const checkpoint = release.createCheckpoint({ file: path.join(directory, '.release-state', 'arm64.json') });
  const runner = release.createCommandRunner({ logDirectory: path.join(directory, '.release-state', 'logs'), checkpoint });
  const submissionArchive = path.join(directory, '.notarize-arm64.zip');
  const finalArchive = path.join(directory, 'SaveNest-1.0-macOS-arm64.zip');
  let createCalls = 0;
  const base = {
    checkpoint, runner, identity: 'identity-a', architecture: 'arm64', version: '1.0', build: '42',
    inputs: { version: '1.0', build: '42' }, submissionArchive, finalArchive, profile: 'test-profile',
    extractDirectory: path.join(directory, '.release-state', 'extract'),
    createSubmissionArchive: async () => {
      createCalls++;
      await fs.writeFile(submissionArchive, 'submission-zip-bytes');
    },
    timeoutMs: 1000, pollIntervalMs: 10, now: () => 0, sleep: async () => {}
  };
  return { release, directory, submissionArchive, finalArchive, base, get createCalls() { return createCalls; }, options };
}

function notaryOptions(setup, fixtureValue) {
  return { ...setup.base, runner: setup.release.createCommandRunner({
    logDirectory: path.join(setup.directory, '.release-state', 'logs'), exec: fixtureValue.exec, checkpoint: setup.base.checkpoint
  }) };
}

test('command runner persists timings and logs for successful and failed stages', async t => {
  const release = await load();
  const directory = await temporary(t);
  const checkpoint = release.createCheckpoint({ file: path.join(directory, '.release-state', 'build.json') });
  const times = [1000, 1010, 1020, 1035];
  const runner = release.createCommandRunner({
    logDirectory: path.join(directory, 'logs'), checkpoint, now: () => times.shift(),
    exec: async command => command === 'ok'
      ? { code: 0, stdout: 'stdout text', stderr: '' }
      : { code: 7, stdout: '', stderr: 'boom' }
  });
  await runner.run('compile', 'ok', []);
  await assert.rejects(runner.run('sign', 'bad', []), error => error.code === 'command-failed');
  const state = await checkpoint.read();
  assert.deepEqual(
    { ok: state.timings.compile.ok, duration: state.timings.compile.durationMs, exit: state.timings.compile.exitCode },
    { ok: true, duration: 10, exit: 0 });
  assert.deepEqual(
    { ok: state.timings.sign.ok, duration: state.timings.sign.durationMs, exit: state.timings.sign.exitCode },
    { ok: false, duration: 15, exit: 7 });
  assert.equal(state.attempts.compile, 1);
  assert.equal(state.lastFailure.stage, 'sign');
  assert.match(state.lastFailure.message, /boom/);
  assert.equal(await fs.readFile(path.join(directory, 'logs', 'compile.stdout.log'), 'utf8'), 'stdout text');
  assert.equal(await fs.readFile(path.join(directory, 'logs', 'sign.stderr.log'), 'utf8'), 'boom');
  const entries = await fs.readdir(path.join(directory, '.release-state'));
  assert.equal(entries.some(entry => entry.startsWith('.savenest-release-')), false);
});

test('accepted notarization persists the id without --wait, then staples, checks and compresses', async t => {
  const setup = await notarySetup(t);
  const fake = fixture();
  const result = await setup.release.notarizeAndStaple(notaryOptions(setup, fake));
  const submit = fake.calls.find(call => call.command === 'xcrun' && call.args.includes('submit'));
  assert.deepEqual(submit.args.slice(0, 3), ['notarytool', 'submit', setup.submissionArchive]);
  assert.ok(submit.args.includes('--output-format'));
  assert.ok(!submit.args.includes('--wait'));
  const names = fake.calls.map(call => call.args[0]);
  assert.ok(names.includes('stapler'));
  assert.ok(fake.calls.some(call => call.args[1] === 'staple'));
  assert.ok(names.includes('--assess'));
  assert.ok(names.includes('--verify'));
  assert.ok(fake.calls.findIndex(call => call.args[1] === 'info') < fake.calls.findIndex(call => call.args[1] === 'staple'));
  const state = await setup.base.checkpoint.read();
  assert.equal(state.notary.id, 'sub-1');
  assert.equal(state.notary.status, 'Accepted');
  assert.equal(state.status, 'artifact-ready');
  assert.equal(state.final.sha256, sha256('final-zip-bytes'));
  assert.equal(result.artifact.sha256, sha256('final-zip-bytes'));
  assert.equal(await fs.readFile(setup.finalArchive, 'utf8'), 'final-zip-bytes');
  assert.equal(await fs.readFile(setup.submissionArchive, 'utf8'), 'submission-zip-bytes');
});

test('a wait timeout preserves the submission id and resumes without submitting again', async t => {
  const setup = await notarySetup(t);
  let clock = 0;
  const hanging = fixture({ statuses: ['In Progress'] });
  const first = notaryOptions(setup, hanging);
  first.now = () => clock;
  first.sleep = async milliseconds => { clock += milliseconds; };
  await assert.rejects(setup.release.notarizeAndStaple(first), error => error.code === 'notary-timeout');
  const timedOut = await setup.base.checkpoint.read();
  assert.equal(timedOut.notary.id, 'sub-1');
  assert.equal(timedOut.notary.status, 'TimedOut');
  assert.equal(hanging.calls.filter(call => call.args.includes('submit')).length, 1);
  assert.equal(await fs.readFile(setup.submissionArchive, 'utf8'), 'submission-zip-bytes');

  const accepted = fixture({ statuses: ['Accepted'] });
  const second = notaryOptions(setup, accepted);
  second.now = () => clock;
  second.sleep = async milliseconds => { clock += milliseconds; };
  await setup.release.notarizeAndStaple(second);
  assert.equal(accepted.calls.filter(call => call.args.includes('submit')).length, 0);
  assert.equal(setup.createCalls, 1);
  assert.ok(accepted.calls.some(call => call.args.includes('sub-1')));
  assert.equal((await setup.base.checkpoint.read()).status, 'artifact-ready');
});

test('an interrupted submit recovers its id from the persisted stdout and never resubmits', async t => {
  const setup = await notarySetup(t);
  await setup.base.createSubmissionArchive();
  const digest = sha256('submission-zip-bytes');
  await setup.base.checkpoint.update(state => {
    state.identity = 'identity-a'; state.architecture = 'arm64'; state.version = '1.0'; state.build = '42';
    state.inputs = { version: '1.0', build: '42' };
    state.submission = { file: path.basename(setup.submissionArchive), sha256: digest, size: 20, createdAt: new Date(0).toISOString() };
    state.submitAttempt = { status: 'started', startedAt: new Date(0).toISOString(), file: path.basename(setup.submissionArchive), sha256: digest, size: 20 };
    state.logs = { 'notary-submit': { stdout: 'notary-submit.stdout.log', stderr: 'notary-submit.stderr.log' } };
    state.status = 'submitting';
  });
  const logs = path.join(setup.directory, '.release-state', 'logs');
  await fs.mkdir(logs, { recursive: true });
  await fs.writeFile(path.join(logs, 'notary-submit.stdout.log'), JSON.stringify({ id: 'sub-1', status: 'Submitted' }));
  const fake = fixture({ statuses: ['Accepted'] });
  await setup.release.notarizeAndStaple(notaryOptions(setup, fake));
  assert.equal(fake.calls.filter(call => call.args.includes('submit')).length, 0);
  assert.ok(fake.calls.some(call => call.args.includes('sub-1')));
  assert.equal((await setup.base.checkpoint.read()).submitAttempt.status, 'recovered');
});

test('an ambiguous submit without a recoverable id refuses to resubmit', async t => {
  const setup = await notarySetup(t);
  await setup.base.createSubmissionArchive();
  const digest = sha256('submission-zip-bytes');
  await setup.base.checkpoint.update(state => {
    state.identity = 'identity-a'; state.architecture = 'arm64'; state.version = '1.0'; state.build = '42';
    state.inputs = { version: '1.0', build: '42' };
    state.submission = { file: path.basename(setup.submissionArchive), sha256: digest, size: 20, createdAt: new Date(0).toISOString() };
    state.submitAttempt = { status: 'started', startedAt: new Date(0).toISOString(), file: path.basename(setup.submissionArchive), sha256: digest, size: 20 };
    state.status = 'submitting';
  });
  const fake = fixture();
  await assert.rejects(setup.release.notarizeAndStaple(notaryOptions(setup, fake)),
    error => error.code === 'notary-submit-ambiguous' && /Refusing to submit again/.test(error.message));
  assert.equal(fake.calls.filter(call => call.args.includes('submit')).length, 0);
  assert.equal(await fs.readFile(setup.submissionArchive, 'utf8'), 'submission-zip-bytes');
});

test('explicit Invalid notarization fails without stapling or resubmitting', async t => {
  const setup = await notarySetup(t);
  const fake = fixture({ statuses: ['Invalid'] });
  await assert.rejects(setup.release.notarizeAndStaple(notaryOptions(setup, fake)),
    error => error.code === 'notary-rejected' && /Invalid/.test(error.message) && /signature is invalid/.test(error.message));
  assert.equal(fake.calls.filter(call => call.args.includes('submit')).length, 1);
  assert.equal(fake.calls.some(call => call.args[1] === 'staple'), false);
  const state = await setup.base.checkpoint.read();
  assert.equal(state.status, 'notary-rejected');
  assert.equal(state.notary.status, 'Invalid');
  assert.equal(await fs.readFile(setup.submissionArchive, 'utf8'), 'submission-zip-bytes');
});

test('changed submission bytes and stale source identity are refused before any submit', async t => {
  const setup = await notarySetup(t);
  await setup.base.createSubmissionArchive();
  await setup.base.checkpoint.update(state => {
    state.identity = 'identity-a'; state.architecture = 'arm64'; state.version = '1.0'; state.build = '42';
    state.inputs = { version: '1.0', build: '42' };
    state.submission = { file: path.basename(setup.submissionArchive), sha256: sha256('submission-zip-bytes'), size: 20, createdAt: new Date(0).toISOString() };
    state.notary = { id: 'sub-1', status: 'TimedOut' };
    state.status = 'notary-timeout';
  });
  await fs.writeFile(setup.submissionArchive, 'tampered-zip-bytes!');
  const fake = fixture();
  await assert.rejects(setup.release.notarizeAndStaple(notaryOptions(setup, fake)),
    error => error.code === 'submission-mismatch' && /no longer matches/.test(error.message));
  assert.equal(fake.calls.filter(call => call.args.includes('submit')).length, 0);

  await fs.writeFile(setup.submissionArchive, 'submission-zip-bytes');
  const changedInputs = notaryOptions(setup, fixture());
  changedInputs.inputs = { version: '1.0', build: '42', source: 'changed' };
  await assert.rejects(setup.release.notarizeAndStaple(changedInputs),
    error => error.code === 'stale-state' && /release inputs/.test(error.message));

  await setup.base.checkpoint.update(state => { delete state.inputs; });
  const missingInputs = notaryOptions(setup, fixture());
  missingInputs.inputs = { version: '1.0', build: '42' };
  await assert.rejects(setup.release.notarizeAndStaple(missingInputs),
    error => error.code === 'stale-state' && /release inputs/.test(error.message));

  const stale = notaryOptions(setup, fixture());
  stale.identity = 'identity-b';
  await assert.rejects(setup.release.notarizeAndStaple(stale),
    error => error.code === 'stale-state' && /release identity/.test(error.message));
});

test('completed archives are reused only with matching checkpoint bytes and metadata', async t => {
  const release = await load();
  const directory = await temporary(t);
  const finalArchive = path.join(directory, 'SaveNest-1.0-macOS-arm64.zip');
  const checkpoint = release.createCheckpoint({ file: path.join(directory, '.release-state', 'arm64.json') });
  await fs.writeFile(finalArchive, 'good-zip');
  const artifact = { architecture: 'arm64', file: path.basename(finalArchive), sha256: sha256('good-zip'), size: 8 };
  await checkpoint.update(state => {
    state.identity = 'identity-a'; state.architecture = 'arm64'; state.version = '1.0'; state.build = '42';
    state.final = { file: artifact.file, sha256: artifact.sha256, size: 8 };
    state.metadata = { artifact };
  });
  let validations = 0;
  const verified = await release.verifyExistingFinal({ checkpoint, identity: 'identity-a', architecture: 'arm64', version: '1.0', build: '42',
    finalArchive, metadata: { artifact }, validate: async () => { validations++; } });
  assert.equal(validations, 1);
  assert.equal(verified.metadataMissing, false);

  await checkpoint.update(state => { delete state.metadata; });
  const recoverable = await release.verifyExistingFinal({ checkpoint, identity: 'identity-a', architecture: 'arm64', version: '1.0', build: '42',
    finalArchive, metadata: null });
  assert.equal(recoverable.metadataMissing, true);
  assert.equal(recoverable.final.sha256, artifact.sha256);

  await fs.writeFile(finalArchive, 'bad-zip!');
  await assert.rejects(release.verifyExistingFinal({ checkpoint, identity: 'identity-a', architecture: 'arm64', version: '1.0', build: '42',
    finalArchive, metadata: { artifact }, validate: async () => { validations++; } }), error => error.code === 'final-corrupt');
  assert.equal(validations, 1);

  await fs.writeFile(finalArchive, 'good-zip');
  await assert.rejects(release.verifyExistingFinal({ checkpoint, identity: 'identity-a', architecture: 'arm64', version: '1.0', build: '42',
    finalArchive, metadata: { artifact: { ...artifact, sha256: '0'.repeat(64) } } }),
  error => error.code === 'final-metadata-mismatch' && /artifact sha256 provenance/.test(error.message));
  await assert.rejects(release.verifyExistingFinal({ checkpoint, identity: 'identity-b', architecture: 'arm64', version: '1.0', build: '42',
    finalArchive, metadata: { artifact } }), error => error.code === 'stale-state');

  const empty = release.createCheckpoint({ file: path.join(directory, '.release-state', 'other.json') });
  await assert.rejects(release.verifyExistingFinal({ checkpoint: empty, identity: 'identity-a', architecture: 'arm64', version: '1.0', build: '42',
    finalArchive, metadata: null }), error => error.code === 'final-without-provenance');
});

test('changing a packaged helper resource or notice changes inputs and rejects resume', async t => {
  const release = await load();
  const directory = await temporary(t);
  const helper = path.join(directory, 'helper', 'SaveNest.app');
  const resource = path.join(helper, 'Contents', 'Resources', 'Sparkle.framework');
  const notice = path.join(directory, 'THIRD_PARTY_NOTICES.md');
  await fs.mkdir(path.dirname(resource), { recursive: true });
  await fs.writeFile(resource, 'framework-v1');
  await fs.writeFile(notice, 'notices-v1');
  const checkpoint = release.createCheckpoint({ file: path.join(directory, '.release-state', 'arm64.json') });
  const before = await release.collectReleaseInputs({ helper, files: { notice } });
  await release.prepareCheckpoint({ checkpoint, identity: 'supplied-release-identity', architecture: 'arm64',
    version: '1.0', build: '42', inputs: before });
  await checkpoint.update(state => { state.submission = { file: 'submission.zip', sha256: 'a'.repeat(64), size: 1 }; });

  await fs.writeFile(notice, 'notices-v2');
  const afterNotice = await release.collectReleaseInputs({ helper, files: { notice } });
  assert.notEqual(release.stableStringify(before), release.stableStringify(afterNotice));
  await assert.rejects(release.prepareCheckpoint({ checkpoint, identity: 'supplied-release-identity', architecture: 'arm64',
    version: '1.0', build: '42', inputs: afterNotice }), error => error.code === 'stale-state' && /release inputs/.test(error.message));

  await fs.writeFile(notice, 'notices-v1');
  await fs.writeFile(resource, 'framework-v2');
  const afterResource = await release.collectReleaseInputs({ helper, files: { notice } });
  assert.notEqual(release.stableStringify(before), release.stableStringify(afterResource));
  await assert.rejects(release.prepareCheckpoint({ checkpoint, identity: 'supplied-release-identity', architecture: 'arm64',
    version: '1.0', build: '42', inputs: afterResource }), error => error.code === 'stale-state' && /release inputs/.test(error.message));
});
