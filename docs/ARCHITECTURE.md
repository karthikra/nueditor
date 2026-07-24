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
  │  match · B-roll assoc · assemble_timeline  │ JSON-   │  export (fcpxml/xml/palmier)             │
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

Status: ✅ works now · 🔧 to build · ⚠️ present upstream, being removed in debrand.

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
| Export (video H.264/265/ProRes, xml, fcpxml, palmier) | Mac | NUEditor | ✅ |
| **MCP server** (~20 tools) | Mac `:19789` | NUEditor | ✅ |
| On-device transcription + search (siglip2) | Mac | NUEditor | ✅ (search model URL → decision) |
| Login / accounts (Clerk) | (hosted) | — | ⚠️ removing → local-only |
| Cloud backend + cloud transcription (Convex) | (hosted) | — | ⚠️ removing |
| In-app hosted agent chat | (hosted) | — | ⚠️ off; revisit local |
| Closed generation (Seedance/Kling via Convex) | (hosted) | — | ⚠️ removing → NUEDIT owns |
| Telemetry (Sentry/PostHog), auto-update (Sparkle) | Mac | — | ⚠️ removing |
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

1. **Debrand** (Mac, in progress) — remove Clerk/Convex/telemetry/Sparkle, rename → NUEditor,
   local-only. `docs/debrand/`.
2. **Phase 2 — MCP integration** (Tower) — `app/services/palmier.py` (MCP client),
   `app/core/palmier_map.py` (pure ms↔frame), push a real assembled timeline into NUEditor, read
   back. Spec: NUEDIT repo `docs/superpowers/specs/2026-07-24-palmier-mcp-integration-design.md`.
3. **Phase 3 — owned generation + gap-fill** (Tower) — generate on our stack → `import_media`;
   fill script-coverage gaps from `MISSING` markers. Also: rehost/replace the siglip2 search model.
4. **Phase 4 — native features** (Mac + Tower) — scriptmaker panel, local LLM (MLX + Bedrock),
   video-generator UI, in-editor B-roll review/override.

## Boundaries / invariants

- **MCP is the only coupling.** NUEDIT never reaches into NUEditor's internals; it calls MCP tools.
  MCP port `19789` is fixed. Debrand must not touch the MCP server or `Agent/Tools/*`.
- **NUEDIT owns intelligence + generation; NUEditor owns editing + render + export.** Build each
  capability in exactly one place.
- **Units:** NUEDIT ms ↔ NUEditor project frames (`round(ms/1000*fps)`).
