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

## Edge ingest — NUEditor is the primary ingest point (supersedes "drag-to-ingest")

**The topology:** raw footage arrives **here, on the Mac, usually on an external drive** — never on
the tower. Raw must not cross the network (nor be copied to the Mac's SSD: 926 GB but only ~35 GB
free). And the two sides share no database — NUEditor's library is a **JSON manifest referencing files
in place**; NUEDIT's knowledge lives in its **Postgres**. So footage dragged in is invisible to NUEDIT
(no captions/transcript/A-B-roll/search/matching) until it's registered.

**Therefore the editor becomes the ingest point**, and *only proxies* travel:

1. **Probe** the file (AVFoundation), **checksum** it (**SHA-256, whole file**), record **volume UUID +
   path relative to the volume** (external drives remount at different paths).
2. **Generate proxies locally** with the hardware encoders (M1 Max has H.264/HEVC + ProRes engines):
   `preview_proxy` 720p (editing), `vlm_proxy` 480p/5 fps (analysis), **audio 16 kHz mono WAV**.
   **Compute the SHA-256 in the same read pass** — the bytes are already streaming through, so
   whole-file hashing is effectively free.
3. **Register with NUEDIT** and upload **only `vlm_proxy` + audio** (~0.4–0.9 GB per TB of raw, a
   ~1000× reduction). **Never upload the original.** The tower then runs its whole pipeline on proxies.
4. **Originals stay on the external drive, referenced in place** — never copied, never moved.

Design rules:
- **Non-blocking.** The drop completes and the clip is immediately editable; probe/transcode/upload run
  in the background with per-asset state in the media panel (queued → proxying → uploading →
  analysed / failed) as a badge, not a modal.
- **Offline is normal.** The external drive is usually unplugged. A clip whose original is offline stays
  fully visible and **editable via its proxy**; only conform/export needs the volume, and should name
  exactly which volumes to mount.
- **Store identity on the manifest entry:** `footage_id` + `checksum` + which tier is in use, so relink
  is by content (not path), re-imports dedupe, and the project opens on any machine.
- **Proxy cache on the internal disk** (default) so editing survives an unplug; honour a disk budget
  with LRU eviction + pin/unpin. Evicting must remove *bytes*, never clips.
- **Backend unreachable:** degrade silently to local-only import and retry later — never lose the clip.
- **Don't duplicate the pull path:** media NUEDIT already owns still arrives via `import_media`
  (url/path) on a tower-side push.

Full design + data model: NUEDIT repo `docs/superpowers/specs/2026-07-25-media-management-design.md`
(rev 2). Tower builds identity/locator + the edge-ingest API first (steps 1–2); this editor work is
step 3.

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
