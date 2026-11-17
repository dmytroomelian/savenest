import { main } from './release-orchestrator.mjs';

// One reproducible local release preparation command:
//   npm run release:electron            real signed/notarized arm64+x64+universal
//   npm run release:electron -- --plan  read-only plan, no credentials
//   npm run release:electron -- --jobs=1
// Resume by rerunning the same command; frozen snapshots, caches, helper
// signatures, submitted ZIPs, and verified archives are reused by provenance.
try {
  await main();
} catch (error) {
  console.error(error?.message || error);
  if (error?.code && error.code !== 'command-failed') console.error(`release preparation failed: ${error.code}`);
  process.exit(1);
}
