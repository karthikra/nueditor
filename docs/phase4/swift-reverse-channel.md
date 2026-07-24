# Phase 4 (Swift) — Reverse channel: NUEditor → NUEDIT

> **STATUS: QUEUED — do NOT start yet.** This depends on tower-side work that does not exist:
> (1) the debrand queue (`docs/debrand/`) complete, (2) NUEDIT REST endpoints for editor-initiated
> flows + the generation layer (backend Phase 3), (3) the NUEDIT MCP server (backend Phase 4).
> The tower session will flip this to **READY** (and ping) when the backend is in place. Until then,
> keep working the debrand.

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

## NUEDIT endpoints this consumes (tower `/api/v1`)

`search`, `scripts/*` (sections, `match`, `select`), `timelines/{id}/assemble`,
`timelines/{id}/analyze-gaps`, `generation/{video|image|music|voiceover}` + `jobs/{id}`,
`footage` (list/status). (Exact shapes finalized when backend Phase 3/4 lands.)

## Constraints

- **Do not duplicate NUEDIT logic in Swift** — the editor is a thin client for these features.
- **Do not touch the MCP server / `Agent/Tools/*`** — that's the inbound (agent→editor) surface;
  this task is the outbound (editor→backend) surface, a separate client.
- Generated/returned assets flow through the normal media library (tag AI-generated where the
  backend marks them).

## Not this task

The **NUEDIT MCP server** (so Claude/Cursor can call NUEDIT's services) is **tower-side** — it is
not built here. Agents connect to it directly; this Swift client is only for the editor app itself.
