# NUEditor debrand — task queue

Fork of Palmier Pro → **NUEditor** (see `../../CLAUDE.md`). Run these on the Mac **in order**,
compile-loop against the build, each on its own branch, and **verify (`swift build` + `swift test`
+ `./scripts/dev.sh`) before committing**. Use the stub-then-prune tactic — keep the build green.

| # | Task | Effect | Doc |
|---|------|--------|-----|
| 0 | Preconditions | green `swift build` baseline; branch per task | — |
| 1 | Remove **Clerk + Convex** | auth + closed generation/cloud-transcription gone → **local-only, no login** | `01-remove-clerk-convex.md` |
| 2 | Remove **Sentry/PostHog + Sparkle** | no telemetry, no auto-update → **no external calls** | `02-remove-telemetry-sparkle.md` |
| 3 | Rename **PalmierPro → NUEditor** | `com.veeville.nueditor`, display name NUEditor, UTI/scheme/mcpb | `03-rename-to-nueditor.md` |

**Order matters:** task 3 (rename) assumes 1 and 2 already deleted the files that also carry the
old `io.palmier.pro` identifier (Telemetry, etc.). Throughout, **do not touch the MCP server or
`Agent/Tools/*`** — NUEDIT drives the editor through them (they have no Clerk/Convex/telemetry
dependency), and the MCP port `19789` stays fixed.

After the queue: NUEditor is unbranded, local-only, and renamed — ready for Phase 2+
(NUEDIT MCP integration, owned generation, native features) in `../NUEDIT_ROADMAP.md`.
