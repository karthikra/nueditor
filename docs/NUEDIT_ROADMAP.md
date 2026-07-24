# NUEditor — roadmap

Fork of Palmier Pro → **NUEditor**, the AI-native editor (the **NUEDIT** backend is the brain).
See `CLAUDE.md` for the full context. Each phase ships something runnable.

## Phase 0 — Bootstrap (current)

- Clone this fork on the Mac; `swift build`; `./scripts/dev.sh` launches the editor + its MCP
  server on `127.0.0.1:19789`.
- Validate the NUEDIT→editor MCP seam (Task 0 in the backend spec): list tools, `create_timeline`,
  `import_media` (matte — no footage needed), `add_clips`, `get_timeline` read-back. NUEDIT
  reaches the Mac over Tailscale via an SSH local-forward.

## Phase 1 — Debrand & de-service

Ordered execution queue in **`docs/debrand/`** (see `docs/debrand/README.md`):
1. `01-remove-clerk-convex.md` — Clerk + Convex → local-only, no login.
2. `02-remove-telemetry-sparkle.md` — Sentry/PostHog + Sparkle → no external calls.
3. `03-rename-to-nueditor.md` — PalmierPro → NUEditor (`com.veeville.nueditor`).

Result: a clean, unbranded, self-owned editor with a live MCP server and no external calls.

## Phase 2 — NUEDIT drives the editor (MCP integration)

- Backend implements the MCP client (`app/services/palmier.py`) + pure ms↔frame mapping
  (`app/core/palmier_map.py`) + push-assembly viewmodel.
- Push a real assembled timeline (V1 A-roll / V2 B-roll) from a NUEDIT project into the editor,
  read back, reconcile.
- Spec: backend repo `docs/superpowers/specs/2026-07-24-palmier-mcp-integration-design.md`.

## Phase 3 — Generation layer + gap analysis (tower)

A **backend-flexible generation layer** — every capability can run on the **tower** (local GPU),
**Modal** (serverless GPU), or **fal** (hosted API), chosen per-capability by config and swappable
without touching callers. Async (job + webhook/poll); results land as NUEDIT assets → `import_media`
into the editor. Full design: NUEDIT repo `docs/superpowers/specs/2026-07-24-generation-layer-design.md`.

- **Capabilities:** **video generation**, **image generation**, **music generation**,
  **voice-over (TTS)**.
- **Video gap analysis:** `analyze_coverage(timeline)` reads `MISSING` + `LOW_CONFIDENCE` markers
  and section coverage → per-gap **generation briefs** (prompt/duration/aspect/style-ref) = the
  shot list to generate.
- **Gap fill:** briefs → generate → register asset → `add_clips` into the `MISSING` slot.
- Exposed via NUEDIT REST + the NUEDIT MCP server (Phase 4).

## Phase 4 — Reverse channel + native features (Mac + tower)

- **NUEDIT MCP server (tower):** agent-facing facade over NUEDIT's services (search, match,
  assemble, classify, generate, analyze_gaps) — so Claude/Cursor drive **both** NUEditor's MCP
  (edit) and NUEDIT's MCP (intelligence/generation).
- **Reverse channel (Mac → tower, REST):** a Swift REST client to NUEDIT `/api/v1` (JWT) — the
  scalable path for editor-initiated features. Spec: `docs/phase4/swift-reverse-channel.md`.
- **Scriptmaker** panel (drives NUEDIT script/section/matching).
- **Generation UI:** trigger video/image/music/VO + the gap-fill flow from the editor.
- **Local LLM:** on-device MLX agent for offline/fast tasks; Bedrock for heavy reasoning.
- Transcript-driven editing and in-editor B-roll review/override.

## Feature ownership (build once)

| Feature | Owner |
|---|---|
| Timeline / render / export / MCP engine | **Editor** (this repo) |
| Generation — video / image / music / voice-over | **NUEDIT** generation layer (tower · Modal · fal, per-capability) → `import_media` |
| Video gap analysis (what's missing → briefs) | **NUEDIT** (tower) |
| Scriptmaker, A/B-roll intelligence, search, batch transcript | **NUEDIT** (tower) |
| Reverse channel (editor → backend) | **REST** `/api/v1` (Swift client on Mac) + **NUEDIT MCP** for agents |
| In-editor agent, quick on-device tasks | **Editor** (MLX, local) |
| Heavy reasoning | **NUEDIT** → AWS Bedrock |
