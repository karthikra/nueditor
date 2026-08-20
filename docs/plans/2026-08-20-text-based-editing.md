# Plan — Text-based audio/video editing (edit media by editing its transcript)

**Goal.** Edit spoken-word audio and video by editing the words. Select "young and restless" in the
transcript, press Delete, and the corresponding audio (and, for video, the picture on the same span)
is cut and the gap closed — on-device, no cloud.

**Owner:** Editor (this repo). It's native, on-device, real-time — not a tower feature.
**Roadmap slot:** Phase 4, "Transcript-driven editing" (expands that line).
**Models:** all local — Apple **SpeechAnalyzer** (word timing) + **Silero VAD** (`SpeechVAD`, clean
cut points). No network.

---

## The key realisation: the engine already exists

This is ~80% a UI. The cut pipeline is built and battle-tested through the agent tools; we are adding
a direct-manipulation surface on top of the **same** domain operation (AGENTS.md forbids a second
implementation). Inventory of what we reuse unchanged:

| Piece | Where | What it already does |
|---|---|---|
| Word-level transcript | `Transcription/Transcription.swift`, `TranscriptCache` | on-device, per-word start/end, cached |
| Transcript → project frames | `MediaPanel/CaptionsTab/CaptionTranscriptMapper` | word times → timeline frames |
| **Cut planning** | `Transcription/WordCutPlanner` | `words[selected]` → cut frame ranges, `tight/balanced/loose` breathing room, merges adjacent runs |
| **Delete + close gap** | `remove_words` → `editor.rippleDeleteRangesOnTrack` (`ToolExecutor+Words.swift`) | ripple-delete ranges, **keeps linked A/V in sync**, respects sync-locked tracks |
| **Silence map** | `Audio/Analysis/VoiceActivity` (Silero VAD) | speech/silence spans, cached sidecars |
| Dead-air removal | `SpeechTab` "Remove Silence" → `editor.removeAllDeadAir()` | one-click filler/silence cut, same ripple path |

**So the video case is already solved at the engine level:** ripple delete cuts a video clip's linked
audio partner on the same span, so deleting words cuts picture+sound together and A/V stays locked.

## What's actually missing

1. **A transcript-editor UI** — spoken words as selectable prose, bound to a clip/timeline. (Today the
   engine is reachable only via the agent and the "Remove Silence" button.) — the bulk of the work.
2. **VAD-snapped cut points** — snap cut boundaries to the nearest silence so cuts land in breath gaps,
   not on raw word-timestamp edges. The silence map already exists; feed it into the planner.
3. **Video jump-cut handling** — cutting mid-sentence on a static talking head leaves a jump cut. Offer
   a fix (micro-dissolve, or B-roll cover — reuses gap-fill).
4. Polish: micro-crossfade de-click at joins; word correction; timeline-wide (multi-clip) transcript.

---

## Build (staged, each stage shippable)

### Stage 1 — Read-only transcript panel
A new **Transcript** view (a MediaPanel tab, or an Inspector tab for the selected clip). Renders the
selected clip's cached word-transcript as flowing prose. Bidirectional binding to the playhead:
- click a word → seek the playhead to its `startFrame`;
- playback → highlight the current word (karaoke follow).
No editing yet. Pure reuse of `TranscriptCache` + `CaptionTranscriptMapper`. Transcribe-on-demand if
the clip has no cached transcript (on-device, background, with the existing progress state).

**Ships:** "see what's said, click to jump" — useful alone, and the substrate for everything below.

### Stage 2 — Select words → Delete → cut (the core feature)
Text selection over the words (drag / shift-click / double-click-word). On Delete:
- mark the selected words `selected` → build `[WordCutPlanner.Word]` → `WordCutPlanner.cutRanges(...)`
  with the current `CutAggressiveness` → `editor.rippleDeleteRangesOnTrack(...)`.
- **This is the identical call `remove_words` makes** — one shared path, one undoable action, A/V sync
  and sync-lock handling for free.
Show the pending cut as a struck-through span in the prose + a highlighted region on the timeline
before commit. Deleting updates the transcript view to match the shortened media.

**Ships:** the exact scenario — select "young and restless", press Delete, audio cut, gap closed.

### Stage 3 — VAD-snapped cuts + de-click (intelligence)
Feed `VoiceActivity` silence spans into cut-point selection: snap each range boundary to the nearest
silence within a small window, so cuts land between words in a breath, never mid-phoneme. Add a short
(≈8–15 ms) equal-power micro-crossfade at each join to kill clicks. Expose the existing
`tight/balanced/loose` as the panel's aggressiveness control. Everything local.

**Ships:** clean, professional-sounding cuts, not robotic word-boundary chops.

### Stage 4 — Video jump-cut handling
Deleting words already cuts video+audio. Add, on a video cut, a choice:
- **hard cut** (default) — accept the jump cut;
- **soft** — auto micro-dissolve (short cross-dissolve) across the join;
- **cover** — hand the gap to the generation gap-fill flow (B-roll over the join). Reuses Phase 3.
Detect "static talking head" (low motion around the join, via existing frame sampling) to *suggest*
soft/cover rather than forcing it.

**Ships:** text-editing a talking-head video without ugly jumps.

### Stage 5 — Polish
- **Filler-word one-click** — highlight detected "um/uh/like" + long pauses (VAD + transcript) for
  bulk removal (extends `remove_silence`).
- **Word correction** — fix a misrecognised word in place (display only; re-align optional).
- **Timeline-wide transcript** — concatenate every speech clip's transcript into one document so cuts
  can span clips (the ripple engine already accepts multi-clip project-frame ranges).

---

## Correctness / edge cases (AGENTS.md)

- **One undoable action per delete**, through `EditorUndo` — reuse the `remove_words` grouping; no
  empty steps on a no-op selection.
- **Boundaries:** selection at clip start/end, whole-clip selection (delete the clip), single word,
  adjacent runs (planner already merges), zero-length words (filtered).
- **Linked & sync-locked:** engine already cuts A/V partners together and refuses (naming the blocking
  track) when a sync-locked track can't absorb the shift — surface that refusal in the UI.
- **Stale transcript:** after a cut, word→frame offsets shift; re-derive the view from the post-cut
  timeline (don't trust cached absolute frames across an edit).
- **Off-main:** transcription, VAD, and frame sampling stay off the main actor (existing pattern);
  the panel renders immutable snapshots.
- **Non-destructive:** cuts are timeline ripple edits, never source re-encodes — fully reversible.

## Why it's "intelligent"

1. **Reuse, not reinvent** — one cut engine for agent, "Remove Silence", and this UI.
2. **VAD-snapped cuts** — land in breath gaps for natural edits (local Silero).
3. **Filler/silence awareness** — the same stack removes dead air and "um"s.
4. **Video jump-cut smoothing** — detect static talking heads, offer dissolve or B-roll cover
   (composes with generation gap-fill).
5. **Fully on-device** — SpeechAnalyzer + Silero VAD; works offline, nothing leaves the Mac.

## Estimate

Stages 1–2 (the feature) are small precisely because the engine exists — a transcript view + a
selection→`WordCutPlanner` binding. Stage 3 is a focused audio-quality pass. Stage 4 is the only
genuinely new logic (jump-cut handling), and it leans on Phase 3 generation for the "cover" option.
