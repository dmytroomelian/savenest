# SaveNest agent entrypoint

Scope: this repository. Preserve the user's dirty changes and excluded duplicate `* 2.*` files unless active references prove a duplicate is canonical. Do not broaden permissions here.

## Skill routing

- At the start and end of a nontrivial task, follow [savenest-self-improve](.agents/skills/savenest-self-improve/SKILL.md).
- Before work, read only matching entries in [project learnings](.agents/learnings.md); after work, record a verified delta, an evidence-backed candidate, or nothing.
- Follow the user's active Caveman and OpenCode-first preferences without redefining them. When available, `~/.codex/skills/opencode-go/SKILL.md` is the default route for nontrivial local coding/research, with its delegation, one-focused-retry, and budget constraints. Do not change model/reasoning or disable plugins automatically.

## Project map

- Electron shell and renderer: [electron/](electron/) (chiefly `electron/main.cjs`, `electron/contracts.cjs`, `electron/renderer/`).
- Native Swift helper and Settings: [Sources/SaveNest/](Sources/SaveNest/).
- Checks, packaging, and release scripts: [scripts/](scripts/); npm entry points in [package.json](package.json) (`npm test`, `npm run preview`, `npm run test:smoke`).
- Release authority and acceptance: [docs/maintainers.md](docs/maintainers.md) and [docs/preview-acceptance.md](docs/preview-acceptance.md).
- Tests: Electron `node --test electron/tests/*.test.cjs`; Swift per [Package.swift](Package.swift).

Keep signing, tests, and security intact. Do not commit, publish, change billing, or modify global memory because a skill suggested it.
