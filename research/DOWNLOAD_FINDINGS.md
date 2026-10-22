# File Share download investigation

Path update (2026-10-21): existing checkout and tool references use the current `~/Documents/Halo_MCC/` layout. References to `real-mvar-samples/`, `maps/headstrong-star/` are historical artifacts absent from this checkout; examples requiring them are not ready to run. Recorded test results and literal historical default strings are unchanged.

Read-only static evidence from the installed Windows MCC executable, SHA-256
`be70d6dcd1a884f10ceb342a7a2dcb35ee0fa43181b66a1d19c3d830e9834691`,
image base `0x140000000`. Bounded Ghidra decompilation uses saved exception-table
ranges, without whole-program autoanalysis. Inferred types remain provisional.
The Xbox executable has not been examined.

## Confirmed Windows behavior

- Published-content task `0x1405571f0` submits the selected catalog `ItemId`.
  Parser `0x140557c88` reads `data.Item.Contents[]`, including **`Url`** and
  content `Id`. `DownloadFileTask` execute `0x140555250` issues a GET to that URL.
- Completion `0x140560d18`, scheduler `0x1404872cc`, and raw callback
  `0x140482758` accept a successful, nonempty buffer. Helper `0x14047fce4`
  allocates/copies it. These bounded paths do not parse a FileName as a GUID.
- Outer request `0x14048166c` takes catalog Id from native metadata `+0xf8`.
  Its callback wrapper `0x140488104`, vtable `0x1432b5ac8`, dispatches through
  `0x1404870fc` to `0x140481930`. That consumer clones selected metadata,
  attaches the returned data source through `0x1404815b0`, and copies the
  already-selected 16-byte local GUID into native metadata `+0x24`.
- Catalog conversion `0x1405912a8` reads CreatorId, AuthorXuid, EditorXuid,
  AuthorTime, EditorTime and other DisplayProperties through optional getters.
  No nonzero CreatorId or date-presence rejection was established in it.
  Catalog Id at `+0xf8` is distinct from the native local GUID at `+0x24`.
- Fresh-map save path `0x1404d9584` supplies the signed-in user's nonzero XUID
  to `0x140595010` → `0x140593d58` → `0x140593940`, which stores it in native
  metadata `+0xc8`. Converter `0x140591c2c` emits this field as `CreatorId`.
  Thus fresh native publication uses the current uploader's XUID as CreatorId;
  the original publisher's `0` fallback is a confirmed fidelity mismatch.
  This field is separate from source author/editor XUIDs and the BLF unique ID.
  Its isolated causal role in Xbox download failure is untested. Cache lookup
  `0x14047fb1c` has a zero-owner wildcard fallback, which prevents inferring a
  universal rejection from this field merely being zero.
- UI `0x140533bc0` prompts for untrusted provenance when metadata `+0x288` is
  zero. This is a confirmation branch, not an automatic rejection. Result UI
  `0x140534a40` maps non-success to a generic download error; it cannot identify
  the underlying reason from that dialog alone.
- Shared-to-local copy initiation `0x140534474` creates operation type 5 with
  source store 4 and target store 3. Copy completion `0x14047d258` creates a new
  GUID with `CoCreateGuid(metadata + 0x24)`, clears catalog Id and the local
  filename, then schedules the local write. Local save `0x1405902b0` defaults
  to a GUID path with `.mvar`. This does not establish a universal requirement
  that the incoming protocol FileName must parse as a UUID.
- Native publication **does** use a lowercase dashed local UUID without an
  extension in both protocol FileName fields. The complete source chain is in
  filename-gate/findings.md (historical file: `filename-gate/findings.md`; absent from this checkout). A human basename was
  a confirmed mismatch with that publication path.
- Reach map body decoder `0x18006d468` explicitly accepts body versions 31 and
  32 and has an upgrade path for version 31. Version 31 alone is not a demonstrated
  cause of download failure. Preserved pseudocode: `reach-body-decoder-6d468.c`.
- Local save `0x1405902b0` determines core-prefix length through `0x14038696c`,
  which uses the selected game's DAL parser and object serializer. It checks
  for an existing `_fsm` using `0x1403b6d20`. If catalog signature metadata is
  present and the trailer is absent, `0x1403b6e90` copies the core prefix and
  adds a 464-byte `_fsm` chunk (version 1.1) from catalog FAM. If prefix length
  is zero, that helper instead preserves the supplied bytes. Uploading the EOF
  prefix without an `_fsm` is therefore covered by a native download/save path;
  omission alone does not establish corruption or incompatibility.
- Filesystem completion `0x14058f158` maps the I/O result into the operation
  status. A successful write invokes `0x14058fa04`, which clones metadata and
  stores a local data source in the indexed game/content list. No additional
  game-DAL rejection was found in that completion. The Windows prefix-length
  helper does not itself make zero length a download error. An Xbox-specific
  validation path or later map load remains possible.

## Signature scope of a filename-only catalog edit

