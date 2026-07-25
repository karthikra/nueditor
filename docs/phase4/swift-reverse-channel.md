# Phase 4 (Swift) — Reverse channel: NUEditor → NUEDIT

> **STATUS: QUEUED — do NOT start yet.** Progress on the preconditions (2026-07-25):
> (1) debrand queue — ✅ done; (2) generation layer + video gap analysis (backend Phase 3) — ✅ done
> (video/image/music/voice-over over fal·Modal·local; marker + LLM gap streams); (3) NUEDIT MCP
> server — ✅ done (8 tools on tower `:8009`). **Still missing: the REST endpoints** this client
> consumes — generation/analyze-gaps/gap-fill exist today only as MCP tools + service code, not as
> `/api/v1` routes. The tower session builds those, then flips this to **READY** and pings.

## Goal

Give NUEditor a **thin client to NUEDIT's backend** so editor-initiated features (scriptmaker,
footage search, generation, gap-fill, B-roll review) call the backend rather than reimplementing
its intelligence in Swift. **REST is the path** (scalable, stateless, JWT); agents use the NUEDIT
MCP server separately.

## Reachability (no tunnel this direction)

NUEDIT's FastAPI binds `0.0.0.0:8000`, so the Mac reaches it directly over Tailscale at
`http://tower:8000` (contrast: the tower→editor MCP needs an SSH forward because NUEditor's MCP is
loopback). Auth: JWT / agent key issued by NUEDIT (`/api/v1/agent_keys`).

## Build (Swift, Mac)

1. **`NUEDITBackendClient`** — `URLSession` async/await client. Base URL + token in Settings.
   Handles sync JSON responses and async `{jobId}` responses (poll `GET .../jobs/{id}` or receive a
   webhook). One typed method per endpoint used.
2. **Settings** — backend base URL, token; a connection-status indicator.
3. **Panels** (each calls the client; place returned assets via the editor's *existing*
   `import_media`/`add_clips` — do not build a second import path):
   - **Scriptmaker** — upload/edit script + sections; trigger match/assemble on the backend.
   - **Footage search** — query → results (with importable URLs) → drop onto the timeline.
   - **Generation** — video / image / music / voice-over; show coverage gaps from `analyze_gaps`,
     trigger generation, poll the job, import the finished asset into the gap.
   - **B-roll review/override** — surface NUEDIT's A/B-roll calls for accept/override.
4. **Drag-to-ingest** — register dragged footage with NUEDIT (see below).

## Drag-to-ingest — make dragged footage "smart"

**Why:** the two sides share no database. NUEditor's media library is a **JSON manifest inside the
project package** referencing files in place (no DB, no SQLite); NUEDIT's knowledge lives in its
**Postgres** (`footage_files` → `video_chunks` → captions/transcript/roll signals) with bytes in S3.
So footage dragged straight into the editor is invisible to NUEDIT: **no VLM captions, no transcript,
no A/B-roll classification, no semantic search, no script matching.** Only footage ingested by NUEDIT
gets the intelligence.

**What to build:** on media import (drag-drop or file picker), optionally hand the file to NUEDIT so
it becomes a first-class ingested asset while staying usable locally straight away.

- **Opt-in + non-blocking.** A setting ("Send imported media to NUEDIT") and a per-import affordance.
  The drag must complete and the clip be immediately editable — ingest happens in the background;
  never block the UI on an upload.
- **Call** `POST /api/v1/footage/upload` (or `/upload/batch`), then poll `GET /api/v1/footage/{id}/status`
  until the pipeline finishes. Surface per-asset state in the media panel (queued → ingesting →
  captioned/searchable, or failed) — a small badge, not a modal.
- **Store the mapping.** Persist NUEDIT's `footage_id` on the `MediaManifestEntry` (the manifest is
  the editor's source of truth) so the clip can later be searched, roll-reviewed, or matched, and so
  re-imports don't double-ingest. Dedupe on that id (plus a content hash if cheap).
- **Big files:** prefer sending a path/URL NUEDIT can pull, or a resumable/chunked upload, over one
  giant POST; large masters are the norm. Respect NUEDIT's rate limits (`RATE_LIMIT_UPLOAD`).
- **Offline / backend unreachable:** degrade silently to local-only import (the current behavior) and
  let the user retry later — never lose the clip or fail the drop.
- **Reverse direction already exists:** footage NUEDIT already owns arrives via `import_media`
  (url/path) during a tower-side push — don't duplicate that path here.

## NUEDIT endpoints this consumes (tower `/api/v1`)

`search`, `scripts/*` (sections, `match`, `select`), `timelines/{id}/assemble`,
`footage/upload` + `footage/{id}/status` (drag-to-ingest), `footage` (list/status).
**Not yet routed (MCP-only today, tower to add):** `analyze-gaps`, gap-fill, and
`generation/{video|image|music|voiceover}` + job polling. Exact shapes finalized when those land.

## Constraints

- **Do not duplicate NUEDIT logic in Swift** — the editor is a thin client for these features.
- **Do not touch the MCP server / `Agent/Tools/*`** — that's the inbound (agent→editor) surface;
  this task is the outbound (editor→backend) surface, a separate client.
- Generated/returned assets flow through the normal media library (tag AI-generated where the
  backend marks them).

## Not this task

The **NUEDIT MCP server** (so Claude/Cursor can call NUEDIT's services) is **tower-side** — it is
not built here. Agents connect to it directly; this Swift client is only for the editor app itself.
