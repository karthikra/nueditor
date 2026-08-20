# Plan — Edge ingest (raw footage in, proxies out, the tower knows your media)

**Goal.** Make NUEditor the ingest point for raw footage. Raw lands here on the Mac (usually an
external drive), is huge, and must never cross the network — yet the tower needs to *know* about it
(caption, transcript, A/B-roll, search, assemble). On import: probe + checksum + generate proxies
locally, edit off the proxy, upload **only proxies** to the tower, keep the original referenced in
place. Non-blocking, offline-tolerant, content-addressed.

**Owner:** Editor (this repo) for ingest/proxy/upload; tower owns the endpoint (**built + tested**)
and analysis. **Roadmap slot:** Phase 4, reverse channel. **Design:**
`docs/phase4/swift-reverse-channel.md` §"Edge ingest"; tower spec (nuedit)
`docs/superpowers/specs/2026-07-25-media-management-design.md` (rev 2). Tower steps 1–2 done; this is
step 3.

---

## Two layers — what exists vs. this

**Basic import works today** — drag from Finder / file-pick / drag-to-timeline / `import_media path`;
the original is referenced in place and edited directly. Fine for normal files.

**Edge ingest is the intelligent superset:** you edit off a lightweight **proxy** (so huge originals
stay smooth and can go offline), and the footage is **registered with the tower** so the whole
intelligence stack lights up — without originals ever crossing the network.

## Reuse (grounded in the codebase — don't reinvent)

| Piece | Where | Role in ingest |
|---|---|---|
| Per-asset background state + panel badge | `MediaAsset.generationStatus` (`.preparing/…`) | mirror as `ingestStatus`: queued → proxying → uploading → analysed → failed |
| Manifest (files referenced in place) | `Models/MediaManifest`, `MediaResolver` | persist `footage_id` (NUEDIT) + `checksum` + active tier; relink lives here |
| **16 kHz mono WAV extraction** | `Transcription.extractAudioTrack` (`AVSampleRateKey: 16_000`) | *is exactly* the `audio` derivative the endpoint wants |
| Transcode / hardware H.264 | `Export/` (AVAssetWriter pipeline) | generate `preview_proxy` 720p + `vlm_proxy` 480p/5fps |
| Import entry points | `EditorViewModel.importFinderItems(ToTimeline)`, `import_media` | where ingest hooks in |
| Package-safe writes | `ProjectPackageCoordinator` | proxy/sidecar writes into the live package |

**Greenfield:** `NUEDITBackendClient` (the shared Phase-4 reverse-channel REST client) — needed here
first, reused by every other Phase-4 feature.

---

## Build (staged, each shippable)

### Stage 0 — `NUEDITBackendClient` (shared foundation)
`URLSession` async client to NUEDIT `/api/v1`: base URL + JWT in Settings, a connection-status
indicator, sync-JSON and async-`{jobId}` handling, one typed method per endpoint used. This is item 1
of the reverse-channel spec and the prerequisite for edge-register *and* search/scriptmaker/generation
later. **Ships:** the editor can talk to the tower; nothing user-visible yet, but everything else
builds on it.

### Stage 1 — Local ingest identity (no tower yet)
On import, in the background, off-main:
1. **Probe** (AVFoundation async): codec, fps, resolution, duration, has-audio.
2. **SHA-256 the whole file**, and record **volume UUID + path-relative-to-volume** (external drives
   remount at different mount points) + last-seen mount point.
3. **Reference the original in place**; persist identity on the `MediaManifestEntry`
   (`checksum`, `volume_uuid`, `volume_relative_path`, active tier).
4. Surface `ingestStatus` as a media-panel badge (mirror `generationStatus`).
The clip is **immediately editable** the instant it drops — probe/hash run behind it.
**Ships:** robust local import with content identity → re-imports dedupe by checksum, and the
foundation for relink-by-content.

### Stage 2 — Local proxies (edit off the proxy)
Generate locally with the hardware encoders, **hashing in the same read pass**:
- `preview_proxy` 720p H.264 — what you edit against;
- `vlm_proxy` 480p / 5 fps H.264 — for the tower's VLM;
- `audio` 16 kHz mono WAV — reuse `extractAudioTrack`.
Editing/preview resolve to `preview_proxy` when present (via `MediaResolver`); conform/export fall
back to the original. **Proxy cache on the internal disk** with a size budget + LRU eviction and
pin/unpin — **evicting removes bytes, never clips**. **Ships:** smooth editing of huge 4K/raw footage;
originals can be unplugged and you keep working off proxies.