Canonical FAM serializer `0x1403b550c` emits exactly `ParentData`, `CurrentData`,
and `CertificateThumbprint`. For each of the two data records, child serializer
`0x1403b58c0` emits exactly `ParentUserXuid`, `ParentPayloadHash`, and
`ParentUgcItemPlayfabId`. Verifier `0x1403b7220` submits those canonical UTF-8
bytes, the preserved signature, and public-key material to `0x1403b5088`.
Protocol FileName, title, dates, CreatorId and other DisplayProperties are not
included in that signed JSON. Therefore an edit confined to catalog filename,
preserving FAM and core bytes, preserves this Windows client's signature input.
Unrelated backend or Xbox-specific constraints remain outside this finding.
Primary evidence is in `../investigation/research/ghidra-targeted/mcc/0x1403b550c.c`,
`../investigation/research/ghidra-targeted/mcc/0x1403b7220.c`, and
`../investigation/research/ghidra-targeted/mcc-auth-addition/0x1403b58c0.c` with their
assembly/reference counterparts.

Evidence is preserved in `download-pass-1` through `download-pass-17`, their
manifests/assembly/reference records, and the independent `filename-gate`
project. A later Reach validity audit examines deeper BLF/mvar import rules.

## Live observations reported by the parent task

These are parent-task runtime results and user confirmations, not authenticated
calls made by the static analysis agent:

| Entry | Outcome |
|---|---|
| Initial Headstrong, `14001448-a0e0-49ca-a2f0-e8f2290e15b3` | Upload success, Xbox catalog visibility, and exact authenticated core readback; Xbox download failed |
| Same initial entry after filename-only catalog update | Update accepted with content references preserved; user reported Xbox download still failed |
| Headstrong - Original Control, `3c1ccd0e-5903-4d96-be82-7810f3676884` | Fresh upload with corrected uploader identity and UUID filename; publication status succeeded, CDN hash matched, and user confirmed Xbox download |
| Fresh edited Headstrong, `ed150b45-48fe-4189-9d6d-d537819333e3` | Updated native macOS GUI uploaded it; **Check Download** matched the core hash, and user confirmed Xbox download |

The first publication used `Headstrong_Star.mvar`, CreatorId `0`, no AuthorTime
or EditorTime, and server-generated provenance. Native tracing established
that its protocol filename and CreatorId differed from the ordinary native
publication path. Fresh uploads now set CreatorId to the signed-in account's
decimal XUID and use one canonical lowercase hyphenated UUID, with no extension,
for both the FileName header and `DisplayProperties.FileName`. Source author
and editor fields remain separate; no map-body repair was made.

The untouched control source was
`~/Documents/Halo_MCC/mjolnir-forge-editor/forge-workspace/real-mvar-samples/0aaaf8c7-5ae6-43ba-bb4d-37c987f5e8b8.mvar`.
Its 29,481-byte core SHA-256 is
`53d60e21eab7f2a3092199b9fb29aa592ab7b54edac660c39b1446aa37bce4fd`.
The edited source remained
`~/Documents/Halo_MCC/mjolnir-forge-editor/forge-workspace/maps/headstrong-star/Headstrong_Star.mvar`,
with core SHA-256
`24ce68b51b3f1aae8a3da7fe0879fa6c07e0cb5d79029f008700dfda6181156e`.
Both published core hashes matched their respective sources. Source comparisons
are preserved in
source-byte-comparison.json (historical file: `reach-blob-audit/source-byte-comparison.json`; absent from this checkout).

Content readback was separately corrected to consume `Contents[].Url` and
accept the official `content1.prod.catalog.playfab.com` CDN host. That enabled
accurate macOS verification; it did not change the uploaded map bytes or the
Xbox client. The GUI now persists account/core-bound publication receipts and
offers **Check Download** without another upload.

The user confirmed manually deleting the initial failed entry. Its subsequent
`ItemNotFound` result is explained by that deletion and must not be described
as evidence of automatic moderation.

## Confirmed result and remaining hypotheses

Legitimate-account native macOS publication followed by successful MCC Xbox
download is confirmed for both the original control and the edited export.
The combined corrected request is validated. CreatorId is the stronger suspect
for the original failure because the filename-only edit did not resolve the
reported failure, but neither a strict Xbox gate nor isolated one-field
causality was established. No deliberate regression upload is needed to use
the now-working native request shape.

Missing optional dates were not added to obtain success, and the core map
bytes were not modified. The deeper Reach audit in
REACH_DOWNLOAD_VALIDITY.md (historical file: `reach-blob-audit/REACH_DOWNLOAD_VALIDITY.md`; absent from this checkout) found
no concrete defect in core format/hash checks or installed Breakneck palette
bounds. The post-upload audit (historical file: `upload-finalize-audit.md`; absent from this checkout) found no second
catalog finalization request in the traced ordinary Windows publication path;
the final indirect application callback and Xbox implementation remain outside
that bounded trace.

Successful downloading does not establish every later map load or arbitrary
map variant, a minimum server field set, support for signed provenance trailers,
or provider approval of an independently registered OAuth client. Those are
separate boundaries from the two verified downloads. No credentials,
authentication stores, account APIs, or remote mutations were used by the
static analysis agent.
