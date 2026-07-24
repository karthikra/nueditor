@AGENTS.md

# NUEDIT Editor — project context

This repo is a fork of **Palmier Pro** (`palmier-io/palmier-pro`, GPLv3) being taken over
entirely and rebuilt as the **NUEDIT** AI-native video editor. `@AGENTS.md` above governs Swift
engineering style; this file governs *what we are building and why*. When they conflict on
process, this file wins; on Swift style, AGENTS.md wins.

## The product in one line

NUEDIT is a two-part system:
- **This editor** (Swift 6.2 / SwiftUI + AppKit / AVFoundation / Metal, macOS 26, arm64) — the
  front-end and hands: timeline engine, compositing, rendering, transcript/caption editing,
  export, and the **MCP server** (`127.0.0.1:19789/mcp`).
- **The NUEDIT backend** (Python / FastAPI on a Linux GPU tower — repo `karthikra/nuedit`) — the
  brain: ingest, VLM captioning, transcript, semantic search, A-roll/B-roll classification
  (incl. measured active-speaker detection / Light-ASD), script→section matching, B-roll
  association, and generation.

The backend drives this editor over MCP. Two repos, two languages, one product.

## Ownership stance — clean, unbranded, self-owned

Keep everything open and local (timeline engine, compositing, export, MCP tools, agent chat) and
extend it. Remove everything that phones home to Palmier's servers:

- **Clerk** (hosted auth/identity) + **Convex** (hosted reactive backend + the *closed*
  generative-AI broker) — the only umbilical to palmier.io. **Remove entirely; go local-only,
  no login.** NUEDIT is our backend. (Add accounts later only if cloud sync/multi-user is ever
  wanted.)
- **Sentry + PostHog** (telemetry — already trait-gated off via `ProductionTelemetry`) — remove.
- **Sparkle** (auto-update feed) — remove or repoint to our own.

Debrand every surface: app name/bundle id/subsystem `io.palmier.pro`, `Resources/AppIcon.*`,
`Info.plist` (incl. `PalmierClerk*` / `PalmierConvex*` keys), localization strings, changelog,
and the MCP server/bundle name `palmier-pro` (`mcpb/`).

## Architecture — build each feature in ONE place (never twice)

- **Generation (video/image/audio):** **NUEDIT owns it** (tower: NUVIDS / fal / nano-banana) →
  `import_media` into the editor. Do NOT depend on Palmier's closed `generate_*` backend.
- **Scriptmaker:** NUEDIT computes script → sections → matching; surface it here as a panel /
  over MCP. Don't reimplement the matching in Swift.
- **Local LLM — BOTH:** on-device **MLX** (already a dep) for fast/offline in-editor tasks
  (agent chat, quick scriptmaking); **NUEDIT / AWS Bedrock** (Claude via Bedrock, per house
  rules) for heavy reasoning.
- **A/B-roll intelligence, batch transcript, semantic search:** NUEDIT. The editor renders the
  results and lets the human review/override.

## Integration seam

NUEDIT is an MCP *client* of this editor's server. Design doc lives in the backend repo:
`docs/superpowers/specs/2026-07-24-palmier-mcp-integration-design.md`. Core mapping: NUEDIT
timeline is in **milliseconds**, the editor in **project frames** (`round(ms/1000*fps)`);
V1 A-roll → `trackIndex 0`, V2 B-roll → `trackIndex 1`; footage → `import_media` → `mediaRef`.

## Build / run (details in AGENTS.md)

```bash
swift build && swift run          # or:
./scripts/dev.sh                  # debug .app + OSLog stream (subsystem io.palmier.pro)
swift test
```
Use `--traits BundledSpeech` for MLX / speech / transcription work. Keep telemetry OFF (never
enable the `ProductionTelemetry` trait in dev/our builds).

## Commit rules

Conventional commits. **No AI/assistant attribution, no Co-Authored-By, never mention AI in
commit messages.**

## Roadmap

See `docs/NUEDIT_ROADMAP.md`.
