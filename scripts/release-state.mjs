import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { access, mkdir, open, readFile, readdir, readlink, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

// Shared release reliability primitives. This module intentionally knows nothing
// about publication or the release orchestrator; it only owns durable checkpoints,
// command logs/timings, and resumable notarization/staple/verification for the
// exact archive that was submitted.

export const RELEASE_STATE_SCHEMA = 1;
const TEMPORARY_PREFIX = '.savenest-release-';
let temporaryCounter = 0;

export class ReleaseStateError extends Error {
  constructor(message, code, details = {}) {
    super(message);
    this.name = 'ReleaseStateError';
    this.code = code;
    Object.assign(this, details);
  }
}

function sortedValue(value) {
  if (Array.isArray(value)) return value.map(sortedValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortedValue(value[key])]));
  }
  return value;
}

export function stableStringify(value, indent = 2) {
  return JSON.stringify(sortedValue(value), null, indent);
}

export function sha256Text(text) {
  return createHash('sha256').update(text).digest('hex');
}

export async function hashFile(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

export async function pathExists(file) {
  try { await access(file); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}

export async function fileFacts(file) {
  const [hash, details] = await Promise.all([hashFile(file), stat(file)]);
  return { sha256: hash, size: details.size };
}

export async function hashDirectory(directory) {
  const hash = createHash('sha256');
  async function visit(current, relative) {
    for (const entry of (await readdir(current, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const child = path.join(current, entry.name);
      const childRelative = path.join(relative, entry.name);
      if (entry.isDirectory()) {
        await visit(child, childRelative);
      } else if (entry.isSymbolicLink()) {
        hash.update(`link\0${childRelative}\0${await readlink(child)}\0`);
      } else if (entry.isFile()) {
        hash.update(`file\0${childRelative}\0${await hashFile(child)}\0`);
      }
    }
  }
  await visit(directory, '');
  return hash.digest('hex');
}

export async function collectReleaseInputs({ helper, files = {}, directories = {} }) {
  const consumed = { helper: helper ? await hashDirectory(helper) : null, files: {}, directories: {} };
  for (const [name, file] of Object.entries(files)) consumed.files[name] = await hashFile(file);
  for (const [name, directory] of Object.entries(directories)) consumed.directories[name] = await hashDirectory(directory);
  return consumed;
}

export async function writeFileAtomic(file, data, options = {}) {
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = path.join(path.dirname(file), `${TEMPORARY_PREFIX}${process.pid}-${temporaryCounter++}.tmp`);
  try {
    await writeFile(temporary, data, { mode: 0o600, ...options });
    const handle = await open(temporary, 'r+');
    try { await handle.sync(); } finally { await handle.close(); }
    await rename(temporary, file);
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => {});
    throw error;
  }
}

export async function writeJsonAtomic(file, value) {
  await writeFileAtomic(file, JSON.stringify(value, null, 2) + '\n', { mode: 0o644 });
}

export function createCheckpoint({ file, now = () => Date.now() }) {
  return {
    file,
    async read() {
      let text;
      try { text = await readFile(file, 'utf8'); }
      catch (error) { if (error.code === 'ENOENT') return null; throw error; }
      const state = JSON.parse(text);
      if (state.schema !== RELEASE_STATE_SCHEMA) {
        throw new ReleaseStateError(`Unsupported release checkpoint schema ${state.schema} in ${file}.`, 'state-schema');
      }
      return state;
    },
    async write(state) {
      const next = { ...state, schema: RELEASE_STATE_SCHEMA, updatedAt: new Date(now()).toISOString() };
      await writeFileAtomic(file, stableStringify(next) + '\n');
      return next;
    },
    async update(mutator) {
      const state = (await this.read()) || {};
      await mutator(state);
      return this.write(state);
    }
  };
}

function stateMismatches(state, expected) {
  const problems = [];
  if (state.identity !== expected.identity) problems.push('release identity');
  if (state.architecture !== expected.architecture) problems.push('architecture');
  if (state.version !== expected.version) problems.push('version');
  if (state.build !== expected.build) problems.push('build');
  if (expected.inputs && (!state.inputs || stableStringify(state.inputs) !== stableStringify(expected.inputs))) problems.push('release inputs');
  return problems;
}

export async function prepareCheckpoint({ checkpoint, identity, architecture, version, build, inputs, now = () => Date.now() }) {
  const expected = { identity, architecture, version, build, inputs };
  const state = await checkpoint.read();
  if (state) {
    const problems = stateMismatches(state, expected);
    if (!problems.length) return state;
    const hasReleaseArtifacts = Boolean(state.submission || state.notary || state.final);
    if (hasReleaseArtifacts) {
      throw new ReleaseStateError(
        `Refusing to reuse release state because the ${problems.join(', ')} changed. ` +
        `The existing submission/archive is immutable; move ${checkpoint.file} aside only after confirming it is obsolete.`,
        'stale-state', { checkpoint: checkpoint.file, problems });
    }
  }
  return checkpoint.write({
    identity, architecture, version, build, inputs,
    status: 'started', timings: {}, logs: {}, createdAt: new Date(now()).toISOString()
  });
}

function defaultExec(command, args, options = {}) {
  const { allowFailure, timeoutMs, ...execOptions } = options;
  return new Promise(resolve => {
    execFile(command, args, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...execOptions, ...(timeoutMs ? { timeout: timeoutMs } : {}) },
      (error, stdout, stderr) => resolve({
        code: error ? (typeof error.code === 'number' ? error.code : 1) : 0,
        stdout: stdout ?? '', stderr: stderr ?? '', signal: error?.signal ?? null
      }));
  });
}

export function createCommandRunner({ logDirectory, exec = defaultExec, now = () => Date.now(), checkpoint = null }) {
  const logs = {};
  return {
    logs,
    logDirectory,
    async run(stage, command, args = [], options = {}) {
      const safeStage = String(stage).replace(/[^a-zA-Z0-9._-]+/g, '-');
      const stdoutPath = path.join(logDirectory, `${safeStage}.stdout.log`);
      const stderrPath = path.join(logDirectory, `${safeStage}.stderr.log`);
      await mkdir(logDirectory, { recursive: true });
      const start = now();
      let result;
      try { result = await exec(command, args, options); }
      catch (error) {
        result = { code: error?.code ?? 1, stdout: error?.stdout ?? '', stderr: error?.stderr ?? '', signal: error?.signal ?? null };
      }
      const end = now();
      const stdout = String(result.stdout ?? '');
      const stderr = String(result.stderr ?? '');
      await writeFile(stdoutPath, stdout);
      await writeFile(stderrPath, stderr);
      const record = {
        command: path.basename(command), startedAt: new Date(start).toISOString(), finishedAt: new Date(end).toISOString(),
        durationMs: Math.max(0, end - start), ok: result.code === 0, exitCode: result.code, signal: result.signal ?? null
      };
      if (checkpoint) {
        await checkpoint.update(state => {
          state.timings = state.timings || {};
          state.timings[safeStage] = record;
          state.logs = state.logs || {};
          state.logs[safeStage] = { stdout: path.basename(stdoutPath), stderr: path.basename(stderrPath) };
          state.attempts = state.attempts || {};
          state.attempts[safeStage] = (state.attempts[safeStage] || 0) + 1;
          if (!record.ok) {
            state.lastFailure = {
              stage: safeStage, at: record.finishedAt, exitCode: result.code,
              message: (stderr || stdout || `${command} failed`).slice(-2000)
            };
          }
        });
      }
      logs[safeStage] = { stdoutPath, stderrPath, ...record };
      if (!record.ok && !options.allowFailure) {
        throw new ReleaseStateError(
          `Stage ${safeStage} failed: ${command} exited with ${result.code}. Logs: ${stdoutPath}, ${stderrPath}`,
          'command-failed', { stage: safeStage, exitCode: result.code, stdout, stderr, logs: logs[safeStage] });
      }
      return { ...result, stdout, stderr, ok: record.ok, stage: safeStage, logs: logs[safeStage] };
    }
  };
}

function parseNotaryJson(text) {
  if (!text) return null;
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try { return JSON.parse(text.slice(start, end + 1)); }
  catch { return null; }
}

const rejectedStatuses = new Set(['Invalid', 'Rejected']);

function verifyMetadataValue(state, metadata, expectedFile) {
  const problems = [];
  const final = state.final;
  if (!final) return ['checkpoint has no final archive'];
  if (metadata?.artifact !== undefined && metadata.artifact !== null) {
    const artifact = metadata.artifact;
    if (artifact.file !== expectedFile || artifact.file !== final.file) problems.push('artifact file provenance');
    if (artifact.sha256 !== final.sha256) problems.push('artifact sha256 provenance');
    if (artifact.size !== final.size) problems.push('artifact size provenance');
  }
  if (metadata?.feed !== undefined && metadata.feed !== null) {
    const update = metadata.feed.releases?.find(release => release.version === state.version)?.updateTo;
    if (!update) problems.push('feed version provenance');
    else {
      if (update.sha256 !== final.sha256) problems.push('feed sha256 provenance');
      if (update.size !== final.size) problems.push('feed size provenance');
    }
  }
  if (metadata?.sha256sums !== undefined && metadata.sha256sums !== null) {
    if (metadata.sha256sums !== `${final.sha256}  ${expectedFile}\n`) problems.push('SHA256SUMS.txt provenance');
  }
  return problems;
}

function verifyMetadata(state, metadata, expectedFile) {
  const problems = [];
  if (metadata) problems.push(...verifyMetadataValue(state, metadata, expectedFile));
  if (state.metadata) problems.push(...verifyMetadataValue(state, state.metadata, expectedFile));
  return [...new Set(problems)];
}

export async function verifyExistingFinal({ checkpoint, identity, architecture, version, build, inputs = null, finalArchive, metadata = null, validate = null }) {
  const state = await checkpoint.read();
  if (!state) {
    throw new ReleaseStateError(
      `Refusing to overwrite ${finalArchive}: no release checkpoint proves these bytes were built by this release.`,
      'final-without-provenance', { archive: finalArchive });
  }
  const problems = stateMismatches(state, { identity, architecture, version, build, inputs });
  if (problems.length) {
    throw new ReleaseStateError(
      `Refusing to overwrite ${finalArchive}: checkpoint does not match the current ${problems.join(', ')}.`,
      'stale-state', { archive: finalArchive, problems });
  }
  const file = path.basename(finalArchive);
  if (!state.final || state.final.file !== file) {
    throw new ReleaseStateError(`Refusing to overwrite ${finalArchive}: checkpoint does not identify this archive.`,
      'final-without-provenance', { archive: finalArchive });
  }
  const facts = await fileFacts(finalArchive);
  if (facts.sha256 !== state.final.sha256 || facts.size !== state.final.size) {
    throw new ReleaseStateError(`Refusing to reuse ${finalArchive}: archive bytes do not match the completed checkpoint.`,
      'final-corrupt', { archive: finalArchive, expected: state.final, actual: facts });
  }
  const metadataProblems = verifyMetadata(state, metadata, file);
  if (metadataProblems.length) {
    throw new ReleaseStateError(`Refusing to reuse ${finalArchive}: ${metadataProblems.join(', ')}.`,
      'final-metadata-mismatch', { archive: finalArchive, problems: metadataProblems });
  }
  if (validate) await validate(finalArchive);
  return { state, final: facts, metadataMissing: !metadata, artifact: state.metadata?.artifact ?? null };
}

export async function notarizeAndStaple({
  checkpoint, runner, identity, architecture, version, build, inputs,
  submissionArchive, createSubmissionArchive, finalArchive, extractDirectory, profile,
  timeoutMs = 20 * 60 * 1000, pollIntervalMs = 5000, now = () => Date.now(), sleep = delay => new Promise(resolve => setTimeout(resolve, delay))
}) {
  if (!profile) throw new ReleaseStateError('NOTARY_PROFILE is required for notarization.', 'missing-profile');
  if (await pathExists(finalArchive)) {
    throw new ReleaseStateError(`Refusing to overwrite existing release archive: ${finalArchive}`, 'archive-exists', { archive: finalArchive });
  }
  let state = await prepareCheckpoint({ checkpoint, identity, architecture, version, build, inputs, now });
  const submissionFile = path.basename(submissionArchive);

  async function assertSubmission() {
    if (!state.submission) throw new ReleaseStateError('Release checkpoint has no submission archive record.', 'submission-missing');
    if (state.submission.file !== submissionFile) {
      throw new ReleaseStateError(`Submission archive provenance changed: expected ${state.submission.file}, found ${submissionFile}.`, 'submission-mismatch');
    }
    if (!(await pathExists(submissionArchive))) {
      throw new ReleaseStateError(`Submission archive ${submissionArchive} is missing; refusing to rebuild an already submitted archive.`, 'submission-missing');
    }
    const facts = await fileFacts(submissionArchive);
    if (facts.sha256 !== state.submission.sha256 || facts.size !== state.submission.size) {
      throw new ReleaseStateError(
        `Submission archive ${submissionArchive} no longer matches the submitted bytes; refusing to submit or resume different bytes.`,
        'submission-mismatch', { expected: state.submission, actual: { file: submissionFile, ...facts } });
    }
  }

  if (state.notary?.id) {
    await assertSubmission();
    if (rejectedStatuses.has(state.notary.status)) {
      throw new ReleaseStateError(`Notarization ${state.notary.id} is ${state.notary.status}; no resubmission will be attempted.`,
        'notary-rejected', { submissionId: state.notary.id, status: state.notary.status });
    }
  } else {
    if (!state.submission) {
      if (await pathExists(submissionArchive)) {
        throw new ReleaseStateError(
          `Refusing to overwrite ${submissionArchive}: it exists without checkpoint provenance and may be an in-flight submission.`,
          'submission-without-provenance', { submissionArchive });
      }
      await createSubmissionArchive();
      const facts = await fileFacts(submissionArchive);
      state = await checkpoint.update(current => {
        current.submission = { file: submissionFile, sha256: facts.sha256, size: facts.size, createdAt: new Date(now()).toISOString() };
        current.status = 'submission-ready';
      });
    }
    await assertSubmission();

    if (state.submitAttempt) {
      // A submit command started but its response was lost. Recover the id from
      // the persisted stdout only; never submit the same bytes a second time.
      const loggedStdout = state.logs?.['notary-submit']?.stdout;
      let payload = null;
      const logCandidates = [
        loggedStdout && runner.logDirectory ? path.join(runner.logDirectory, path.basename(loggedStdout)) : null,
        runner.logDirectory ? path.join(runner.logDirectory, 'notary-submit.stdout.log') : null
      ].filter(Boolean);
      for (const logFile of [...new Set(logCandidates)]) {
        try { payload = parseNotaryJson(await readFile(logFile, 'utf8')); }
        catch { payload = null; }
        if (payload?.id) break;
      }
      if (!payload?.id) {
        throw new ReleaseStateError(
          `A previous notarytool submit attempt for ${submissionArchive} has no recorded submission id. ` +
          `Inspect notarytool history; if it was submitted, record the id in ${checkpoint.file}; if not, remove submitAttempt only after confirming no submission exists. Refusing to submit again silently.`,
          'notary-submit-ambiguous', { submissionArchive, submitAttempt: state.submitAttempt, log: loggedStdout ?? null });
      }
      const recoveredAt = new Date(now()).toISOString();
      state = await checkpoint.update(current => {
        current.notary = { id: payload.id, status: payload.status || 'Submitted',
          submittedAt: current.submitAttempt?.startedAt ?? recoveredAt, checkedAt: recoveredAt, recoveredFromLog: true };
        current.submitAttempt = { ...current.submitAttempt, status: 'recovered', recoveredAt };
        current.status = 'submitted';
      });
    } else {
      state = await checkpoint.update(current => {
        current.submitAttempt = { status: 'started', startedAt: new Date(now()).toISOString(),
          file: submissionFile, sha256: state.submission.sha256, size: state.submission.size };
        current.status = 'submitting';
      });
      let result;
      try {
        result = await runner.run('notary-submit', 'xcrun',
          ['notarytool', 'submit', submissionArchive, '--keychain-profile', profile, '--output-format', 'json'],
          { timeoutMs: 10 * 60 * 1000 });
      } catch (error) {
        const payload = parseNotaryJson(error.stdout);
        if (!payload?.id) {
          await checkpoint.update(current => {
            current.submitAttempt = { ...current.submitAttempt, status: 'unknown', endedAt: new Date(now()).toISOString() };
            current.status = 'notary-submit-ambiguous';
          });
          throw new ReleaseStateError(
            `notarytool submit did not return a submission id; the attempt is recorded as ambiguous in ${checkpoint.file}. ` +
            `Inspect notarytool history and reconcile before rerunning; refusing to submit again silently.`,
            'notary-submit-ambiguous', { submissionArchive, submitAttempt: state.submitAttempt });
        }
        result = { stdout: error.stdout };
      }
      const payload = parseNotaryJson(result.stdout);
      if (!payload?.id) {
        await checkpoint.update(current => {
          current.submitAttempt = { ...current.submitAttempt, status: 'unknown', endedAt: new Date(now()).toISOString() };
          current.status = 'notary-submit-ambiguous';
        });
        throw new ReleaseStateError(
          `notarytool submit did not return a submission id; the attempt is recorded as ambiguous in ${checkpoint.file}. ` +
          `Inspect notarytool history and reconcile before rerunning; refusing to submit again silently.`,
          'notary-submit-ambiguous', { submissionArchive, submitAttempt: state.submitAttempt });
      }
      const checkedAt = new Date(now()).toISOString();
      state = await checkpoint.update(current => {
        current.notary = { id: payload.id, status: payload.status || 'Submitted', submittedAt: checkedAt, checkedAt };
        current.submitAttempt = { ...current.submitAttempt, status: 'submitted', submissionId: payload.id, endedAt: checkedAt };
        current.status = 'submitted';
      });
    }
  }

  if (rejectedStatuses.has(state.notary.status)) {
    throw new ReleaseStateError(`Notarization ${state.notary.id} is ${state.notary.status}; no resubmission will be attempted.`,
      'notary-rejected', { submissionId: state.notary.id, status: state.notary.status });
  }

  if (state.notary.status !== 'Accepted') {
    const deadline = now() + timeoutMs;
    let accepted = false;
    while (true) {
      let info;
      try {
        info = await runner.run('notary-info', 'xcrun',
          ['notarytool', 'info', state.notary.id, '--keychain-profile', profile, '--output-format', 'json'],
          { allowFailure: true, timeoutMs: 60 * 1000 });
      } catch { info = null; }
      const payload = parseNotaryJson(info?.stdout);
      const status = payload?.status;
      if (status === 'Accepted') {
        state = await checkpoint.update(current => {
          current.notary = { ...current.notary, status: 'Accepted', checkedAt: new Date(now()).toISOString() };
          current.status = 'accepted';
        });
        accepted = true;
        break;
      }
      if (rejectedStatuses.has(status)) {
        state = await checkpoint.update(current => {
          current.notary = { ...current.notary, status, checkedAt: new Date(now()).toISOString(), message: payload?.message ?? null };
          current.status = 'notary-rejected';
          current.lastFailure = { stage: 'notary-info', at: new Date(now()).toISOString(), message: payload?.message ?? status };
        });
        throw new ReleaseStateError(
          `Notarization ${state.notary.id} was ${status}${payload?.message ? `: ${payload.message}` : ''}. No resubmission will be attempted.`,
          'notary-rejected', { submissionId: state.notary.id, status });
      }
      if (status && status !== state.notary.status) {
        state = await checkpoint.update(current => {
          current.notary = { ...current.notary, status, checkedAt: new Date(now()).toISOString() };
        });
      }
      if (now() >= deadline) break;
      await sleep(Math.min(pollIntervalMs, Math.max(0, deadline - now())));
    }
    if (!accepted) {
      state = await checkpoint.update(current => {
        current.notary = { ...current.notary, status: 'TimedOut', checkedAt: new Date(now()).toISOString() };
        current.status = 'notary-timeout';
        current.lastFailure = { stage: 'notary-wait', at: new Date(now()).toISOString(), message: 'Timed out waiting for notarization.' };
      });
      throw new ReleaseStateError(
        `Notarization ${state.notary.id} did not finish before the timeout. Rerun the same release command to wait for the same submission; it will not be resubmitted.`,
        'notary-timeout', { submissionId: state.notary.id, submissionArchive });
    }
  }

  if (state.notary.status !== 'Accepted') {
    throw new ReleaseStateError('Refusing to staple before notarization is Accepted.', 'notary-not-accepted');
  }

  await rm(extractDirectory, { recursive: true, force: true });
  await mkdir(extractDirectory, { recursive: true });
  await runner.run('notary-extract', 'ditto', ['-x', '-k', submissionArchive, extractDirectory]);
  const app = path.join(extractDirectory, 'SaveNest.app');
  if (!(await pathExists(app))) {
    throw new ReleaseStateError(`Submitted archive did not contain SaveNest.app at ${app}.`, 'extracted-app-missing');
  }
  await runner.run('staple', 'xcrun', ['stapler', 'staple', app]);
  await runner.run('staple-validate', 'xcrun', ['stapler', 'validate', app]);
  await runner.run('gatekeeper', 'spctl', ['--assess', '--type', 'execute', '--verbose=2', app]);
  await runner.run('codesign-verify', 'codesign', ['--verify', '--deep', '--strict', app]);

  const temporaryFinal = path.join(path.dirname(finalArchive),
    `${TEMPORARY_PREFIX}${path.basename(finalArchive)}.${process.pid}-${temporaryCounter++}.tmp.zip`);
  try {
    await runner.run('final-compress', 'ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', app, temporaryFinal]);
    if (await pathExists(finalArchive)) {
      throw new ReleaseStateError(`Refusing to overwrite existing release archive: ${finalArchive}`, 'archive-exists', { archive: finalArchive });
    }
    const facts = await fileFacts(temporaryFinal);
    await rename(temporaryFinal, finalArchive);
    state = await checkpoint.update(current => {
      current.final = { file: path.basename(finalArchive), sha256: facts.sha256, size: facts.size, createdAt: new Date(now()).toISOString() };
      current.status = 'artifact-ready';
    });
    return { app, submissionId: state.notary.id, artifact: { file: path.basename(finalArchive), sha256: facts.sha256, size: facts.size } };
  } catch (error) {
    await rm(temporaryFinal, { force: true }).catch(() => {});
    throw error;
  }
}

export async function markCompleted({ checkpoint, metadata }) {
  return checkpoint.update(state => {
    state.metadata = metadata;
    state.status = 'completed';
    state.completedAt = new Date().toISOString();
  });
}

export async function removeSubmissionArchive({ checkpoint, submissionArchive }) {
  const state = await checkpoint.read();
  if (!state?.final) throw new ReleaseStateError('Refusing to remove a submission archive before the final archive checkpoint exists.', 'submission-retained');
  await rm(submissionArchive, { force: true });
  return checkpoint.update(current => { current.submissionRetained = false; });
}
