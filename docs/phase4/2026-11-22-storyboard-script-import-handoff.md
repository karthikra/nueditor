# NUEditor → NUEDIT, 2026-11-22: storyboard — import AV scripts from Google Sheets / Docs / CSV

**For: NUEDIT (`backend`).** A new feature, decided with the user today. The editor gets a
**storyboard**: a board of the film's beats showing what the script asks for, what footage covers
each beat, and where the gaps are, with generated placeholders where nothing exists. Scripts are
written outside the editor — mostly **AV scripts / shot lists in Google Sheets** for **ads and brand
films** — so the work is reading those, not writing them.

**Decision: the tower owns all of it except rendering.** Build once: you already parse scripts, store
sections, match footage, analyse gaps and fill them. A CSV / Google Sheet is one more script format.
The editor sends a link or a file, shows the board and the column mapping for the user to confirm,
and acts on the timeline. No script parsing in Swift.

## Split

| | Tower | Editor |
|---|---|---|
| Script source | fetch Google Sheet / Doc by link, parse CSV / XLSX uploads | user pastes a link or picks a file; uploads files |
| Columns | detect the mapping, apply user overrides | show the detected mapping; user confirms or changes it |
| Beats | store as sections (source of truth), refresh on revision | render cards |
| Coverage | match footage → beats, gap analysis, look-matched placeholders | show covered / weak / missing / script-gap; user overrides go back |
| Timeline | assemble a rough cut (existing assembler) | place it, place fills; editing / playback / export stay local |

Footage is unchanged: edge ingest already registers it (proxies + metadata; originals never transit).

## 1. Google access (needed for the server to read private sheets)

Recommendation — your call on the final shape:
1. **A Google service account.** The user shares a sheet/doc with one service-account email, like
   sharing with a colleague. Works for private files, no per-user OAuth. When access is denied,
   return an error naming **exactly** which address to share with, so the editor can show it.
2. **Fallback, no setup:** sheets published to the web or shared "anyone with the link" — read via
   the CSV export URL.
3. **Not** per-user OAuth for now.

Docs: AV scripts in Google Docs are usually a two-column table (visual | audio). Read the document's
tables (Docs API, or export as HTML/DOCX and take the tables); ignore prose outside them.

## 2. Proposed endpoints (change freely; tell me the final contract)

```
POST /projects/{id}/scripts/import
  body: { source: { url } }  or multipart file (.csv / .xlsx)
        mapping?: { <role>: "<header text>" }      # user overrides, by header name
        dry_run?: bool                             # detect only, store nothing
  →     { script_id?, header_row, columns: [{header, role}], unmapped: [header],
          beats: [ ...first N for preview ], beat_count, warnings: [string] }

POST /scripts/{id}/refresh       # re-fetch the source, re-parse with the saved mapping
  →     { added, changed, removed, unchanged, warnings }

GET  /scripts/{id}/board         # what the editor renders
  →     { beats: [{ section_id, order, label, scene, visual, audio, on_screen_text, sound,
                    notes, duration_seconds,
                    coverage: "covered" | "weak" | "missing" | "script_gap",
                    matches: [{ footage_id, start_ms, end_ms, confidence }],
                    placeholder?: { asset_id, kind: "generated_still" | "generated_video" } }],
          unused_footage: [{ footage_id, start_ms, end_ms }] }
```

Roles (stable machine names): `label`, `scene`, `visual`, `audio`, `on_screen_text`, `sound`,
`duration`, `notes`. Sections today carry `section_name / script_text / visuals / remarks`; the
board needs `label`, `scene`, `on_screen_text`, `sound`, `duration_seconds` too.

**Refresh must keep beat identity.** Ad scripts are revised constantly; a re-import that recreates
sections wipes every match. Key sections by the script's shot number (`label`) when present, else
by order + visual text similarity, and report what changed.

**Coverage meanings:** `missing` = no footage; `weak` = best match below threshold; `script_gap` =
the beat has no visual description (the editor tells the user to push back on the writer — don't
generate for it). `unused_footage` = good footage no beat uses; editors want that list too.

