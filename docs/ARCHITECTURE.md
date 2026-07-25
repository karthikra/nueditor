# NUEDIT + NUEditor — System Architecture

One product, two parts, two machines:
- **NUEDIT** — the backend *brain*. Python/FastAPI on the Linux GPU tower. Understands footage and
  the script; decides the edit.
- **NUEditor** — the *hands and face* (this repo). Swift/macOS native editor. Renders the edit as a
  real, human-editable timeline; handles polish, generation UX, and export.

NUEDIT drives NUEditor over NUEditor's **MCP server**. NUEditor never depends on NUEDIT to run as a
plain editor; NUEDIT adds the intelligence NUEditor lacks (A-roll/B-roll, script, auto-assembly).

## Topology — what runs where

```
  LINUX GPU TOWER (100.96.118.41, 2× RTX 3090)          APPLE-SILICON MAC (100.88.194.45, macOS 26)
  ┌──────────────────────────────────────────┐         ┌────────────────────────────────────────┐
  │ NUEDIT — FastAPI :8000 (GPU 1)             │         │ NUEditor.app (Swift + Metal)             │
  │  ingest · VLM caption · transcript ·       │  MCP    │  timeline engine · compositing · render  │
  │  search · A/B-roll (Light-ASD) · script    │ (HTTP   │  transcript/caption edit · color/effects │
  │  match · B-roll assoc · assemble_timeline  │ JSON-   │  export (fcpxml/xml/nueditor)             │
  │  Web UI (HTMX) · /api/v1 (JWT, tenant)     │ RPC)    │  MCP server :19789  ◄────────────────────┤ drives
  │  Postgres (docker) · Alembic               │◄───────▶│  on-device: MLX, transcription, search   │
  │  MCP client → NUEditor (services/palmier)  │  via    │                                          │
  └───────┬───────────────┬──────────────┬─────┘  SSH    └────────────────────┬─────────────────────┘
          │               │              │      tunnel                        │
   captioner :8001   S3 nuedit-media   Bedrock / fal.ai / Modal        (Tailscale mesh + SSH -L
   (VLM, shared        (footage +      (LLM reasoning /                 19789: tower localhost →
    with NUVault)       proxies)        generation compute)             Mac loopback)
```

- **Tower** runs the whole NUEDIT service, Postgres, and the in-process ML (BGE embedder + MiniLM
  cross-encoder + Light-ASD on GPU 1). The **VLM captioner** (`:8001`) is a separate service on the
  tower, **shared with NUVault** — don't restart casually.
- **S3** (`nuedit-media`) holds footage originals + proxies (`STORAGE_BACKEND=s3`).
- **External compute**: AWS **Bedrock** (Claude, `ap-south-2`) for heavy reasoning; **fal.ai** /
  **Modal** for generation. All called from the tower.
- **Mac** runs NUEditor + its MCP server on loopback `:19789`, plus on-device MLX/transcription/search.
- **Network**: Tailscale mesh. NUEDIT reaches NUEditor's loopback MCP via an **SSH local-forward**
  (`ssh -N -L 19789:localhost:19789 karthikramesh@100.88.194.45`), so the tower talks to
  `127.0.0.1:19789`.

## Capability matrix

Status: ✅ works now · 🔧 to build.

