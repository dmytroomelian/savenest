import { readFile, access } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

export function captureCapability(binary) {
  const symbols = execFileSync('/usr/bin/strings', [binary], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
  const enabled = symbols.includes('SaveNestSocialCaptureCapability-v1=enabled');
  const disabled = symbols.includes('SaveNestSocialCaptureCapability-v1=disabled');
  if (enabled === disabled) throw new Error('Native helper has missing or ambiguous social capture capability. Rebuild it.');
  return enabled;
}

export async function prepareSocialCapture({ binary, env = process.env }) {
  const enabled = captureCapability(binary);
  const source = env.SAVENEST_PRO_CAPTURE_PACKAGE;
  if (enabled !== Boolean(source)) throw new Error('Built social capture capability does not match packaging intent. Rebuild the helper.');
  if (!enabled) return { enabled: false };
  const license = path.join(source, 'LICENSE');
  const thirdParty = path.join(source, 'THIRD_PARTY_NOTICES.txt');
  await Promise.all([access(license), access(thirdParty)]);
  if (!(await readFile(license, 'utf8')).includes('SaveNest Pro Capture component license')
      || (await readFile(thirdParty)).length < 50) throw new Error('Capture component license and dependency notices are required.');
  return { enabled: true, license, thirdParty };
}
