# NUEditor (Mac) — placement handoff, 2026-07-27

**For: Claude Code running in the `nueditor` fork on the Mac.**
**From: NUEDIT on the tower, `main` @ `1b2b0f4`.**

Copy this into the fork as `docs/phase4/2026-07-27-placement-handoff.md` and work from there.

---

## Read this first: you probably write less Swift than you expect

The direction of control is **NUEDIT → NUEditor**. The tower is the MCP *client*; NUEditor
hosts the MCP *server* on `:19789`. Placing a clip on a timeline is therefore a **Python** call
on the tower (`add_clips`), not Swift code in the editor.

So this handoff is mostly **enablement and verification**. Your job is to get the MCP server
reachable and then tell me the *actual* tool schemas and behaviours, because the Python I write
next will be built directly against your answers. If verification turns up a genuine gap in
NUEditor's tool surface, that is Swift work and you should do it — but do not go looking for
Swift to write. An accurate report is the deliverable.

There is one thing I know is missing on **my** side, listed in §5. Don't try to fix it from
your end.

---

## 1. What is ready on the tower

Generated B-roll fill now runs end to end and stops one step short of your door:

```
gap → measure the look off neighbouring clips → generate candidate stills locally (free)
    → auto-pick the closest match → animate it into a clip (fal / Kling v2.6)
    → conform to the timeline → register as media
```

The conform step is new and is what unblocked you. Clips came back from the model at
1904×1088 / 24 fps; a 24 fps clip in a 23.976 sequence drifts a frame every ~42 seconds.

**A real, conformed, placeable fill exists right now.** Use it as your test target:

| | |
|---|---|
| Timeline | `38ae439b-3735-48a7-8b1d-c80348271035` ("Levis Cut v1", 23.976 fps) |
| Gen job | `84952287-c6e9-406a-8302-612e3188cb38` |
| Footage row | `b80db334-fc27-45fe-80f1-3c47b31707a4` |
| Conformed file | 1904×1072, `24000/1001`, **exactly 100 frames**, 4171 ms, no audio, 3.7 MB |

It is deliberately **not** 3840×2160 even though the project is 4K — see §4, question 4.

Suite on the tower: 596 passed, 7 skipped. Migrations at `b7e41c92f5a3`.

---

## 2. Your tasks, in order

### Task 1 — Get the MCP server reachable from the tower

1. Launch NUEditor with its MCP server enabled.
2. Confirm it is listening on `19789` and serving `/mcp`.
3. Get the Mac's **Tailscale** hostname or IP — the tower reaches you over the tailnet, not
   localhost. Verify from the Mac that the interface is bound in a way a remote host can reach
   (a server bound to `127.0.0.1` only will not work; if it is loopback-only, say so rather than
   changing the binding without flagging it — exposing an unauthenticated MCP server on a network
   interface is a decision to make deliberately, and the tailnet is the boundary we are relying on).

**Report:** the exact URL I should put in `NUEDITOR_MCP_URL`.

### Task 2 — Report the real tool schemas

Read `Sources/NUEditorPro/Agent/Tools/ToolDefinitions.swift` at the current fork HEAD and report
the **actual** signatures for these, not what any doc claims:

`import_media`, `get_media`, `get_timeline`, `add_clips`, `create_timeline`, `remove_clips`

For each: exact tool name, every parameter with its type, whether it is required, and the
response shape. Note the units on every time-like field.

My existing client (`app/infrastructure/external/nueditor_client.py`) assumes:

- `import_media` takes `{source: {url|path|bytes|matte}, name?}` and returns `{mediaRef, status}`;
  `url` imports are async and finish when `get_media` stops reporting `generationStatus`.
- `add_clips` takes entries `{mediaRef, trackIndex, startFrame, source?: [startSec, endSec]}`,
  validated atomically, `trackIndex` 0-based, `startFrame` in project frames.

**Tell me where those assumptions are wrong.** That is the single most valuable thing in this
document.

### Task 3 — Answer the behaviour questions in §4

These cannot be read off a schema; several need a small experiment in a scratch project. They
decide how the Python placement code has to behave, so please actually run them rather than
reasoning from the source.

### Task 4 — Only if Task 2 or 3 exposes a real gap

If a tool NUEDIT needs is missing or cannot express what placement requires, that is Swift work.
Implement it in the fork, keep it consistent with the surrounding tool code, and report what you
added. Do not refactor anything adjacent.

---

## 3. Set up a test project

Make a scratch NUEditor project I can drive without risking anything real:

- **23.976 fps**, 3840×2160, named `NUEDIT Placement Test`.
- At least one video track with a couple of clips and a **deliberate hole** in the middle.
- Report its project id / how I address it, the track ids and indices, `totalFrames`, and the
  frame range of the hole.

---

## 4. Questions I need answered

