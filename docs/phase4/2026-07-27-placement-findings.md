# NUEditor (Mac) — placement findings, 2026-07-27

**Reply to `2026-07-27-placement-handoff.md`.**
**Method:** every answer below was produced by driving the *live* MCP server on the Mac (not by
reading source), in a scratch project built for the purpose. Where I could not produce the exact
condition, I say **unknown** rather than guess.

**Headline:** no Swift was needed — the placement path is fully expressible with today's tools.
Two of your client assumptions need correcting (both make your job easier), one is a genuine
constraint to design around (integer-only timeline fps over MCP), and your §5 blocker can be
**skipped entirely** by using `bytes` import for the 3.7 MB fill.

---

## 1. MCP URL to use (Task 1)

The server binds **`127.0.0.1:19789` only** (verified with `lsof`: `TCP 127.0.0.1:19789 (LISTEN)`,
IPv4 loopback). It also runs a localhost **Origin** validator. Empirically:

- `POST http://127.0.0.1:19789/mcp` (initialize) → **HTTP 200**, no `Origin` header required.
- `POST http://100.88.194.45:19789/mcp` (the Mac's Tailscale IP) → **connection refused** (HTTP 000).

So the tower **cannot** reach it directly over the tailnet. This is deliberate (an unauthenticated
MCP server should not be on a network interface), so I did **not** change the binding.

**Use the SSH local-forward** that `ARCHITECTURE.md` already documents, and point at the forwarded
loopback on the tower side:

```
ssh -N -L 19789:localhost:19789 karthikramesh@100.88.194.45   # macbook-pro.tail375484.ts.net
NUEDITOR_MCP_URL = http://127.0.0.1:19789/mcp
```

Path is `/mcp` (also `/`); protocol version header `MCP-Protocol-Version: 2025-06-18` is accepted.
If you decide you want a direct tailnet bind instead of the forward, that's a one-line change on my
side (`requiredLocalEndpoint` in `MCPHTTPServer.swift`) **plus** relaxing the Origin validator —
but it exposes an unauthenticated editor to the whole tailnet, so it's your call to make explicitly,
not mine to make silently.

---

## 2. Real tool schemas (Task 2) — corrections called out

Read live via `tools/list`. 46 tools total. The six you asked about:

### `import_media` — your assumption is right, plus a shortcut
`{ source: {url|path|bytes|matte}, name?, folder? }` — exactly one of the four source kinds.
- `url`: **HTTPS only** (see §4 q9). "Pre-signed URLs fine but must not expire mid-download."
- `path`: absolute path readable by the NUEditor process (referenced in place).
- `bytes`: base64; `mimeType` **required** with it. Schema says "prefer url/path over ~10 MB" —
  i.e. **≤10 MB is fine as bytes**. Your 3.7 MB fill qualifies (tested, §4 q9).
- `matte`: generates a solid-colour PNG; not relevant to fills.

Returns `{"mediaRef","name","status","type"}`. For `path`/`bytes` the import is **synchronous** —
`status:"ready"` in the same response. Your "url imports are async, finished when `get_media` stops
reporting `generationStatus`" holds for `url`; poll `get_media {ids:[…]}` or `{pending:true}`.
**Correction:** the field is `mediaRef` (not a `status`-first shape); status rides alongside.

### `add_clips` — two things your client doesn't know
`{ entries: [ { mediaRef*, startFrame*, trackIndex?, endFrame?, source? } ] }` (`*` required).
- `mediaRef` + `startFrame` are the only required fields.
- **`trackIndex` is OPTIONAL and 0-based.** Omit it on every entry → NUEditor auto-creates one
  shared track per asset zone (video/audio). **Correction / gotcha:** a freshly created timeline has
  **zero tracks**, so passing `trackIndex:0` into an empty timeline **fails** with
  `entries[0]: track index 0 out of range (0..-1)`. Either omit `trackIndex`, or `manage_tracks`
  first. Do not assume track 0 exists.
- **`endFrame` exists and is what you want for gap-fill** (your client didn't mention it). It makes
  the clip occupy timeline frames **[startFrame, endFrame)** exactly — "a gap from `get_timeline`
  copies straight in." Mutually exclusive with `source`.
- `source: [startSeconds, endSeconds]` — a span of the asset **in seconds** (confirmed real, §4 q3).
  Omit both `source` and `endFrame` for the whole asset.

Returns `{ "clips":[{ "frames":[s,e], "id", "mediaRef", "track", "trimStartFrame"?, "trimEndFrame"? }],
"createdTracks":[{ "index","label","type" }] }`. Note the response reports placement as
`frames:[s,e]`, and any auto-created tracks.

### `get_timeline`
`{ startFrame?, endFrame?, captionDetail? }` — all optional (windowing). Returns project + timeline:
`{ id (timelineId), fps, width, height, totalFrames, durationSeconds, currentFrame, canGenerate,
tracks:[{ index, trackId, type, clips:[{ id, mediaRef, frames:[s,e], track, trim* , … }], gaps:[[s,e],…] }] }`.
**Units:** every frame field is **project frames**; `frames`/`gaps` are `[start, end)` end-exclusive;
`durationSeconds` is seconds. Empty gaps key ⇒ contiguous track.

### `create_timeline`
`{ from?, name? }` — **no fps/resolution parameters.** A new timeline inherits project settings;
resolution/fps are project-level (`set_project_settings` / `manage_project create`). See §4 q1 — fps
is integer-only through these.

### `remove_clips`
`{ clipIds: [string]* }`. Atomic. **Note:** removing the last clip(s) on a track can remove the
track, dropping you back to the empty-timeline / `trackIndex out of range` state above.

### `get_media`
`{ ids?, folder?, pending? }` all optional. Returns
`{ assets:[{ id, name, type, width, height, fps, durationSeconds, generationStatus? }], timelines:[…] }`.
`pending:true` or `ids:[…]` is the cheap poll for an async (url) import.

---

## 3. Scratch test project

Live now, addressable over the forwarded MCP:

| | |
|---|---|
| Project name | `NUEDIT Placement Test` |
| Project id | `E24260C8-A2E7-41AA-8802-8C47BEF2E10E` |
| Path | `/Users/karthikramesh/Documents/NUEditor/NUEDIT Placement Test.nueditor` |
| Timeline id | `AAFE28E4` (active) |
| fps / resolution | **24** (integer — see q1) / 3840×2160 |
| Track | index `0`, `trackId 431604BE`, type `video` |
| Clips | `78219FF1` frames `[0,100)`, `BF64DB16` frames `[200,300)` |
| **Hole** | **`[100, 200)` — 100 frames** (matches your conformed fill's length exactly) |
| totalFrames | 300 |
| Imported media you can place | `17E3FC75` (A-roll 4K 23.976), `755E7A29` (fill 1904×1072, 100f) |

Caveats: `trackId` is **not stable** across track deletion (it changed when I cleared/rebuilt the
track — address tracks by `index` for automation, not `trackId`). fps is 24, not 23.976 — I could
not set 23.976 via MCP (q1).

---

## 4. Answers to §4

**1. Frame rate on import.** `get_media` reports the asset's fps as a **rounded 3-decimal value**
(`23.976`) — not the rational, not resampled: the asset keeps its own rate. **But** the *timeline*
fps set via MCP is **integer-only**: `manage_project create {fps}` and `set_project_settings {fps}`
both type `fps` as integer, and `set_project_settings {fps:23.976}` is **rejected**
(`The given data was not valid JSON`). So my MCP-created timeline is **24**, with a 23.976 asset
sitting inside it. **Consequence for you:** you cannot create/repair a 23.976 timeline over MCP —
that's an in-app-only setting. Your real target ("Levis Cut v1") already *is* 23.976 (made in-app),
so placement is unaffected, **but I could not confirm what `get_timeline` reports for its fps** — 24
(rounded, like `get_media` would if forced to int) or 23.976. **This decides whether your
`ms_to_frame` uses the right divisor. Read your real timeline via `get_timeline` once the forward is
up and check the `fps` field before trusting it — this is the one thing I'd verify first.** (Reported
**unknown**; I have no in-app-made 23.976 timeline to inspect.)

**2. `startFrame` origin.** Frame **0 is the first timeline frame**; `startFrame` is **inclusive**;
clips occupy **[start, end)**, end-exclusive. A clip at 100 running 100 frames = `[100,200)`; the next
clip **butts at 200, not 201**. Verified: two clips at `[0,100)` and `[200,300)` leave `gaps [[100,200]]`.

**3. `source` units.** Confirmed **seconds**, and mixing seconds-`source` with frames-`startFrame` in
one entry is intended. `source:[1.0,3.0]` on the 23.976 asset produced a clip of **48 frames**
(`trimStartFrame 24`, i.e. 1.0 s×24; span 2.0 s ≈ 48 f). Omitting both `source` and `endFrame` places
the **whole asset** (120-frame A-roll → `[700,820)`). Passing **both** is rejected:
`set source OR endFrame, not both`. **For gap-fill prefer `endFrame`** — it's frame-exact and needs no
seconds↔frames conversion.

**4. Mismatched resolution — no upscale needed.** The 1904×1072 fill placed in the 3840×2160 project
is **scaled up to fill the frame, edge-to-edge — no pillarbox, no black bars, not left small.**
Verified by capturing the composite at the fill's frame (`capture_frame {timelineFrame}`) and looking
at the pixels: the pattern fills the whole 4K canvas. **Your no-upscale policy holds** (both are 16:9,
so fill = no bars). The only cost is that **NUEditor performs the upscale itself** (1904→3840, so the
insert is softened); if you want crisp inserts, upscale on the tower — but that's a quality choice,
not a letterbox risk. (If a fill's aspect ever differs from the project, retest — this answer is for
matching aspect.)

**5. Duration mismatch.**
- **Media longer than the window:** trimmed to fit, no error. Fill (100 f) into `[300,360)` → occupies
  `[300,360)` with `trimEndFrame 40`.
- **Media shorter than the `endFrame` window:** **rejected** —
  `entries[0]: endFrame spans 120 frames but the source is only 100.`
- So your "hole 101, media 100" case: `endFrame:101` **errors**. Options: place 100 frames (leave a
  1-frame gap), or conform the media to ≥101. There is no auto-extend. **Conform the fill to be ≥ the
  gap width** (you already do — exact-100 into a 100-hole placed perfectly, gap closed).

**6. Overlap.** Placing over an existing clip is **overwrite**, not reject and not ripple. New clip at
`[50,150)` over an existing `[0,100)`: the old clip trimmed to `[0,50)`, new clip `[50,150)`, the next
neighbour trimmed on its left — **total timeline length unchanged**. There is **no "fail if occupied"
guard**, so read `get_timeline.gaps` and target a gap's `[start,end)` explicitly; otherwise you will
silently overwrite. Placing "into a gap specifically" = `startFrame`/`endFrame` equal to the gap.

**7. Atomicity.** Confirmed. One bad entry rejects the **whole** call with no partial state: good entry
`[400,450)` + bad `[-5,40)` → `isError`, and the good clip did **not** appear. **Error shape is
parseable:** `entries[<index>]: <message>` — e.g. `entries[1]: startFrame must be >= 0 (got -5)`.
Other messages seen: `track index N out of range (0..M)`, `endFrame spans N frames but the source is
only M`, `set source OR endFrame, not both`. All follow the `entries[i]: …` prefix.

**8. Provenance — no mechanism.** None of the 46 tools is a marker/note/tag/annotation/label tool, and
`set_clip_properties` carries only visual/timing fields (opacity, transform, trims, fades, speed,
volume, blendMode, edge*) — no metadata/note field. **There is no way over MCP to mark a clip or the
timeline as AI-generated.** Handle provenance on your side. The only weak lever here is the media
asset's **`name`** (settable at `import_media`), which shows in the library — e.g.
`name:"AI B-roll — gap @100"` — but that's a convention, not a marker, and doesn't travel onto the
timeline clip. If you want real on-timeline provenance, that's the one place I'd add Swift — say the
word and I'll propose a `marker`/clip-note surface.

**9. Remote URL import — HTTPS required; but use bytes.** Plain **HTTP is rejected**:
`source.url must use https`. **Self-signed TLS: unknown** (I didn't stand up an HTTPS server to test
cert validation). **However — `bytes` mode works and sidesteps §5 entirely:** I imported the 3.6 MB
fill as base64 `bytes` with `mimeType:"video/mp4"` → `{mediaRef, status:"ready"}`. Since your conformed
fill is 3.7 MB (< the ~10 MB guidance), **send it as `bytes` and you don't need the media route, TLS,
or a cert at all.** If you later serve large originals by URL, it must be HTTPS with a cert NUEditor
trusts — Tailscale's MagicDNS HTTPS (real Let's Encrypt cert) would satisfy that; a self-signed cert
is the untested risk.

---

## 5. Swift changes

**None.** Everything the placement path needs already exists: `import_media` (`bytes` for ≤10 MB,
`url` for HTTPS), `add_clips` with frame-exact `endFrame` and atomic validation, `get_timeline` with
`gaps`. No tool was missing or unable to express placement, so per the handoff I wrote no code and
invented no commit. This findings doc + the filed handoff are the only additions.

The one thing that *would* be Swift, if you want it: on-timeline provenance (q8). Deferred to your call.

---

## 6. Things that surprised me / worth having

- **Integer-only timeline fps over MCP (q1)** is the sharpest gotcha and the one most likely to bite
  your frame math. Verify your real timeline's reported fps before trusting `ms_to_frame`'s divisor.
- **`endFrame` is the clean gap-fill primitive** — you don't need the seconds↔frames conversion your
  client was written around; place `[gap.start, gap.end)` directly.
- **Overwrite-on-overlap with no guard (q6):** always target a real gap, or you'll trim live clips.
- **`bytes` beats the URL route (q9)** for your fill size — likely deletes your §5 task.
- **`trackId` isn't stable across track deletion (q3/§3):** automate against track **index**.
- **Empty timeline has no tracks:** omit `trackIndex` (auto-create) rather than assuming track 0.
- **`capture_frame` imports the composite as a new media asset** (returns a `mediaRef`, writes a PNG
  into the package) rather than returning bytes inline — handy for visual verification, but it does add
  a library asset each call.
