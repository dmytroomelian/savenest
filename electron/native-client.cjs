'use strict';
const { spawn } = require('node:child_process');
const { EventEmitter } = require('node:events');

class NativeClient extends EventEmitter {
  constructor(executable, { preview = false, readerLive = false } = {}) {
    super();
    this.pending = new Map(); this.sequence = 0; this.closed = false; this.buffer = '';
    this.child = spawn(executable, ['--electron-bridge', ...(preview ? ['--ui-preview'] : []), ...(preview && readerLive ? ['--reader-live'] : [])], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', chunk => this.receive(chunk));
    // Never send helper diagnostics or account URLs to the renderer or console.
    this.child.stderr.resume();
    this.child.on('error', () => this.fail('The native helper could not start. Run npm run build:native.'));
    this.child.on('exit', () => this.fail('The native helper stopped. Quit and reopen Savenest.'));
    this.child.stdin.on('error', () => this.fail('The native helper disconnected. Quit and reopen Savenest.'));
  }
  receive(chunk) {
    this.buffer += chunk;
    if (Buffer.byteLength(this.buffer) > 32 * 1024 * 1024) {
      this.fail('The native helper sent too much data.'); this.stop(); return;
    }
    let end;
    while ((end = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, end); this.buffer = this.buffer.slice(end + 1);
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      if (message.event === 'fatal') { this.fail(message.message); continue; }
      if (message.event) { this.emit('event', message); continue; }
      const pending = this.pending.get(message.id);
      if (!pending) continue;
      clearTimeout(pending.timer); this.pending.delete(message.id);
      if (message.ok) pending.resolve(message.result ?? true);
      else pending.reject(new Error(message.error || 'Savenest could not finish this action.'));
    }
  }
  request(command) {
    if (this.closed) return Promise.reject(new Error('Savenest is disconnected. Quit and reopen the app.'));
    if (this.pending.size >= 128) return Promise.reject(new Error('Savenest is busy. Try again shortly.'));
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id); reject(new Error('This action is still taking time. Check Savenest before trying again.'));
      }, 120000);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(JSON.stringify({ ...command, id }) + '\n');
    });
  }
  fail(message) {
    if (this.closed) return;
    this.closed = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error(message)); }
    this.pending.clear(); this.emit('failure', message);
  }
  stop() {
    this.fail('Savenest is closing.');
    this.child.stdin.end();
    const child = this.child;
    const timer = setTimeout(() => { if (child.exitCode === null) child.kill('SIGTERM'); }, 1500);
    timer.unref();
  }
}
module.exports = { NativeClient };