Number your answers to match.

1. **Frame rate on import.** Import a 23.976 fps clip (`24000/1001`). What does `get_media`
   report for `fps` — the rational, a rounded decimal, or something else? Does NUEditor
   re-interpret or resample it?

2. **`startFrame` origin.** Is frame 0 the first frame of the timeline, and is `startFrame`
   inclusive? If a clip starts at frame 100 and runs 100 frames, does the next clip butt at
   frame 200 or 201?

3. **`source` units.** The entry takes `source: [startSec, endSec]` in *seconds* while
   `startFrame` is in *frames*. Confirm that is really the case — mixing units in one entry is
   unusual enough that I want it verified before I write the conversion. What happens if `source`
   is omitted entirely (whole asset)?

4. **Mismatched resolution.** Our fill is 1904×1072 in a 3840×2160 project. When placed, does
   NUEditor scale it to fill the frame, pillarbox it, or leave it small? **This decides whether
   my no-upscale policy holds.** If NUEditor pillarboxes rather than scales, tell me — I will
   upscale on the tower instead, and I would rather know now than ship soft black-barred inserts.

5. **Duration mismatch.** If a clip is placed into a hole that is 101 frames wide but the media
   is 100 frames, what happens — a one-frame gap, an error, an auto-extend? And the reverse:
   media longer than the hole?

6. **Overlap.** If `add_clips` places a clip where one already exists, is it rejected, does it
   overwrite, or does it ripple? Related: is there a way to place *into* a gap specifically?

7. **Atomicity.** Confirm one bad entry rejects the whole `add_clips` call, and report what the
   error looks like — I need to parse it.

8. **Provenance.** Is there any way to tag a clip or leave a marker/note on the timeline
   recording that a clip is AI-generated? We want that visible to whoever opens the project. If
   there is no mechanism, say so and I will handle it on the tower side.

9. **Import of a remote URL.** Does `import_media` with an `https://` URL work against a
   self-signed or plain-HTTP tailnet host, or does it require valid TLS? This determines how I
   serve the file (§5).

---

## 5. Known blocker on my side — do not fix from the Mac

NUEditor cannot see the tower's filesystem, so `import_media` must use `url` mode. Right now the
tower **has no route that serves a conformed fill**: `views/web/media.py` only serves
`thumbnail | preview | vlm` kinds and sits behind a web session, and `NUEDITOR_MEDIA_BASE_URL`
is empty.

I will add that route. Your question 9 tells me what it has to satisfy (TLS, auth, ranges).

If it turns out `import_media` copes better with something other than a plain URL — a byte
upload under ~11 MB would fit our 3.7 MB fill — say so, because that would skip the route
entirely.

---

## 6. Rules

- **Do not** change anything under a `nuedit` Python path — that is my side of the fence.
- **Do not** rename, rebrand or restructure. The debrand is done; leave it alone.
- **Do not** add Clerk, Convex, or any subscription-gated generation path. Generation stays on
  our own infrastructure.
- **No AI attribution in commit messages** and no mention of Claude anywhere in the repo.
- Keep commits conventional and scoped. If you only verified things and wrote no code, do not
  invent a commit — just report.
- If a question in §4 cannot be answered without guessing, **say "unknown"**. A wrong answer here
  costs more than a missing one, because I will write code against it.

---

## 7. Reporting back

Write your findings to `docs/phase4/2026-07-27-placement-findings.md` in the fork, commit, and
push. Structure it as:

1. MCP URL to use (Task 1)
2. Real tool schemas (Task 2) — corrections to my assumptions called out explicitly
3. Test project details (§3)
4. Numbered answers to §4
5. Anything you changed in Swift, and why
6. Anything that surprised you

Once that lands I will write the placement path: serve the conformed fill → `import_media` →
`add_clips` at the gap's `startFrame` → mark the gap resolved.

---

## Appendix — context worth having

- **Architecture:** `docs/superpowers/specs/2026-07-24-nueditor-mcp-integration-design.md` on the
  tower is the agreed design. §2 lists the tool surface, §5 the field mapping, §6 the gap-fill
  flow. Treat it as intent, not as a description of current code — §4 above exists precisely
  because parts of it are assumptions.
- **Frame mapping** already implemented and unit-tested on the tower
  (`app/core/nueditor_map.py`): NUEDIT stores milliseconds, NUEditor speaks project frames.
  `ms_to_frame` uses **half-up** rounding, not Python's banker's rounding, so 12.5 → 13
  predictably. V1 → `trackIndex` 0, V2 → 1.
- **One naming wart** you may notice in the job record: `meta.trim_ms` (800) is how much *longer*
  the model's clip was than the gap, while `meta.conform.notes` says 876 ms was actually cut off
  the tail. Different facts, colliding names. Mine to clean up; ignore it.
