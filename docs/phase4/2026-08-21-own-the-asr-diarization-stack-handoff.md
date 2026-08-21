# NUEditor → NUEDIT — own the ASR + diarization stack, drop Deepgram, 2026-08-21

**For: Claude Code running in the `nuedit` fork on the tower.**
**From: NUEditor on the Mac, `main` @ `f0c24eb`. Read against `nuedit` @ `80cfb0c`.**

This is a **direction/decision handoff**, not a contract change. It asks the tower to replace a
hosted dependency with a self-owned stack. Implementation choices inside `nuedit` are yours — this
states the goal, why, the acceptance criteria, and the open questions I need answered before the
editor side changes anything. Nothing in the editor blocks on this; the MCP contract does not change.

---

## The decision

**We are owning the transcription + diarization stack and removing external hosted APIs.** The one
that matters is **Deepgram**. Replace it with an open, self-hosted pipeline on the tower.

This is the same thesis that removed Clerk and Convex: *clean, unbranded, self-owned, local; nothing
phones home.* Deepgram (`nova-2`, `diarize=true`) is a hosted, closed, paid API in exactly that
category. It should go the same way — not urgently, but deliberately, with a real replacement.

---

## What I read on your side (so we're working off the same facts)

Verified in `nuedit` @ `80cfb0c` — correct me where I've misread:

- **`infrastructure/external/deepgram_client.py`** — `DeepgramClient.transcribe_url(...)` calls
  `api.deepgram.com` with `model=nova-2`, `diarize=true`, `utterances=true`. This is the hosted
  dependency to remove. It returns words + per-word speaker labels in one call.
- **`infrastructure/external/whisper_client.py`** — `transcribe_auto` dispatches to local
  faster-whisper `large-v3` (CPU int8) or Modal. Transcription; `TranscriptSegment.speaker` exists
  but Whisper does not fill it.
- **`core/asd.py` + `asd_pipeline.py` + `asd_aggregate.py` + `vendor/light_asd/`** — Light-ASD
  visual active-speaker detection: face-detect → track → AV-sync scoring → per-face `speaking_ms`,
  aggregated per chunk into `roll_signals`. **This is the asset that makes the switch safe** (see
  below). Already self-hosted, already yours.
- **`infrastructure/db/models/speaker.py`** — project-scoped `speakers` table: `provider_id`,
  `name`, `role`, `voice_profile` (JSON). `provider_id` currently looks Deepgram-shaped.
- No `pyannote` / `nemo` / `sortformer` / `ecapa` anywhere in the repo today.

If any of that is stale, that correction is the most useful thing you can send back.

---

## The target stack (open, self-hosted)

One component per job — keep them decoupled:

| Job | Replace with | Notes |
|---|---|---|
| Words + timestamps | **Parakeet-TDT** (NeMo) | TDT predicts token durations → good native timestamps; tops English Open-ASR leaderboards; very fast on your GPU. Replaces both Whisper *and* Deepgram's transcription. Multilingual: `parakeet-tdt-0.6b-v3`. |
| Audio diarization (who-spoke-when) | **pyannote.audio** or **NeMo Sortformer** | Sortformer pairs naturally with a NeMo Parakeet deployment and handles overlap better than clustering. pyannote is the safe general default. Replaces Deepgram's `diarize`. |
| Visual active-speaker | **Light-ASD** | Already have it. **Keep and lean on it.** |
| Precise word boundaries (optional) | **wav2vec2 / MMS forced alignment** | Only if you want boundaries tighter than the ASR gives — the editor's cut can use them (see §"why the editor cares"). |
| Speaker identity across files | `speakers.voice_profile` + **ECAPA/WeSpeaker** embeddings | Replaces reliance on Deepgram `provider_id` for identity. |

### Why this isn't a downgrade

