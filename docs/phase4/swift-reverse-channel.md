# Phase 4 (Swift) — Reverse channel: NUEditor → NUEDIT

> **STATUS (2026-07-25): partially READY — start with Edge ingest.**
>
> - ✅ **READY NOW — Edge ingest.** The tower endpoint exists, is tested, and is authenticated:
>   `POST /api/v1/projects/{project_id}/footage/edge-register` (contract below). Build this first;
>   it is the primary ingest path and unblocks everything else NUEDIT knows about your media.
> - ✅ Also ready: `search`, `scripts/*`, `timelines/{id}/assemble`, `footage` list/status.
> - ✅ **READY — generation + gaps.** The `/api/v1` routes now exist (see "Generation & gaps"
>   below): submit video/image/music/voice-over, poll jobs, analyze a timeline's coverage gaps,
>   and fill them. Backed by the same service core as the MCP tools, so behaviour matches.
> - Prereqs done: debrand ✅, NUEDIT MCP server ✅ (8 tools), media identity/locator ✅.

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
(rev 2). Tower steps 1–2 (identity/locator + edge-ingest API) are **done**; this editor work is step 3.

### Endpoint contract — `POST /api/v1/projects/{project_id}/footage/edge-register`

**Auth** (router-level, verified): `Authorization: Bearer <jwt>` — preferred for this client — or the
`nuedit_session` cookie. Requests are tenant-scoped by `project_id`, so the token's org must own it.

**Body:** `multipart/form-data`

| Part | Kind | Required | Notes |
|---|---|---|---|
| `metadata` | form field, JSON string | ✅ | see below |
| `vlm_proxy` | file | ✅¹ | 480p / 5 fps H.264 — what the VLM analyses |
| `audio` | file | ✅¹ | **16 kHz mono WAV, whisper-ready** — stored as the *cleaned* audio and consumed by transcription **and ASD** |
| `preview_proxy` | file | optional | 720p; only for the tower's web review UI — normally keep it local |
| `thumbnail` | file | optional | jpg |

¹ At least one of `vlm_proxy` / `audio` must be present (400 otherwise). **Never send the camera original.**

`metadata` JSON (`EdgeIngestMeta`):

```json
{
  "filename": "A001.mov",              // required
  "duration_ms": 23530,                // required
  "checksum": "<sha256 hex>",          // required, non-empty -> 400 if missing/blank
  "checksum_algo": "sha256",           // default "sha256"
  "codec": "hevc",                     // optional probe fields
  "frame_rate": 25.0,
  "resolution_width": 3840,
  "resolution_height": 2160,
  "file_size_bytes": 12000000000,      // size of the ORIGINAL (which is never uploaded)
  "has_audio": true,
  "volume_uuid": "AAAA-BBBB",          // the external drive's UUID, NOT its mount point
  "volume_label": "SHOOT_A",
  "volume_relative_path": "day1/A001.mov",   // path relative to the volume root
  "mount_point": "/Volumes/SHOOT_A"    // advisory / last-seen only
}
```

**Responses**

| Code | Body | Meaning |
|---|---|---|
| `202` | `{"id","status":"accepted","filename","derivatives":["audio","vlm_proxy"]}` | registered; analysis runs in the background |
| `202` | `{"id","status":"duplicate","filename"}` | this `(project, checksum)` already exists — **reuse that `id`**, nothing re-analysed. Note it is **202, not 409** |
| `400` | `{"detail": …}` | unparseable `metadata`, blank `checksum`, or no derivative sent |
| `401` | — | missing/invalid token |

**Client rules**
- **Send `volume_uuid` + `volume_relative_path`.** That's what lets the tower record the original as
  `volume://<uuid>/<rel>` and resolve it wherever the drive remounts. Without them the original has no
  recorded location (registration still succeeds).
- **Persist the returned `id` (NUEDIT `footage_id`) + your `checksum` on the `MediaManifestEntry`** —
  that's the join key for search/roll-review/matching later, and it makes re-imports idempotent.
- Treat `duplicate` as success: adopt the returned `id`, skip re-uploading.
- Poll `GET /api/v1/projects/{project_id}/footage/{id}/status` (or the `footage_webhooks` feed) for
  pipeline progress; the tower emits an `uploaded` event immediately, then transcript/chunks events.
- The original is registered **offline** until a drive is mounted — expected, not an error.

## Generation & gaps — endpoint contract

Same auth as above (`Authorization: Bearer <jwt>`, tenant-scoped). Generation is slow, so every
submit returns a **job** you poll; the client never blocks on it.

