// Real macOS Services delivery through Electron to the preview Swift library.
// Installs a uniquely named disposable fixture and removes it in finally.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, writeFile, cp, rm, access } from 'node:fs/promises';
import { homedir, tmpdir } from 'node:os';
import path from 'node:path';

const root = process.cwd();
const work = await mkdtemp(path.join(tmpdir(), 'savenest-services-check-'));
const suffix = path.basename(work).split('-').at(-1);
const name = `SaveNest Services Check ${suffix}`;
const appPath = path.join(homedir(), 'Applications', `${name}.app`);
const resources = path.join(appPath, 'Contents/Resources');
const register = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister';
const helper = path.join(root, 'build/electron-native/SaveNest.app/Contents/MacOS/SaveNest');
const run = (command, args) => execFileSync(command, args, { encoding: 'utf8', timeout: 45000, stdio: ['ignore', 'pipe', 'pipe'] });
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const stateFile = path.join(work, 'state.json');
let fixturePID;
async function state() { try { return JSON.parse(await readFile(stateFile, 'utf8')); } catch { return null; } }
async function waitFor(predicate, label) {
  for (let i = 0; i < 100; i++) {
    const value = await state();
    if (value?.fatal) throw new Error(value.fatal);
    if (value) fixturePID = value.pid;
    if (value && predicate(value)) return value;
    await pause(100);
  }
  throw new Error(`Timed out: ${label}`);
}
async function command(request) {
  const id = Date.now();
  await writeFile(path.join(work, 'control.json'), JSON.stringify({ id, request }));
  return waitFor(value => value.ack === id, request.command);
}
try {
  await access(helper);
  await mkdir(path.dirname(appPath), { recursive: true });
  run('cp', ['-cR', path.join(root, 'node_modules/electron/dist/Electron.app'), appPath]);
  const plist = path.join(appPath, 'Contents/Info.plist');
  const info = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', plist]));
  Object.assign(info, { CFBundleIdentifier: `app.savenest.services.check.${suffix}`, CFBundleName: name, CFBundleDisplayName: name, LSUIElement: true });
  const production = JSON.parse(run('plutil', ['-convert', 'json', '-o', '-', path.join(root, 'Resources/Info.plist')]));
  info.NSServices = production.NSServices.map(service => ({ ...service, NSMenuItem: { default: name }, NSPortName: name }));
  await writeFile(plist, JSON.stringify(info)); run('plutil', ['-convert', 'xml1', plist]);
  await mkdir(path.join(resources, 'native'), { recursive: true });
  await cp(path.join(root, 'build/services', process.arch, 'savenest-services.node'), path.join(resources, 'native/savenest-services.node'));
  await mkdir(path.join(resources, 'app'));
  await writeFile(path.join(resources, 'app/package.json'), JSON.stringify({ main: 'main.cjs' }));
  await writeFile(path.join(resources, 'app/main.cjs'), `
const {app}=require('electron'), fs=require('node:fs'), path=require('node:path');
const {NativeClient}=require(${JSON.stringify(path.join(root, 'electron/native-client.cjs'))});
const {createServiceQueue,registerServices}=require(${JSON.stringify(path.join(root, 'electron/services.cjs'))});
const work=${JSON.stringify(work)};
app.setPath('userData',path.join(work,'profile'));
let native, current={}, errors=[], ack=0, deliveries=0, initialCount;
const publish=()=>fs.writeFileSync(path.join(work,'state.json'),JSON.stringify({pid:process.pid,state:current,errors,ack,deliveries,initialCount}));
const fail=e=>fs.writeFileSync(path.join(work,'state.json'),JSON.stringify({pid:process.pid,fatal:String(e)}));
const queue=createServiceQueue({capture:async url=>{await native.request({command:'serviceCapture',url});},onError:e=>{errors.push(e.message);publish();}});
app.whenReady().then(()=>{
 registerServices({app,root:${JSON.stringify(root)},preview:false,receive:url=>{deliveries++;queue.receive(url);publish();}});
 native=new NativeClient(${JSON.stringify(helper)},{preview:true});
 native.on('event',m=>{if(m.event==='state'){current=m.state;if(initialCount===undefined)initialCount=current.savedCount;queue.ready();publish();}else if(m.event==='fatal')fail(m.message);});
 native.on('failure',fail);
 let handling=false;
 setInterval(async()=>{if(handling)return;const file=path.join(work,'control.json');if(!fs.existsSync(file))return;handling=true;try{const c=JSON.parse(fs.readFileSync(file));fs.unlinkSync(file);if(c.quit){app.quit();return;}await native.request(c.request);ack=c.id;publish();}catch(e){fail(e);}finally{handling=false;}},50);
 setTimeout(()=>app.quit(),120000);
}).catch(fail);
app.on('before-quit',()=>native?.stop());
`);
  run('xattr', ['-cr', appPath]); run('codesign', ['--force', '--deep', '--sign', '-', appPath]);
  await writeFile(path.join(work, 'invoke.swift'), `import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
NSUpdateDynamicServices()
let board = NSPasteboard.withUniqueName()
board.setString(CommandLine.arguments[2], forType: CommandLine.arguments.count > 3 ? .URL : .string)
print(NSPerformService(CommandLine.arguments[1], board))
board.releaseGlobally()
`);
  run('swiftc', [path.join(work, 'invoke.swift'), '-o', path.join(work, 'invoke')]);
  run(register, ['-f', appPath]);
  const invoke = (url, typed = false) => run(path.join(work, 'invoke'), [name, url, ...(typed ? ['url'] : [])]);
  const url = 'https://example.com/savenest-services-fixture?one=1#anchor';
  // Refresh registration before timing the first real invocation; no app is launched here.
  run('/System/Library/CoreServices/pbs', ['-update']);
  await pause(500);
  const coldStart = Date.now(); invoke(url);
  let value = await waitFor(v => v.state.captureDraft?.url === url, 'cold-start editor');
  const coldMs = Date.now() - coldStart;
  assert.equal(value.state.preview, true);
  assert.equal(value.state.savedCount, value.initialCount, 'Opening Services must not save.');
  const id = value.state.captureDraft.id;
  invoke('https://example.com/second');
  value = await waitFor(v => v.errors.length === 1, 'busy draft rejection');
  assert.match(value.errors[0], /Finish or cancel/);
  assert.equal(value.state.captureDraft.id, id, 'Busy draft must remain intact.');
  await command({ command: 'saveDraft', ids: [id], note: 'Services integration note', tags: ['Services'] });
  await waitFor(v => !v.state.captureDraft && v.state.savedCount === v.initialCount + 1, 'explicit save');
  const warmStart = Date.now(); invoke(url, true);
  value = await waitFor(v => v.state.captureDraft?.id === id, 'saved link reopened');
  const warmMs = Date.now() - warmStart;
  assert.equal(value.state.captureDraft.note, 'Services integration note');
  assert.deepEqual(value.state.captureDraft.tags, ['Services']);
  await command({ command: 'cancelDraft' });
  await waitFor(v => !v.state.captureDraft, 'cancelled editor');
  console.log(JSON.stringify({ passed: true, coldMs, warmMs, checks: ['real Services delivery', 'cold launch', 'URL/text pasteboards', 'busy draft protection', 'explicit save', 'duplicate note and tags', 'cancel'] }));
} finally {
  try { await writeFile(path.join(work, 'control.json'), JSON.stringify({ quit: true })); await pause(300); } catch {}
  if (fixturePID) { try { process.kill(fixturePID, 'SIGTERM'); } catch {} }
  try { run(register, ['-u', appPath]); } catch {}
  await rm(appPath, { recursive: true, force: true });
  try { run('/System/Library/CoreServices/pbs', ['-update']); } catch {}
  await rm(work, { recursive: true, force: true });
}
