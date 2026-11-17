# SaveNest agent learnings

Verified lessons, plus evidence-backed candidates whose cause is uncertain; `verified`/`applied` require actual validation. Retrieve matching entries only; capture rules live in `.agents/skills/savenest-self-improve/SKILL.md`. No transcripts, private paths, secrets, account data, or customer content. Relative repo references only. Repetition is not proof.

## ui.asset-allowlist — test launcher assets through the real protocol allowlist
- **2026-11-17 · applied**
- **Scope:** Electron launcher UI (`electron/renderer/`), preview tests.
- **Evidence:** jsdom injected `features.js` directly, but real `savenest-ui:` serving rejected `features.js`/`features.css` until `assetName` allowed them (`electron/contracts.cjs:85-91`). Regression `electron/tests/contracts.test.cjs:48-54` scans every local `src`/`href` in `electron/renderer/index.html` through the real allowlist.
- **Cause:** the test harness bypassed the production protocol boundary.
- **Action/owner:** keep the asset regression plus a preview visual check, and add new local scripts/styles to `assetName`. UI owner.
- **Verification:** regression test present. Reported by Codex review, not run by the skill worker: final targeted contracts+discovery 32/32, npm suite 104/104, CUA preview succeeded.
- **Invalidate if:** launcher assets use another validator or HTML asset discovery changes.

## ui.installed-vs-source — verify installed UI before relocating a feature
- **2026-11-17 · verified**
- **Scope:** UI review and relocation of installed Electron features.
- **Evidence:** the installed SaveNest app's catalog differed from the current checkout source during this review; behavior matched only after checking the actual app plus owning source. The current source had lost the installed catalog.
- **Cause/uncertainty:** installed builds can differ from the checkout; source alone is not runtime truth.
- **Action/owner:** for UI relocation, compare the installed app with `electron/` and `Sources/SaveNest/`. Do not require installed-app inspection for unrelated work. UI owner.
- **Verification:** observed installed UI and source mapping; no automated test.
- **Invalidate if:** the review target is a fresh build proven identical to source.

## release.arch-outputs — prepare shared UI/icons once or isolate before parallel stages
- **2026-11-17 · verified**
- **Scope:** `npm run release:electron` Apple Silicon/Intel staging.
- **Evidence:** release review observed architecture builds sharing UI/icon outputs; concurrent stages can overwrite shared inputs. Not independently rebuilt by this skill task.
- **Cause:** common generated asset directories are used by per-architecture stages.
- **Action/owner:** prepare shared UI/icons once before stages or isolate each stage in separate work directories. Release owner.
- **Verification:** release review observation only; no release build executed here.
- **Invalidate if:** packaging writes architecture-specific UI/icon outputs.

## release.signing-workspace — keep signing outside synced Desktop/iCloud folders
- **2026-11-17 · verified (documented)**
- **Scope:** signed/notarized release staging.
- **Evidence:** `scripts/package-electron-release.mjs` signing-workspace setup and `docs/maintainers.md` section "Official Electron distribution" both warn that Desktop/iCloud file providers can attach metadata after cleanup; the script defaults to `mkdtemp`.
- **Cause:** file-provider metadata can invalidate signatures.
- **Action/owner:** use non-synced temp space or `RELEASE_WORK_DIR`; validate the final archive. Release owner.
- **Verification:** documented constraint only; no signing outcome verified here.
- **Invalidate if:** packaging stops using file-provider-sensitive staging.