Pure-audio open diarizers are weakest on **overlapping speech** — that's the one place Deepgram is
genuinely ahead. But **you already compute the visual signal that closes the gap.** Fuse Light-ASD's
per-face `speaking_ms` with the audio diarizer's segments and, *on footage with faces*, the open
stack is competitive with Deepgram and arguably better (the mouth-motion prior disambiguates overlap
that audio alone can't). Light-ASD is the reason we can drop the hosted diarizer without regressing
multi-speaker video.

**The honest exception:** audio-only footage (VO, faceless podcast) has no visual prior, so a
pure-audio open diarizer carries it alone — that's the case to benchmark before flipping the switch.
See open question 3.

---

## Why the editor cares (context, not a request)

The editor just shipped **sample-accurate word cutting** (`nueditor` @ `f0c24eb`): deleting a
transcript word cuts the media, and a sub-frame silence removes the fragment the frame grid leaves
behind. It relies on **accurate per-word end times**. On-device it uses Apple SpeechTranscriber;
where the tower supplies the transcript, boundary quality matters directly. Parakeet-TDT's
duration-aware timestamps (or an optional forced-alignment pass) would feed that cut cleanly.

Diarization does **not** affect the cut geometry — the cut needs *boundaries*, not *speaker labels*.
It affects transcript **attribution** in the editor UI (selecting "speaker B's filler"). So this
change improves attribution and keeps the stack open; it does not put the cut at risk either way.

---

## Acceptance criteria

1. **No network call to any hosted ASR/diarization API** in the ingest/transcript path. `deepgram_client.py`
   removed or behind a hard-off default. Grep-clean of `deepgram`, and of any other hosted-ASR host.
2. Transcript output preserves the **same shape** the editor already consumes over MCP — words with
   `start`/`end` in **source seconds**, plus per-word/segment `speaker` labels when available. If the
   field names or units change, that is a **contract change** → update
   `docs/superpowers/specs/2026-07-24-nueditor-mcp-integration-design.md` and say so; the editor reads
   the diff.
3. Per-word **end** times are populated (not just `start`) — the cut depends on them.
4. Diarization labels remain **project-stable** (same person → same id across a project), preserving
   the `speakers` table semantics.
5. Multi-speaker **video** diarization uses the Light-ASD fusion, not audio alone.
6. Tests: unit-cover the new transcribe/diarize seams the way the Deepgram/Whisper clients are covered
   today; keep the Light-ASD aggregate tests green.

---

## Open questions (answer before I change anything editor-side)

1. **Contract:** does the MCP/transcript payload the editor consumes change at all (field names, units,
   speaker-label format)? If yes, which fields — so I update the editor's decode and the shared spec.
2. **`speakers.provider_id`:** is it Deepgram-specific today? What replaces it as the stable identity
   key under the open stack (embedding-cluster id? pyannote label mapped through `voice_profile`)?
3. **Audio-only footage:** what's the plan where Light-ASD can't help? Which audio diarizer, and can
   you run a quick multi-speaker VO benchmark (open diarizer vs. the current Deepgram result) before
   committing? I can supply a test clip.
4. **Transcription engine:** are you replacing Whisper with Parakeet-TDT, or keeping Whisper and only
   swapping the diarizer? Either is fine for the editor as long as end times stay accurate — I just
   need to know which, since it affects boundary quality for the cut.
5. **Identity duplication:** the editor still has an on-device `WeSpeakerModel` doing cross-file voice
   matching. Per our CLAUDE.md, **NUEDIT owns diarization/identity; the editor renders.** Do you want
   the editor's WeSpeaker path retired (tower is the single source of speaker identity), or kept only
   for a fully-offline editor mode? Your call — it's your ownership area.

---

## What I need back

A short findings reply in your repo (`nuedit: docs/superpowers/handoffs/…`, or wherever you keep
editor-facing notes), cross-linking this doc, answering the five questions and confirming/correcting
the "what I read on your side" list. If the transcript contract changes, that diff in the spec doc is
the real sync event — I'll build the editor decode against it, not against this note.

No rush and nothing here blocks the editor. This is a direction to land deliberately, with the
Deepgram removal gated on the audio-only benchmark (Q3).
