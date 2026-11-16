import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const requested = process.env.TARGET_ARCH || process.arch;
const architecture = requested === 'x86_64' ? 'x64' : requested;
if (!['arm64', 'x64'].includes(architecture)) throw new Error('Unsupported Services architecture.');
const output = path.join(root, 'build/services', architecture, 'savenest-services.node');
mkdirSync(path.dirname(output), { recursive: true });
execFileSync('xcrun', ['clang', '-fobjc-arc', '-O2', '-bundle', '-undefined', 'dynamic_lookup',
  '-mmacosx-version-min=14.0', '-arch', architecture === 'x64' ? 'x86_64' : 'arm64',
  '-DNAPI_VERSION=8', '-I', require('node-api-headers').include_dir, '-framework', 'AppKit',
  path.join(root, 'electron/native/services.m'), '-o', output], { stdio: 'inherit' });
console.log(`Built Services adapter (${architecture}).`);
