# Debrand Task 03 — Rename PalmierPro → NUEditor

**For the Mac-side session.** Run **after** task 01 (Clerk/Convex) and 02 (Sentry/PostHog +
Sparkle) so the telemetry/updater files that also carry the old identifier are already gone.
Compile-loop against the build; branch `debrand/rename-nueditor`.

## Target identifiers

| Thing | Old | New |
|---|---|---|
| App display name | Palmier Pro | **NUEditor** |
| Bundle id | `io.palmier.pro` | **`com.veeville.nueditor`** |
| OSLog subsystem | `io.palmier.pro` | **`com.veeville.nueditor`** |
| Executable / SPM product | `PalmierPro` | **`NUEditor`** |
| Project document UTI | `io.palmier.project` | **`com.veeville.nueditor.project`** |
| URL scheme | `palmier` | **`nueditor`** |
| MCP server/bundle name | `palmier-pro` | **`nueditor`** |

(App display casing is `NUEditor`; the reverse-DNS id is fixed at `com.veeville.nueditor`.)

## Where each lives (grounded in the source)

- **`Utilities/Log.swift`** — `static let subsystem = "io.palmier.pro"`. This is the single source
  for the OSLog subsystem; change it here. **Note:** it also builds on-disk cache paths
  (`TranscriptCache`, `Search/Indexing/EmbeddingStore` append `\(Log.subsystem)/…` under Application
  Support), so caches relocate to a `com.veeville.nueditor/` dir — fine for a fresh app.
- **`Resources/Info.plist`** — `CFBundleIdentifier` (`io.palmier.pro`), `CFBundleName`,
  `CFBundleDisplayName`, the `io.palmier.project` document type + `palmier` URL scheme, and the
  Sparkle `SUFeedURL` appcast (already removed in task 02 — delete the key if it lingers).
- **`Agent/MCP/MCPService.swift`** — old id string; keep the **port `19789` unchanged** (NUEDIT
  and existing MCP clients target it), just rename the server identity.
- **`mcpb/manifest.json`** + **`mcpb/server/package.json`** — `name`/`display_name` `palmier-pro`.
- **`Utilities/KeychainStore.swift`**, **`Utilities/Constants.swift`** — old id references
  (keychain/app-group). Keychain usage should be minimal post-task-01 (no Clerk).
- **`scripts/bundle.sh`, `scripts/release.sh`, `scripts/dev.sh`** — `PalmierPro.app` /
  `io.palmier.pro` (the `dev.sh` OSLog `--predicate subsystem == "…"` must match the new subsystem).
- **`scripts/PalmierPro.entitlements`** — rename file → `NUEditor.entitlements`; update any
  app-group/id inside; fix references in the build scripts.
- **`Package.swift`** — `name: "PalmierPro"` and the executable product/target `PalmierPro`
  → `NUEditor` (the `path: "Sources/PalmierPro"` dir can stay or be renamed — renaming the dir is
  a bigger churn; optional).
- **`Telemetry/*`** — removed in task 02; if any file remains, drop the old id.
- App icon (`Resources/AppIcon.*`), localization strings, changelog — swap Palmier branding.

## Verify

- `swift build` green (+ `--traits BundledSpeech`); `swift test` green.
- `./scripts/dev.sh` launches; window/menus say **NUEditor**; **MCP server still on `127.0.0.1:19789`**.
- Built app's bundle id is `com.veeville.nueditor` (`mdls -name kMDItemCFBundleIdentifier NUEditor.app`
  or check `Info.plist` in the bundle).
- `grep -rniE "palmier" Sources/ scripts/ mcpb/` returns nothing but intentional history/attribution.

## Commit

`refactor(debrand): rename PalmierPro -> NUEditor (com.veeville.nueditor)` — conventional, no AI
attribution.
