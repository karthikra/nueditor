# NUEditor → NUEDIT, 2026-11-07: archiving camera originals to S3

**For: NUEDIT (`backend`).** From NUEditor `main` after `5141846`. Edge ingest Stage 5, which the
Mac side is now building against your `core/archive.py` + `views/v1/archive.py`, read at
`6c53407`. Four asks, in priority order, plus a correction to my last findings doc.

The goal is simple and worth stating: **today the camera original exists in exactly one place, the
user's external drive.** Proxies reach you; the original never does. A dead drive loses the
full-res footage. Your archive design (tower presigns → Mac PUTs straight to S3 → tower verifies)
is the right shape, and the Mac will use it as written. These are the gaps that stop it being safe
for real camera media.

---

## 0. Correction — the API *is* authenticated

`2026-08-21-fractional-fps-shipped-and-edge-ingest.md` §2.2 said I read no auth on the footage
router. **Wrong.** Every `/api/v1` router is mounted with
`[Depends(get_current_user_api), Depends(enforce_project_scope)]` (`views/v1/router.py:41`). I read
the router file and missed that the dependency is applied at include time. Sorry for the noise.

---

## 1. How does the Mac authenticate? (blocks everything, incl. edge-register)

The Mac sends `Authorization: Bearer <token>` from a token typed into Settings. But your JWTs expire
after **30 minutes** (`JWT_ACCESS_TOKEN_EXPIRE_MINUTES = 30`), and an archive run is hours of
background work on a machine nobody is watching. A pasted JWT cannot carry that.

**Ask:** pick the credential a long-lived desktop client should hold. Options I can see in your
code — your call, I will not invent one:

- a per-machine **service key** (like `agent_keys`, but accepted by the `/api/v1` routers), scoped to
  one org/project; or
- a **refresh** endpoint the Mac can call with a long-lived refresh token.

Whatever you choose, tell me the header and the failure shape (401 body) so the Mac can say
"re-authorise this Mac" instead of failing silently.

Also: `~/.nuhandoff/hub.toml` on this Mac has no `api_url`, and `:8000` still refuses the
connection from here (`:8010` FLUX and `:8011` nuhub answer). Nothing has reached your API yet.

---

## 2. An interrupted upload strands the footage in `uploading` forever (correctness)

`presign_archive_upload` sets `archive_status = "uploading"`. `decide()` then refuses both
`candidates` and `presign` for `uploading`. Nothing ever moves it back. So **any** interruption —
quit, sleep, network drop, URL expiry, a crash — after presign and before a successful `complete`
leaves that original permanently un-archivable, and it silently disappears from `candidates`.

**Mac-side mitigation (already built):** after every PUT attempt, success or failure, the Mac calls
`archive/complete`. With no object in S3 that flips the row to `failed`, which `decide()` re-offers.
And if the PUT actually landed but the response was lost, `complete` finds the object and records it
— correct either way. This covers every failure **except a crash or force-quit mid-upload**.

**Ask:** make `uploading` a lease — store `uploading_since`, and let `decide()` treat an `uploading`
row older than the URL's `expires_in` as retryable. (Or simply let `presign` re-issue for
`uploading`; a second presign for the same key is harmless, S3 PUT is last-writer-wins.)

---

## 3. Files over 5 GB cannot be archived at all (capability)

`presign_upload` signs a single `put_object`. **S3 caps a single PUT at 5 GB.** ProRes, BRAW, R3D and
long 4K takes routinely exceed that — the footage that most needs a backup is exactly what this
cannot take. A large single PUT also tends to outlive a 1-hour URL on a home uplink.

**Mac behaviour until this lands:** the Mac **does not call presign** for an original over 5 GiB
(presigning would strand it in `uploading`, §2). It reports "too large to archive yet" locally.

**Ask: a multipart flow.** Proposal — change it freely, just tell me the final shape:

```
POST /footage/{id}/archive/multipart            → {upload_id, key, part_size, part_count}
POST /footage/{id}/archive/multipart/parts      {upload_id, part_numbers:[1..n]}
                                                → {parts:[{part_number, url, headers}]}
POST /footage/{id}/archive/multipart/complete   {upload_id, parts:[{part_number, etag, checksum_sha256}]}
                                                → same body as archive/complete
POST /footage/{id}/archive/multipart/abort      {upload_id}
```

Presigning parts on demand (not all up front) keeps URLs fresh and makes a resumed upload cheap: the
Mac persists `upload_id` and which parts are done, and after a restart asks only for the rest.
Please also add an `AbortIncompleteMultipartUpload` lifecycle rule on the bucket so abandoned
uploads don't bill forever. Part size is yours; I'd suggest 64 MiB (a 500 GB file stays under
S3's 10,000-part limit at ≥ 50 MiB).

---

## 4. The archive is verified by size only (integrity)

`complete_archive` checks `ContentLength == file_size_bytes`, and skips even that when
`file_size_bytes` is null. A corrupted-but-same-size upload is recorded as `archived`, and nobody
finds out until the drive is gone and the backup is needed.

**Ask:** bind the checksum into the presign, so **S3 itself rejects wrong bytes**:

- **Single PUT:** presign with `ChecksumSHA256 = base64(bytes.fromhex(footage.checksum))`. The Mac's
  identity checksum *is* the whole-file SHA-256, so this is a true end-to-end check against what was
  hashed at ingest, at no cost to either side.
- **Multipart:** `ChecksumAlgorithm=SHA256` per part; the Mac sends each part's SHA-256. (S3 can't
  produce a full-object SHA-256 for multipart — it's composite — so per-part is the strongest
  available, and the Mac's whole-file hash stays the identity.)

**Return every header the signature requires in the presign response** as a `headers` object, e.g.
`{"Content-Type": "application/octet-stream", "x-amz-checksum-sha256": "…"}`. The Mac sends exactly
what you return and adds nothing else (no `Authorization` — S3 rejects a second auth mechanism).
Today it sends the `Content-Type: application/octet-stream` your signer bakes in; once `headers`
appears it uses that instead, so this is backward compatible.

---

## Smaller things (fix when convenient)

- `archive_candidates` applies `.limit(limit)` **before** filtering, so with >100 already-archived
  rows it can return an empty list while pending originals remain. The Mac does not depend on
  `candidates` (it presigns per `footage_id` it already holds), so this is low priority for us.
- Storage class, lifecycle (e.g. transition to Glacier), and bucket region are your decisions —
  tell me if any of them change restore latency, because the Mac will eventually show it.

---

## What the Mac does (the contract you can rely on)

Per registered original (it already holds your `footage_id`), one upload at a time, in the
background, never blocking edit / import / export:

1. **Check locally first, send nothing if it fails:** the original is mounted, and its size and
   modification date still match what was hashed at ingest. A changed file is reported, never
   uploaded under the old checksum.
2. Over 5 GiB → stop (§3). No presign.
3. `POST /footage/{id}/archive/presign?expires_in=` — scaled to the file (≥ 1 h, ≤ 24 h). A
   `skipped` body is honoured: `already archived` is success; `project opted out` / `no checksum`
   are reported, not retried in a loop.
4. `PUT` the original to the URL with exactly the signed headers, streamed from disk.
5. `POST /footage/{id}/archive/complete {key}` — **always**, even after a failed PUT (§2). Only
   `archived: true` counts as archived. The returned `s3://` URI is stored in the project.

Status: built and unit-tested against this contract with a stubbed transport. **Not live-verified** —
no request has reached your API (§1).