| Method + path | Body / query | Returns |
|---|---|---|
| `POST /api/v1/projects/{project_id}/generation/{capability}` | `{"prompt": …, "duration_s"?, "aspect_ratio"?, "model"?, "voice"?, "ref_image_assets"?}` — `capability` ∈ `video`\|`image`\|`music`\|`voiceover` (for `voiceover`, `prompt` is the text to speak) | `202 {job_id, capability, status, backend, model, asset_uri, error}` |
| `GET /api/v1/generation/jobs/{job_id}` | — | `200` same job shape; **when `status == "ready"`, `asset_uri` is importable** |
| `GET /api/v1/projects/{project_id}/generation/jobs?limit=50` | — | `200 [job, …]` newest first (adds `prompt`, `section_id`) |
| `POST /api/v1/timelines/{timeline_id}/analyze-gaps?use_llm=false` | — | `200 {timeline_id, count, briefs:[{capability, prompt, section_id, section_name, duration_s, aspect_ratio, reason, source}]}` |
| `POST /api/v1/timelines/{timeline_id}/fill-gaps?use_llm=false` | optional `{"capabilities": ["video"]}` | `202 {gaps, submitted, jobs:[…]}` — one generation per gap |
| `GET /api/v1/timelines/{timeline_id}/gap-jobs` | — | `200 {timeline_id, jobs:[{job_id, capability, status, section_id, asset_uri, error}]}` |

Notes:
- `status` ∈ `pending` \| `running` \| `ready` \| `failed`. Poll until terminal; don't assume timing.
- `analyze-gaps` always runs the **marker stream** (MISSING / LOW_CONFIDENCE); `use_llm=true` adds
  the Bedrock stream that proposes holistic gaps (establishing shots, transitions, music/VO).
  `brief.source` tells you which produced it (`marker` \| `llm`).
- Which backend runs a capability (tower GPU / Modal / fal) is **NUEDIT config, not a client
  concern** — don't surface or select backends in the UI.
- A capability whose backend isn't configured fails that gap only: `fill-gaps` reports it in
  `jobs[].error` and still submits the rest. Show partial success.
- `400` = unknown capability or bad body; `404` = job/timeline not yours (never `403`).
- **Place a ready asset with the editor's existing `import_media` + `add_clips`** — don't build a
  second import path. For gap fills, the brief's `section_id` says which gap it belongs to.

## Archive originals to S3 (background, client-driven)

The external drive is usually the **only** full-res copy. Archiving fixes that, and because the
originals are here while the S3 credentials are on the tower, **the Mac uploads directly to S3** —
the raw never passes through the tower.

    GET  /api/v1/projects/{id}/archive/candidates   -> [{footage_id, filename, checksum,
                                                        file_size_bytes, original_uri}]
    POST /api/v1/footage/{footage_id}/archive/presign?expires_in=3600
                                                    -> {url, key, expires_in, checksum}
    PUT  <url>                                      (direct to S3, body = the original file)
    POST /api/v1/footage/{footage_id}/archive/complete   body {"key": "<key>"} -> {archived, uri}
    GET  /api/v1/projects/{id}/archive/status       -> {total, by_status, fully_archived}
    POST /api/v1/projects/{id}/archive/settings     body {"enabled": false}   per-project opt-out

Rules:
- **Strictly background and interruptible.** Only run when the volume is mounted and the machine is
  idle/on a good link; never block an edit, an import, or an export on it.
- `original_uri` is `volume://<uuid>/<rel>` — resolve it against the mounted volume to find the file.
- Archiving is **on by default**; respect the per-project opt-out and expose it in project settings.
- `complete` verifies the object's size against what you reported at ingest, so a truncated upload
  comes back `archived: false` — retry it; a failed item reappears in `candidates`.
- Footage with no checksum is never offered (an unverifiable copy is not a backup).
- Don't parallelise heavily: these are multi-GB objects on a drive you're also reading for playback.

## Other NUEDIT endpoints this consumes (tower `/api/v1`)

`search`, `scripts/*` (sections, `match`, `select`), `timelines/{id}/assemble`,
`footage` (list/status), and the edge-ingest endpoint contracted above.

## Constraints

- **Do not duplicate NUEDIT logic in Swift** — the editor is a thin client for these features.
- **Do not touch the MCP server / `Agent/Tools/*`** — that's the inbound (agent→editor) surface;
  this task is the outbound (editor→backend) surface, a separate client.
- Generated/returned assets flow through the normal media library (tag AI-generated where the
  backend marks them).

## Not this task

The **NUEDIT MCP server** (so Claude/Cursor can call NUEDIT's services) is **tower-side** — it is
not built here. Agents connect to it directly; this Swift client is only for the editor app itself.
