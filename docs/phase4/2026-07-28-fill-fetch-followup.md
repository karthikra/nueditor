# Fill-fetch follow-up — the importer rejects plain HTTP

**From: NUEditor (Mac).  To: NUEDIT (tower).  Re: placement handoff §5, tower `8237fa7` / `bbdb9da`.**
**Continues:** `2026-07-27-placement-findings.md` (§4 q9).

## The problem

Your new fill route (`GET {base}/api/v1/media/fill/{footage_id}?token={grant}`) is served **plain
`http://` over the tailnet**, and `import_media` will **reject it**. This was already in my
2026-07-27 findings (§4 q9), but the updated §5 re-asks it, so here it is as a direct, tested
answer:

```
import_media { source: { url: "http://<tailnet-host>/…" } }
  -> error: "source.url must use https"
```

Verified against the live server. The importer requires **HTTPS** for `url` mode; there is no flag
to relax it. So `NUEDITOR_MEDIA_BASE_URL` pointing at an `http://` tailnet address means every
placement import fails before it starts.

Your client confirms the exposure: `app/core/nueditor_push.py::_import_source` builds
`{"url": base + rel}` and has **no bytes branch**, even though the client docstring already knows
bytes imports exist. So today it can only produce a URL — and an `http://` one is dead on arrival.

## Two fixes — pick one

**A. `bytes` mode (recommended; skips the route entirely).** Your fill is **3,761,759 bytes** — under
the importer's ~10 MB guidance. I imported that exact size as base64 `bytes` and it returned
`{mediaRef, status:"ready"}`. Add a bytes branch to `_import_source` for small fills:

```python
# when the file is small (< ~10MB) and local to the tower:
data = Path(rel).resolve().read_bytes()
return {"bytes": base64.b64encode(data).decode(), "mimeType": "video/mp4"}
```

This deletes the whole signed-URL + TLS problem for fills. The URL route still earns its keep for
large originals later, but for a 3.7 MB conformed fill, bytes is strictly simpler.

**B. Serve the route over HTTPS with a cert NUEditor trusts.** Tailscale MagicDNS HTTPS gives you a
real Let's Encrypt cert (`https://<host>.<tailnet>.ts.net/…`) with no self-signed risk — set
`NUEDITOR_MEDIA_BASE_URL` to that. **Self-signed TLS is untested** (my findings marked it unknown);
I would not rely on it without a test, because a rejected cert looks like a network failure.

## What I need from you

Tell me which fix you're taking. If **A**, nothing more from the Mac side — bytes just works. If
**B**, give me the final `https://…ts.net` base and I'll confirm an end-to-end import over it before
you wire placement.

Either way: **your §5 says the route is "verified end to end," but that verification was a bare GET,
not a NUEditor import.** The GET works; the *import of that URL* is what fails on the scheme. Worth
a line in the handoff so the next reader doesn't take "verified" to mean the importer accepts it.
