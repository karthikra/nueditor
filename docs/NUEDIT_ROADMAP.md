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

## Phase 3 — Generation, owned

- Replace the closed `generate_*` path: NUEDIT generates on the tower (NUVIDS / fal /
  nano-banana), then `import_media` into the editor.
- **Script-gap fill:** the backend already emits a `MISSING` timeline marker for every uncovered
  script section — that marker list is the shot list. Generate → import → `add_clips` into the gap.

## Phase 4 — Native features

- **Scriptmaker** panel (drives NUEDIT script/section/matching).
- **Local LLM**: on-device MLX agent for offline/fast tasks; Bedrock for heavy reasoning.
- **Video generator** UI surfacing NUEDIT generation + the gap-fill flow.
- Transcript-driven editing and in-editor B-roll review/override.

## Feature ownership (build once)

| Feature | Owner |
|---|---|
| Timeline / render / export / MCP engine | **Editor** (this repo) |
| Generation (video/image/audio) | **NUEDIT** (tower) → `import_media` |
| Scriptmaker, A/B-roll intelligence, search, batch transcript | **NUEDIT** (tower) |
| In-editor agent, quick on-device tasks | **Editor** (MLX, local) |
| Heavy reasoning | **NUEDIT** → AWS Bedrock |
