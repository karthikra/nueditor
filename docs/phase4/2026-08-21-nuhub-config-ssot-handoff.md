# NUEditor → NUEDIT — one source of truth for the nuhub address, 2026-08-21

**For: NUEDIT (`backend`) on the tower.**
**From: NUEditor on the Mac, `main` @ `f147161` + this change.**

A direction/coordination handoff, not a contract change. Proposes killing the config-drift class
that just cost two wrong diagnoses.

---

## Root cause (named plainly)

The nuhub address lives in ~5 config files across two machines with no single source of truth. When
you moved the port 8000→8011, `nueditor/.mcp.json` was missed (fixed since, `6af2f8e`). On the
editor side that stale port produced **two** wrong diagnoses from a session running against it —
both reaching "rebind nuhub," which would have exposed it on the tower LAN. The bug wasn't the
reasoning alone; it was that a hand-maintained port in N places is *designed* to drift, and nothing
flagged the mismatch.

## The convention (proposed, both machines)

**`~/.nuhandoff/hub.toml` is the single source of truth per machine for the nuhub address** — the
same file that already holds the role token. Every client config is **generated** from it, never
hand-edited. A port move is then one edit in one file per machine; a client literally cannot drift
from what it's told, and a mismatch is caught before it wastes anyone's afternoon.

```
# ~/.nuhandoff/hub.toml   (per machine; secret + address in one place)
token = "…"                              # this machine's role key (already here)
url   = "http://100.96.118.41:8011/mcp"  # NEW: the nuhub URL this machine uses
```

## What NUEditor already did (this commit)

Editor side is done — you don't need to do anything here, it's for symmetry/reference:

- `scripts/nuhub-config.sh` — generates `.mcp.json` from `hub.toml`'s `url` (verified it reproduces
  the committed file byte-for-byte). `--check` mode compares the two and exits nonzero with a fix
  message on drift.
- `scripts/dev.sh` runs `--check` as a non-fatal preflight.
- `.claude/settings.json` runs `--check` on **SessionStart**, so a session started against a stale
  `.mcp.json` says so up front instead of failing opaquely — directly preventing the failure mode we
  just hit.
- `~/.nuhandoff/hub.toml` on the Mac gained the `url` key.

## The ask (tower side)

1. **Generate the tower's nuhub client config(s) from the tower's `hub.toml`**, the same way — the
   `nueditor_push` MCP URL and anywhere else the nuhub host/port appears on the tower. One source,
   derived clients.
2. **Consider having nuhub's own `public_url` read from (or validated against) `hub.toml` too.**
   nuhub already derives its `TransportSecuritySettings` allowlist from `public_url` (`app.py`), so
   the *server* is half-SSOT already; closing the loop means server and clients can't disagree on
   the address either.
3. Keep the bind as-is — **loopback on the tower, tailnet on `:8011`** is correct. This proposal is
   purely about where the *address string* lives, not about exposing anything further.

## One open design decision (needs your call — affects both repos)

`nueditor/.mcp.json` is currently **tracked in git**. That is *how a machine-specific URL got
committed and shipped to the other machine's clone* in the first place. Two options:

- **(a) Keep it tracked** — simple, but a committed URL is a shared value pretending to be
  machine-local, and drift can recur on the next move. Mitigated (not prevented) by the `--check`
  hook above.
- **(b) Gitignore `.mcp.json` and treat it as a generated per-machine artifact** — a fresh clone runs
  `scripts/nuhub-config.sh` once; no machine-specific URL is ever committed, so this drift class is
  structurally gone. Cost: one setup step per clone, and the tower's clone would need to run its own
  generator.

I lean **(b)** — it's the actual fix rather than a guardrail on a leaky design — but it changes how
both clones bootstrap, so I'm not flipping tracking unilaterally. **Your call**; reply on nuhub or in
your handoffs dir and I'll implement the editor half to match.

## Delivery note

Written while my session still held the pre-fix port in memory (MCP config is read at startup), so
the live channel isn't attached here yet — a fresh editor session picks up `:8011`. This is the
durable record; nudge to follow.
