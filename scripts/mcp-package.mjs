import { access, copyFile, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

// Public builds never implicitly consume a sibling private checkout. Official
// builds opt in with a reviewed private package or a previously built artifact.
export async function prepareMCP({ architecture, workspace, env = process.env }) {
  const packagePath = env.SAVENEST_MCP_PACKAGE_PATH;
  const suppliedBinary = env.SAVENEST_MCP_BINARY;
  if (packagePath && suppliedBinary) throw new Error('Set only SAVENEST_MCP_PACKAGE_PATH or SAVENEST_MCP_BINARY.');
  if (!packagePath && !suppliedBinary) return null;
  const cpu = architecture === 'x64' ? 'x86_64' : 'arm64';
  let binary, license, thirdParty;
  if (packagePath) {
    const source = path.resolve(packagePath);
    const scratch = path.join(workspace, `mcp-build-${architecture}`);
    const arguments_ = ['build', '--build-system', 'native', '--package-path', source, '--scratch-path', scratch,
      '--configuration', 'release', '--arch', cpu, '--product', 'savenest-mcp', '--disable-automatic-resolution'];
    await access(path.join(source, 'Package.resolved'));
    execFileSync('swift', arguments_, { stdio: 'inherit' });
    const binDirectory = execFileSync('swift', [...arguments_, '--show-bin-path'], { encoding: 'utf8' }).trim();
    binary = path.join(binDirectory, 'savenest-mcp');
    license = path.join(source, 'LICENSE');
    const notices = ['SaveNest Pro MCP third-party notices\nDependency versions are pinned in Package.resolved.\n'];
    const checkouts = path.join(scratch, 'checkouts');
    for (const dependency of (await readdir(checkouts)).sort()) {
      const directory = path.join(checkouts, dependency);
      for (const file of (await readdir(directory)).filter(name => /^(license|notice|copying)(\..+)?$/i.test(name)).sort()) {
        notices.push(`\n--- ${dependency}/${file} ---\n${await readFile(path.join(directory, file), 'utf8')}`);
      }
    }
    if (notices.length < 2) throw new Error('The MCP SDK and dependency notices must be included.');
    const artifact = path.join(workspace, `mcp-${architecture}`);
    await mkdir(artifact, { recursive: true });
    await copyFile(binary, path.join(artifact, 'savenest-mcp'));
    await copyFile(license, path.join(artifact, 'LICENSE'));
    thirdParty = path.join(artifact, 'THIRD_PARTY_NOTICES.txt');
    await writeFile(thirdParty, notices.join('\n'));
    binary = path.join(artifact, 'savenest-mcp');
    license = path.join(artifact, 'LICENSE');
  } else {
    binary = path.resolve(suppliedBinary);
    license = path.join(path.dirname(binary), 'LICENSE');
    thirdParty = path.join(path.dirname(binary), 'THIRD_PARTY_NOTICES.txt');
  }
  await Promise.all([access(binary), access(license), access(thirdParty)]);
  execFileSync('lipo', [binary, '-verify_arch', cpu]);
  for (const file of [license, thirdParty]) {
    if ((await readFile(file)).length < 50) throw new Error('The MCP component requires commercial and third-party notices.');
  }
  return { binary, license, thirdParty };
}