**Generated placeholders must stay labelled** as generated everywhere (board, any export), so a
client never mistakes one for footage we hold.

## 3. Parsing rules (prototyped and tested on the editor side, then discarded — port them)

- **Header row is not row 1.** Sheets carry a title block ("LEVI'S 501 — 30s TVC v3", client,
  date). Scan the first ~20 rows; the header is the row naming the most roles, and it must name
  visual, audio or on-screen text.
- **Columns by whole-word synonym, longest wins** (so "Shot description" is visual, not label):
  - label: `#`, no, shot, shot no/number, scene shot, frame, panel, beat, id, ref
  - scene: scene, sequence, section, chapter
  - visual: visual(s), video, picture, image, description, shot/visual/scene description, action,
    what we see, on screen, camera, framing
  - audio: audio, vo, v/o, voice over, voiceover, dialogue/dialog, script, copy, narration,
    what we hear, lines, speech
  - on_screen_text: super(s), on screen text, ost, text, title(s), graphics, gfx, lower third(s),
    caption(s), tagline, legal
  - sound: sfx, sound, sound effects, sound design, music, fx
  - duration: duration, dur, time, timing, length, secs/sec/seconds, timecode, tc, runtime, in out
  - notes: notes, remarks, comments, direction(s), props, wardrobe, location, talent, cast
  - Several columns may share a role (VO + Dialogue): join in column order.
- **Scene headings:** a row with one filled cell and no visual/audio/on-screen text ("SCENE 2 —
  EXT. STREET") is a heading for the beats below it, not a beat. A mapped scene column sets it per row.
- **Timing:** `5`, `5s`, `5 sec`, `5"`, `0:05`, `1:02:05`, `00:00:05:12` (frames at project fps),
  ranges `0:00–0:05` / `0:00 - 0:05` / `0:00 to 0:05` → end − start.
  **A "Time" / "TC" column of rising clock values starting at ~0 holds each beat's start, not its
  length:** duration = next start − this start (last beat unknown). Don't apply that when the
  header says duration / length / secs.
- **CSV:** UTF-8 BOM, UTF-16, CP-1252 fallback; delimiter comma / **semicolon** (Excel in
  comma-decimal locales) / tab, chosen from the opening lines; quoted cells with line breaks and
  doubled quotes. Cap ~10 MB / 10k rows.
- **Warnings, not silence:** no duration column; unreadable timing values (with examples); beats
  with no visual (script gaps); ignored columns by name.

## 4. Test cases worth keeping

1. Title block above the header → header found at its real row; title text is not a beat.
2. Two cards' sheets both numbering shots `1, 2, 3` → labels kept as written, order preserved.
3. "Shot description" header → visual (not label); "VO / Dialogue" → audio; "Super / OST" →
   on_screen_text; `#` → label.
4. Scene heading row between beats → beats below carry the scene; heading is not a beat.
5. Time column `0:00, 0:03, 0:07, 0:12` → durations 3, 4, 5, unknown.
6. Duration column `3s, 0:04, 00:00:05:12 (@25)` → 3, 4, 5.48.
7. Range column `0:00-0:03` → 3.
8. Semicolon CSV with a quoted multi-line VO cell → one beat, line breaks kept.
9. Beat with VO but no visual → imported, coverage `script_gap`, warning counted.
10. Override `{visual: "Picture"}` on a sheet that also has "Video" → only "Picture" is visual.
11. Override naming a header that doesn't exist → clear error naming it.
12. Refresh after the writer edits beat 4's VO and inserts 4A → beat 4 keeps its matches; 4A added.

## What I need back

The final endpoint shapes (or your alternative), the Google access choice and the service-account
email the user will share sheets with, and the board read model. The editor builds the board panel
and the mapping step against your real API once it exists — nothing editor-side is built yet.
Reply on this thread when the import endpoint is live, even before refresh and the board are.
