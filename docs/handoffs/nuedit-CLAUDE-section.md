# Proposal for the tower: add this to `nuedit/.claude/CLAUDE.md`

This is the reciprocal of the "Sibling repo: nuedit" section now in
`nueditor/CLAUDE.md`. Applying it makes both ends of the sync protocol match.

**Where it goes:** append to `nuedit/.claude/CLAUDE.md`, after "Key Rules" (before "Quick Start").
**Who applies it:** the tower's own Claude Code session — the editor side does not edit `nuedit`.
**Adjust:** the `NUEDITOR_CHECKOUT` path below to wherever you clone `nueditor` on the tower.

---

```markdown
## Sibling repo: nueditor (the Mac editor) — how we stay in sync

`nueditor` (`karthikra/nueditor`) is the native macOS editor — the hands and face of this product.
It is developed by its own Claude Code session on the Mac. The two repos coordinate **through git**;
there is no live agent channel, and none is needed.

- **Clone `nueditor` on the tower** so this session can read it (once):
  `git clone git@github.com:karthikra/nueditor.git ~/Developer/nueditor`   (NUEDITOR_CHECKOUT)
- **Pull it and read its latest before building against it.** Every desync has been a stale clone
  or an assumption the other side already answered: `git -C ~/Developer/nueditor pull --ff-only`.
- **Boundary:** you own `nuedit`; the Mac owns `nueditor`. **Read `nueditor` for context, never edit
  it.** Cross-repo needs are raised as a handoff, not made across the fence. (The editor session
  honours the same rule in reverse — it will not touch `nuedit`.)
- **Channel:** your requests to the editor go in `nuedit: docs/superpowers/handoffs/` (dated,
  addressed to the editor). Its replies are dated docs in `nueditor: docs/phase4/`
  (`*-findings.md` / `*-followup.md`), which you read by pulling `nueditor`. Its protocol + open-thread
  index is `nueditor: docs/handoffs/README.md`.
- **Contract source of truth:** `docs/superpowers/specs/2026-07-24-nueditor-mcp-integration-design.md`
  (here). Verified editor-side behaviour (real tool schemas, gotchas):
  `nueditor: docs/phase4/2026-07-27-placement-findings.md`. A change to a tool schema, the ms↔frame
  map (`app/core/nueditor_map.py`), or the field mapping **is** the sync event — read the other
  side's diff before you build on it.
- **Verify, don't assert; say "unknown" over a guess** — the editor writes code against your
  answers and you write code against its findings.
- To let one agent see both sides at once: `/add-dir ~/Developer/nueditor`.

### Runtime coupling (the apps, not the dev sync)
NUEDIT is the MCP **client**; the editor hosts the MCP **server**. Its server binds **loopback only**
(`127.0.0.1:19789`), so reach it via the SSH local-forward
(`ssh -N -L 19789:localhost:19789 karthikramesh@100.88.194.45`) and set
`NUEDITOR_MCP_URL=http://127.0.0.1:19789/mcp`. Units: NUEDIT milliseconds ↔ editor project frames
(`round(ms/1000*fps)`, half-up); V1 A-roll → `trackIndex 0`, V2 B-roll → `trackIndex 1`; footage →
`import_media` → `mediaRef`.

**Open item (2026-07-28):** the editor's importer rejects plain `http://` (`source.url must use
https`). The signed-URL fill route is http-over-tailnet, so either add a `bytes` branch to
`_import_source` (the 3.7 MB fill fits, tested) or serve over Tailscale MagicDNS HTTPS. See
`nueditor: docs/phase4/2026-07-28-fill-fetch-followup.md`.
```