### Stage 3 — Register with the tower (the payoff)
Via `NUEDITBackendClient`: `POST /api/v1/projects/{project_id}/footage/edge-register`,
`multipart/form-data` — `metadata` (the `EdgeIngestMeta` JSON: filename, duration_ms, checksum,
volume_uuid/relative_path, probe fields) + **`vlm_proxy` + `audio` only. Never the original.**
- Handle `202 accepted` (analysis runs) and `202 duplicate` (adopt the returned `id`, skip re-upload);
  `400` (bad metadata / no derivative), `401`.
- **Persist the returned `id` (NUEDIT `footage_id`) on the manifest** — the join key for
  search/roll-review/matching, and what makes re-imports idempotent.
- Poll `GET …/footage/{id}/status` for the pipeline (`uploaded` → transcript/chunks events).
- **Degrade silently** if the backend is unreachable: stay local-only, retry later, never lose the clip.
**Ships:** the tower *knows* your footage → captions, transcript, semantic search, A/B-roll
classification, script matching — the whole intelligence stack — with ~0.4–0.9 GB crossing per TB of
raw (a ~1000× reduction).

### Stage 4 — Content-addressed relink + offline UX
Relink is **by checksum, not path**, so a remounted drive re-binds automatically and the project opens
on any machine. A clip whose original is offline stays fully visible and **editable via its proxy**;
only conform/export needs the volume, and the UI **names exactly which volumes to mount**. **Ships:**
drives come and go gracefully; projects are portable.

### Stage 5 — Archive originals to S3 (the drive isn't the only copy)
Background, client-driven, interruptible: the **Mac uploads originals directly to S3** (raw never
transits the tower). `GET …/archive/candidates` → `POST …/archive/presign` → `PUT` to S3 →
`POST …/archive/complete` (size-verified). On by default, per-project opt-out, only checksummed
footage offered. Never blocks an edit/import/export; runs only when the volume is mounted and the
machine is idle. **Ships:** the external drive stops being the single point of failure.

---

## Correctness / edge cases (AGENTS.md)

- **All file I/O off-main**; probe/hash/transcode on background executors; the panel renders immutable
  snapshots. Ingest **never blocks** the drop — the clip is editable immediately.
- **Package safety:** proxy + sidecar writes route through `ProjectPackageCoordinator` (staged →
  atomic install); serialize against save/close/export.
- **Offline is normal:** original absent ⇒ edit off proxy; only conform/export require the volume.
- **Dedupe & idempotency:** re-importing the same bytes reuses the `footage_id` (checksum key);
  `202 duplicate` is success.
- **Integrity:** the whole-file SHA-256 is the identity; `archive/complete` size-check catches truncated
  uploads (re-offered in candidates).
- **Cache discipline:** LRU eviction frees bytes only; pins protect in-use proxies; a missing proxy
  re-generates on demand.
- **Don't duplicate the pull path:** media the tower already owns (generated fills, search results)
  still arrives via `import_media(url|bytes)` on a tower push — edge ingest is *only* for footage that
  originates here.
- **Cancellation/teardown:** cancel proxy/upload on close/quit without leaving half-written proxies.

## Why it's intelligent

1. **Only proxies cross the network** — ~1000× reduction; the camera original never leaves the drive.
2. **Content-addressed identity** — relink by checksum, dedupe re-imports, open on any machine.
3. **Reuse over reinvention** — the 16 kHz audio extractor, transcode pipeline, `generationStatus`
   state machine, manifest, and resolver already exist; ingest wires them together.
4. **Non-blocking** — the clip is editable the instant it drops; everything else is background.
5. **It's the feeder for the whole product** — nothing the tower does (caption/search/A-B-roll/assemble)
   works until footage is registered, and text-based editing rides the same proxy+transcript. Edge
   ingest is the on-ramp.

## Dependencies & estimate

Stage 0 (`NUEDITBackendClient`) is shared with every reverse-channel feature — build it once here.
The tower endpoint is **already built and tested**, so Stage 3 is client work, not a negotiation.
Bigger than text-based editing (a real pipeline + a network client), but the transcode, 16 kHz audio,
state-machine, and manifest pieces are reused, and Stages 1–3 deliver the core ("edit off proxies, the
tower knows your footage"); Stages 4–5 are portability and durability.