| Capability | Runs where | Owner | Status |
|---|---|---|---|
| Footage ingest, proxy gen, S3 storage | Tower | NUEDIT | ✅ |
| VLM captioning (shot description) | Tower `:8001` | NUEDIT | ✅ |
| Transcript (batch, faster-whisper) | Tower | NUEDIT | ✅ |
| Semantic search (BGE + cross-encoder) | Tower | NUEDIT | ✅ |
| A-roll/B-roll classify (rules + **Light-ASD**) | Tower (GPU) | NUEDIT | ✅ (activated) |
| Script → section matching | Tower | NUEDIT | ✅ |
| B-roll association → sections | Tower | NUEDIT | ✅ |
| Timeline assembly (V1 A-roll / V2 B-roll, markers) | Tower | NUEDIT | ✅ |
| Web review UI (HTMX; B-roll tray, roll override) | Tower | NUEDIT | ✅ |
| FCPXML export (Resolve/FCP, Phase-10 adapter) | Tower | NUEDIT | ✅ |
| Native timeline engine, compositing, render | Mac | NUEditor | ✅ |
| Clip ops (add/insert/move/split/ripple), multicam | Mac | NUEditor | ✅ |
| Transcript/caption editing, word-level cuts | Mac | NUEditor | ✅ |
| Color grade, effects, transforms, keyframes | Mac | NUEditor | ✅ |
| Export (video H.264/265/ProRes, xml, fcpxml, **nueditor**) | Mac | NUEditor | ✅ (mode renamed from `palmier`) |
| **MCP server** (~20 tools) | Mac `:19789` | NUEditor | ✅ |
| On-device transcription + search (siglip2) | Mac | NUEditor | ✅ (model URL still upstream — mirror pending) |
| Login / accounts (Clerk) | — | — | ✅ removed → local-only, no login |
| Cloud backend + cloud transcription (Convex) | — | — | ✅ removed |
| In-app hosted agent chat | Mac | NUEditor | ✅ now runs on the user's own Anthropic key |
| Closed generation (Seedance/Kling via Convex) | — | — | ✅ removed → NUEDIT owns (Phase 3) |
| Telemetry (Sentry/PostHog), auto-update (Sparkle) | — | — | ✅ removed → no external calls |
| **NUEDIT → NUEditor MCP client** (push assembly) | Tower | NUEDIT | 🔧 Phase 2 |
| ms ↔ frame mapping, footage↔mediaRef map | Tower | NUEDIT | 🔧 Phase 2 |
| **Owned generation** (fal/Modal/nano-banana → import_media) | Tower | NUEDIT | 🔧 Phase 3 |
| **Script-gap fill** (MISSING markers → generate → place) | Tower | NUEDIT | 🔧 Phase 3 |
| Scriptmaker panel | Mac (drives NUEDIT) | both | 🔧 Phase 4 |
| Local LLM: on-device MLX + tower/Bedrock | Mac + Tower | both | 🔧 Phase 4 |
| Video-generator UI, in-editor B-roll review | Mac | NUEditor | 🔧 Phase 4 |

## End-to-end flow (target state)

```
footage → [NUEDIT tower] ingest → caption → transcript → search index
                         → A/B-roll classify (Light-ASD) → script match → B-roll associate
                         → assemble_timeline  ⇒  V1 A-roll clips, V2 B-roll, MISSING markers
   ── MCP push (Phase 2) ──▶ [NUEditor Mac] import_media(footage) + create_timeline + add_clips
   MISSING markers ⇒ [NUEDIT] generate (fal/Modal) → import_media → add_clips into gap  (Phase 3)
                              [NUEditor] human reviews/edits · color · captions · export (fcpxml/video)
```

## What's to be built (see `docs/NUEDIT_ROADMAP.md`)

1. **Debrand** (Mac) — ✅ **done**. Clerk/Convex/telemetry/Sparkle removed, renamed → NUEditor
   (`com.veeville.nueditor`), local-only. `docs/debrand/`. Two upstream ties remain: the siglip2
   model URL and the skills catalog repo.
2. **Phase 2 — MCP integration** (Tower) — ✅ **steps 1–3 done** (backend `fb460cf`):
   `core/nueditor_map.py` (pure ms↔frame), `infrastructure/external/nueditor_client.py` (MCP
   client), `core/nueditor_push.py` (push V1/V2), `scripts/nueditor_push.py`. Step 4 = live push
   once NUEditor runs. Spec: NUEDIT repo `docs/superpowers/specs/2026-07-24-nueditor-mcp-integration-design.md`.
3. **Phase 3 — generation layer + gap analysis** (Tower) — a **backend-flexible** generation layer
   (tower · Modal · fal, per-capability) for **video · image · music · voice-over**, plus **video
   gap analysis** (`MISSING`/`LOW_CONFIDENCE` → generation briefs) → generate → `import_media` →
   fill the gap. Spec: NUEDIT repo `docs/superpowers/specs/2026-07-24-generation-layer-design.md`.
   Also: rehost/replace the siglip2 search model.
