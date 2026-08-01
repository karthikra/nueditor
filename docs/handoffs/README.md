# Cross-repo handoffs — NUEditor ⇄ NUEDIT

NUEditor (this repo, the Mac editor) and NUEDIT (`karthikra/nuedit`, the tower backend) are one
product built by separate Claude Code sessions on separate machines. They coordinate **through git**
— there is no live agent-to-agent channel and none is needed. This file is the protocol and the
index of open threads.

## The rule that keeps the two in sync

**Pull the sibling and read its latest before you build against it.** Every desync so far has been
one of two failures: a stale local clone, or acting on an assumption the other side had already
answered. Both are avoided by the same habit.

At the start of any cross-repo work:

```
git -C ~/Developer/nuedit pull --ff-only      # or ~/Developer/nueditor from the tower side
```

Then read the newest handoff addressed to you (below) before planning.

## Where things live

| | Path |
|---|---|
| Sibling repo (tower) on this Mac | `~/Developer/nuedit` |
| Tower → editor requests | `nuedit: docs/superpowers/handoffs/*-nueditor-*.md` |
| Editor → tower replies | `nueditor: docs/phase4/*-findings.md`, `*-followup.md` |
| The interface **contract** (source of truth) | `nuedit: docs/superpowers/specs/2026-07-24-nueditor-mcp-integration-design.md` |
| Verified editor-side behaviour (schemas, gotchas) | `nueditor: docs/phase4/2026-07-27-placement-findings.md` |

**Boundary:** each session owns its own repo. The editor agent reads `nuedit` for context but does
**not** edit it (the tower's standing rule: *"do not change anything under a nuedit Python path"*),
and vice versa. Cross-repo changes are proposed as a handoff, not made across the fence.

## The convention

- **A request** is a dated doc in the owning repo, addressed to the other side, stating what it needs
  and any test targets: `YYYY-MM-DD-<topic>-handoff.md`.
- **A reply** is a dated findings/followup doc in the *responder's* repo, cross-linking the request:
  `YYYY-MM-DD-<topic>-findings.md`. The requester pulls the responder's repo to read it.
- **Verify, don't assert.** Findings about the other side's runtime should be produced by exercising
  it (drive the MCP server, hit the endpoint), not read off source. Say "unknown" rather than guess —
  a wrong answer costs more than a missing one, because the other side writes code against it.
- **A contract change is a sync event.** When a tool schema, the ms↔frame map, or the field mapping
  changes, it changes the contract doc above; the diff is how the other side finds out.

## Making one agent see both sides

The biggest friction-remover is to add the sibling to your Claude Code session as a **read**
reference, so the agent reads the other repo's real code and handoffs directly instead of the human
copy-pasting between them:

```
/add-dir ~/Developer/nuedit          # from a nueditor session (read-only in practice; honour the boundary)
```

## Open threads

| Date | Thread | Request (tower) | Reply (editor) | Status |
|---|---|---|---|---|
| 2026-07-27 | MCP placement verification | `nuedit …/handoffs/2026-07-27-nueditor-placement-handoff.md` | `docs/phase4/2026-07-27-placement-findings.md` | ✅ answered |
| 2026-08-01 | Reciprocal CLAUDE.md section for the tower | — | `docs/handoffs/nuedit-CLAUDE-section.md` | ⏳ tower to apply to `nuedit/.claude/CLAUDE.md` |
| 2026-07-28 | Fill fetch: http vs https | placement handoff §5 (updated `bbdb9da`) | `docs/phase4/2026-07-28-fill-fetch-followup.md` | ⏳ awaiting tower: bytes vs Tailscale-HTTPS |

Newest first. When a thread closes, mark it ✅ and leave it for history.
