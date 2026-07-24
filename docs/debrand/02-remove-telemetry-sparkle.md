# Debrand Task 02 — Remove Sentry/PostHog (telemetry) + Sparkle (auto-update)

**For the Mac-side session.** Run **after** task 01, **before** task 03. Compile-loop against the
build; branch `debrand/remove-telemetry-sparkle`. Two independent parts — telemetry is trivial,
Sparkle is a small refactor.

## Part A — Telemetry (Sentry + PostHog) — low risk

All Sentry/PostHog code is already behind `#if PRODUCTION_TELEMETRY` (the `ProductionTelemetry`
trait), so it is **not compiled in default/dev builds**. Removal just makes that permanent.

1. **`Package.swift`** — remove deps `sentry-cocoa` and `posthog-ios`, their (trait-conditional)
   product edges (`Sentry`, `PostHog`), and the `ProductionTelemetry` trait entry itself.
2. **`Telemetry/Telemetry.swift`** and **`Telemetry/Analytics.swift`** — strip every
   `#if PRODUCTION_TELEMETRY` block and the `import Sentry` / `import PostHog`. Keep each type's
   public facade as **no-ops** (methods still exist, do nothing) so the call sites across the app
   still compile. (Prune the call sites in a later pass if desired.)
3. Grep for stray `PRODUCTION_TELEMETRY` references outside `Telemetry/` and clean up.

## Part B — Sparkle (auto-update) — small compile-loop

Sparkle is a hard dependency wired through a few files.

1. **`Package.swift`** — remove the `Sparkle` dep + product edge.
2. **`App/Updater.swift`** — this file is entirely Sparkle (`SPUStandardUpdaterController`,
   `SPUUpdater`, `SUAppcastItem`, `SPUUpdaterDelegate`). Replace it with a **no-op `Updater`
   stub**: keep `Updater.shared`, an observable `updateAvailable = false`, and a no-op
   `checkForUpdates()` — so `Home/HomeView.swift` (which reads `Updater.shared` /
   `updater.updateAvailable`) still compiles. Then, follow-up: remove the update-banner UI in
   `HomeView.swift` and any "Check for Updates…" menu command.
3. **`Resources/Info.plist`** — remove `SUFeedURL` and any other `SU*` keys (e.g.
   `SUEnableAutomaticChecks`, `SUPublicEDKey`).
4. **Delete `appcast.xml`** (repo root) and remove any appcast sign/publish steps in
   `scripts/release.sh`.

## Verify

- `swift build` green (+ `--traits BundledSpeech`); `swift test` green.
- `./scripts/dev.sh` launches; no update banner appears; app makes **no external calls**.
- `grep -rniE "sentry|posthog|sparkle|SPU[A-Z]|appcast|PRODUCTION_TELEMETRY" Sources/ Package.swift scripts/`
  returns nothing (bar intentional comments).

## Commit

Two commits (conventional, no AI attribution):
`refactor(debrand): remove Sentry/PostHog telemetry` and
`refactor(debrand): remove Sparkle auto-update`.