4. **Phase 4 — reverse channel + native features** (Mac + Tower) — **NUEDIT MCP server** (agents
   drive NUEDIT's services); **Swift REST client** to NUEDIT `/api/v1` (editor → backend);
   scriptmaker panel, generation UI, local LLM (MLX + Bedrock), in-editor B-roll review. Swift task:
   `docs/phase4/swift-reverse-channel.md`.

## Connection model (two directions, two protocols)

REST is the scalable backbone; MCP is the agent-facing adapter over the same service core.

- **NUEDIT → NUEditor (drive the editor):** NUEDIT is an MCP *client* of NUEditor's MCP server
  (`:19789`, loopback → SSH-forwarded from the tower). One-way control (create timeline, import,
  add_clips). Built (Phase 2).
- **NUEditor → NUEDIT (editor uses backend intelligence/generation):** the Mac calls NUEDIT's
  **REST `/api/v1`** (JWT, tenant-scoped) directly over Tailscale — *no tunnel* (FastAPI binds
  `0.0.0.0:8000`). Async work returns `{jobId}` + webhook/poll. Scales (stateless, LB-able). To build
  (Phase 4).
- **Agents (Claude/Cursor) get both:** connect to NUEditor's MCP (edit) **and** a **NUEDIT MCP
  server** (a thin facade over the REST service core — search/match/assemble/classify/generate/
  analyze_gaps). To build (Phase 4).
- **Media bytes** move over HTTP (`import_media` url mode) or a shared path — not MCP.

### Storage model — the two sides share NO database

- **NUEditor** has **no database** (no SQLite/CoreData/SwiftData). A project is a **package** with
  **JSON** inside — `MediaManifest` (v2: entries + folders), timeline data, generation log — and media
  is **referenced in place**, not copied. Derived caches are plain files under
  `~/Library/Application Support/com.veeville.nueditor/` (`Embeddings/*.embed`, `Transcripts/`).
- **NUEDIT** owns **PostgreSQL 16** (`pgvector/pgvector:pg16`, async SQLAlchemy + Alembic):
  `footage_files` → `video_chunks` → `chunk_descriptions`/`transcripts`/roll signals, plus scripts,
  timelines, `section_broll`, `roll_labels`, `gen_jobs`. Bytes in S3 (`nuedit-media`) + local proxies;
  vectors in ChromaDB (pgvector available).
- **Consequence:** footage dragged straight into NUEditor is invisible to NUEDIT — no captions,
  transcript, A/B-roll classification, search, or script matching. Intelligence requires NUEDIT
  ingest. Closing that gap is the **drag-to-ingest** item in `docs/phase4/swift-reverse-channel.md`.

## Boundaries / invariants

- **NUEDIT → NUEditor coupling is MCP only.** NUEDIT never reaches into NUEditor's internals; it
  calls MCP tools. Port `19789` is fixed; the MCP server / `Agent/Tools/*` are off-limits to debrand.
- **NUEditor → NUEDIT coupling is REST (app) / MCP-facade (agents).** Never the reverse of the above.
- **NUEDIT owns intelligence + generation; NUEditor owns editing + render + export.** Build each
  capability in exactly one place.
- **Units:** NUEDIT ms ↔ NUEditor project frames (`round(ms/1000*fps)`).

## Contract changes NUEDIT must absorb (from the debrand)

The MCP port, tool names and schemas are otherwise unchanged. These are not:

- **`export_project` mode `palmier` → `nueditor`.** The enum value and the project package
  extension both changed; `.palmier` packages no longer open. Any tower-side call passing
  `mode: "palmier"` will now fail validation.
- **MCP server identity is `nueditor`** (was `palmier-pro`), and the Claude Desktop connector
  ships as `nueditor.mcpb`. Resource URIs are `nueditor://models/*`.
- **`canGenerate` is permanently false** until Phase 3 — generation and upscale tools reject.
  Tool descriptions no longer tell the user to sign in; they report the capability as unavailable.
- **`send_feedback` returns a terminal error** — there is no report sink. It validates and logs
  locally rather than returning a success receipt.
