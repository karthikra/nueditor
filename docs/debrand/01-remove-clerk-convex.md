# Debrand Task 01 — Remove Clerk + Convex (go local-only)

**For the Mac-side session.** Execute against the Swift compiler in your checkout. See `CLAUDE.md`
for why. Goal: rip out the two hosted services — **Clerk** (auth/identity) and **Convex**
(backend + closed generation broker + cloud transcription) — so the editor runs **local-only, no
login**, with NUEDIT as the backend.

## Preconditions

1. `swift build` is **green before you start** (establish a baseline; the first resolve/compile
   is slow — MLX/transformers/etc.).
2. Work on a branch: `git checkout -b debrand/remove-clerk-convex`.

## What must NOT change

- The **MCP server + `Agent/Tools/*`** — confirmed to have zero Clerk/Convex dependency; NUEDIT
  drives the editor through them. Leave them intact.
- The timeline engine, compositing, export.

## Tactic: stub to keep the build green, then prune

Do **not** mass-delete services — many UI/agent callers reference them and you'll drown in
cascade errors. Instead, first **gut each service to a local-only stub** (drop the Clerk/Convex
imports, keep the public API returning sensible local defaults), get `swift build` green, then
remove now-dead UI in a follow-up commit.

## Steps

### 1. `Package.swift`
Remove the three dependencies and their target product edges:
- deps: `clerk-convex-swift`, `clerk-ios`, `convex-swift`
- target products: `ClerkConvex`, `ClerkKit`, `ConvexMobile`

### 2. `Backend/BackendConfig.swift`
Delete the `clerkPublishableKey`, `clerkKeychainAccessGroup`, `convexDeploymentURL`,
`convexHttpURL` accessors. Remove the matching `PalmierClerk*`/`PalmierConvex*` keys from
`Info.plist`.

### 3. `Account/AccountService.swift` (the hub)
Remove `import ClerkKit/ClerkConvex/ConvexMobile`, `Clerk.configure(...)`, and the
`ConvexClientWithAuth(...ClerkConvexAuthProvider())`. Reduce to a local-only stub: no session, no
credits, `canGenerate = false`. Keep the public surface callers use so they still compile.

### 4. `Account/` UI — `AccountPopoverCard`, `CreditSummaryView`, `IdentityViews`, `TopOffField`
Login/credits UI. Once AccountService is a stub, remove these and their entry points (menu items,
toolbar buttons). Grep for their call sites and delete cleanly.

### 5. `App/AppDelegate.swift`
Remove `import ClerkKit` and the `Clerk.shared.handle(url)` OAuth deep-link callback block.

### 6. `Generation/{GenerationBackend,GenerationService,ModelCatalog}.swift`
This is the **closed** generation path (Convex `ConvexEncodable` calls). Remove the Convex path.
Short-term: `ModelCatalog` returns `loaded=false`/empty and generation calls fail gracefully
(`canGenerate=false`) — the `generate_*` MCP tools already handle this. NUEDIT wires generation
back in Phase 3 (own stack → `import_media`). Keep the tool/service interfaces intact.

### 7. `Transcription/TranscriptionBackend.swift`
Remove the Convex (cloud) transcription path. Route transcription to the on-device implementation
in `Transcription/Transcription.swift`. Verify with `--traits BundledSpeech`. Confirm the caller
selects the on-device path unconditionally now.

### 8. `Agent/Clients/PalmierClient.swift`
Remove the `Clerk.shared.session` guard. If the in-app agent chat depends on a hosted
Clerk/Convex endpoint, disable that in-app hosted agent for now (external MCP agents — NUEDIT,
Claude Desktop — are unaffected because the MCP server is separate). Revisit with local MLX +
NUEDIT later.

## Verify

- `swift build` green (and `swift build --traits BundledSpeech`).
- `swift test` green.
- `./scripts/dev.sh` launches the app; **MCP server live on `127.0.0.1:19789`**.
- App runs with **no login UI**; generation shows unavailable (expected — Phase 3 rewires it);
  transcription still works on-device.
- `grep -rnE "Clerk|Convex" Sources/` returns nothing (except comments you intend to keep).

## Commit

Conventional commits, **no AI attribution**. Suggested:
`refactor(debrand): remove Clerk + Convex — local-only, no login`
Then a follow-up `refactor(debrand): remove dead account/credits UI` if you split the prune.

## Next debrand tasks (later docs in this dir)

- `02` — remove Sentry/PostHog (telemetry) + Sparkle (auto-update).
- `03` — rename PalmierPro → **NUEditor** (bundle id/subsystem `io.palmier.pro`, app name, icons,
  Info.plist, localization, changelog, `mcpb/` server name `palmier-pro`).
