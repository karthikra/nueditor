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
- **Reverse channel (Mac → tower, REST):** ✅ shipped — `NUEDITBackendClient` talks to NUEDIT
  `/api/v1`; the tower's address comes from this machine's `~/.nuhandoff/hub.toml` SSOT with a
  Settings override. Authenticates with a per-machine agent key (`X-Agent-Key`) held in the Keychain; the
  tower is reached by its tailnet name (`http://tower:8000`), since App Transport Security blocks plain HTTP
  to a raw IP.
  Spec: `docs/phase4/swift-reverse-channel.md`.
- **Edge ingest:** NUEditor is the ingest point for raw footage — probe + checksum + local proxies,
  edit off the proxy, upload **only proxies** to the tower (raw never crosses the network), originals
  referenced in place, content-addressed relink, offline-tolerant, background. This is what feeds the
  whole tower-intelligence stack (caption/transcript/search/A-B-roll). ✅ Stages 0–3 shipped:
  backend client, content identity (SHA-256 + volume UUID), local proxies with an LRU-bounded
  content-addressed cache and playback off them, and `edge-register` + the `tower_link` MCP tool.
  Stage 5 (S3 archive of originals) built on this side for originals up to 5 GB: the Mac uploads
  straight to S3 on a tower-signed URL, one file at a time, refuses a file changed since it was
  hashed, and always calls `complete` so a failed upload stays retryable. Larger files wait on the
  tower's multipart flow — see `docs/phase4/2026-11-07-archive-originals-handoff.md`. Stage 4 ✅ shipped: originals are found by identity, not path (same drive by volume UUID plus
  path and size/date; any other drive only on a full SHA-256 match), relinked automatically when a
  project opens or a drive mounts, taken offline the moment their drive unmounts, kept editable from
  their proxies while offline, and named by drive in the export view and the `export_project` receipt.
  Live-verified with a disk image ejected and remounted at a new mount point.
  **Live-verified 2026-11-21** on a dedicated tower test project: link → register → single-PUT archive, driven
  over MCP, with the tower reading back the footage row and S3's stored size and SHA-256 (nuhub #29/#30).
  Originals over 5 GB go up in resumable 64 MiB parts (journal per machine in Application Support); **live-
  verified 2026-11-21** with a 5.4 GB file cut off by a network drop at part 40 of 82, resumed after an app
  restart under the same upload, and confirmed by the tower down to a full-object SHA-256 match (nuhub #31/#32).
  Re-calling `tower_link` is the retry for interrupted work.
  Plan: `docs/plans/2026-08-20-edge-ingest.md`.
- **Scriptmaker** panel (drives NUEDIT script/section/matching).
- **Generation UI:** trigger video/image/music/VO + the gap-fill flow from the editor.
- **Local LLM:** on-device MLX agent for offline/fast tasks; Bedrock for heavy reasoning.
- **Text-based editing:** edit spoken-word audio/video by editing its transcript — select words,
  press Delete, the media is cut and the gap closed (A/V kept in sync). Fully on-device
  (SpeechAnalyzer + Silero VAD). The cut engine already exists (`WordCutPlanner`, `remove_words`,
  ripple-delete with A/V sync); this adds the transcript-editor UI + VAD-snapped cuts + video
  jump-cut handling. ✅ All five stages shipped: transcript panel, select→Delete→cut, VAD-snapped
  cuts with a sample-accurate de-click and sub-frame audio trim, jump-cut softening (a cross-dissolve
  built from the outgoing clip's tail, suggested only where the picture actually pops), and the
  polish pass — one-click filler selection and in-place word correction stored with the project.
  Not done: B-roll "cover" over a join, which needs tower generation.
  Plan: `docs/plans/2026-08-20-text-based-editing.md`.
- **Fractional frame rates:** ✅ shipped — a project can hold 23.976 / 29.97 / 59.94 exactly
  (nominal count + the 1000/1001 pulldown, stored as the rational, never the decimal). `ntsc` is
  settable over MCP and `get_timeline` reports `fpsExact` / `fpsRational`. Drop-frame timecode is
  not implemented.
- In-editor B-roll review/override.

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
