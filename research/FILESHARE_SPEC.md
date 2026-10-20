# File Share browsing and local map downloads

Implemented and checked on 2026-10-18. These operations read the account's
share; they do not publish, update, or delete items or change upload receipts.

## Owned-share listing

Discover `MCCAzureFunctions_GetPlayFabUgcItems` and
`MCCAzureFunctions_GetPlayFabUgcItem` from the same official service
configuration used for uploading. Existing saved settings without these fields
fall back to their known `mcc-production.azurefd.net/api/` routes. Supplied
URLs still pass MCC service transport validation.

Listing is a POST with `{}` and these headers:

| Header | Value |
| --- | --- |
| `Accept` | `application/json` |
| `CreatorEntityId` | signed-in account's PlayFab entity ID |
| `UserEntityId` | same entity ID |

Accept root `Items`/`Count` or a `data` envelope. A complete result requires a
nonnegative integer `Count` equal to the raw array length, no error envelope,
no continuation marker, valid stable catalog IDs, and confirmed ownership.
Check completeness before filtering `ContentType == "MapVariant"`.
Missing counts, malformed entries, conflicting duplicates, or continuation
markers produce an explicit partial warning rather than a complete/empty
claim. No continuation request schema has been established for this wrapper.

The native MCC list task (`0x14055647c`) and parser (`0x140556a94`) were
decompiled in a bounded Ghidra pass with autoanalysis disabled. The native
request has the same three headers, a zero body argument, and no page/cursor
arguments. Its parser uses `Count` to reserve capacity and iterates actual
`Items`; it has no pagination loop. The working `{}` body and stricter
count check are confirmed by the live client behavior and local reference
client. These observations do not prove that a future server cannot cap lists.

Analysis was pinned to MCC executable SHA-256
`be70d6dcd1a884f10ceb342a7a2dcb35ee0fa43181b66a1d19c3d830e9834691`,
image base `0x140000000`. Local-only detailed evidence is preserved in
`research/fileshare-browser-native/` and `research/fileshare-browser-protocol.md`.

## Item identity and content

Catalog IDs identify selections, independently of duplicate titles and
extensionless service filenames. Models bind selections to both the account's
XUID and entity ID. Fresh lookup sends `ItemId` with `X-EntityToken` and checks
the returned ID, `MapVariant` content type, and `CreatorEntity.Id` before GET.
Source authorship is distinct from ownership of the shared catalog entry.

Prefer exactly one `Contents` entry with `Type == "data"`. Older live entries
can omit `Type`; accept exactly one untyped candidate when no typed data
exists. Explicit images/thumbnails and ambiguous candidates are rejected.
Recognized HTTPS destinations are the existing Azure blob/PlayFab catalog
hosts, MCC's service host, and the observed legacy
`xforgeassets002.xboxlive.com`. Reject embedded credentials, other ports, and
fragments. Scoped URLs and raw responses are never included in user errors.
On a CDN 401/403, refresh item details and retry once; this never retries an
upload. Expired app sessions renew through the existing auth service.

## Map files and saving

The download parser is separate from `ReachMapDocument`, whose strict checks
remain appropriate for fresh Reach uploads. Generic downloads require bounded
BLF framing, exactly one `mvar` or `mapv` payload, a valid end marker, and
bounded valid zlib expansion for `_cmp`. No Reach-only chunk version or `chdr`
requirement is imposed. JSON/HTML/XML error documents are rejected.

Keep the entire received byte buffer, including compression, zero padding,
and opaque trailers after outer `_eof`. Do not strip to an upload prefix or
fabricate `_fsm` signatures. Native conditional trailer reconstruction is
documented in [DOWNLOAD_FINDINGS.md](DOWNLOAD_FINDINGS.md); it is not a
universal prerequisite for exporting the received file.

The save dialog supplies a readable sanitized `.mvar` filename with a stable
ID suffix and standard overwrite confirmation. Stage in the destination
directory, sync and reread/hash the stage, then atomically rename it. Failed or
cancelled stages are removed without truncating an existing map.

## Verification and limits

All native test suites passed, including 16 new File Share cases covering
mocked requests, account binding, envelopes/completeness, legacy content,
expired links, malformed payloads, multiple games, compression, byte
preservation, failed/cancelled saves, filenames, and settings migration.
App-model lifecycle guards were reviewed statically; they do not have a
dedicated automated suite.

Live listing returned a complete account-scoped list of 62 maps: two Halo 3,
six Halo 4, and 54 Reach entries. Three older entries with no local publication
receipts downloaded and passed staged/saved SHA-256 checks:

| Map | Saved bytes | Format observed |
| --- | ---: | --- |
| Straight Ahead (Halo 3) | 8,192 | `chdr` 9.2, `_cmp` containing `mapv` 12.1, physical padding |
| req 30 (Halo 4) | 5,867 | `chdr` 10.2, `_cmp` containing `mvar` 50.1 |
| Request 4 (Reach) | 6,100 | `chdr` 10.2, `_cmp` containing `mvar` 31.1 |

The Reach sample loaded through the local Mjolnir `mvarlib` parser: 511
occupied objects, version 31, `cmp4`, original salted big-endian hash flavor.
That parser reported existing length/header mismatch warnings; the downloader
preserved the source bytes. The stricter upload inspector rejected this
legacy header, further demonstrating why upload validation cannot gate export.

The installed release app displayed the same 62-map list. Its native save
dialog downloaded req 30; the saved bytes matched the independent CLI download
exactly (SHA-256
`499a2af4ef2661b56349e52b48e56c08d73de4eed367363f77c23ed3cbe53dd2`).
Reveal in Finder selected that file. Loading the downloaded HOT WHEELS LOOP
core into Publish restored its existing receipt and disabled duplicate upload;
the existing Check Download action then verified its stored bytes successfully.
No new upload or remote mutation was used for these checks.

Installed samples additionally establish Halo 3 `athr`/`mvar` without `chdr`,
Reach `mvar` 31, and Halo 4 `mvar` 50. H2A version 52 has public-source and
fixture coverage but no live File Share sample here. Structural validation and
saved-byte equality do not establish gameplay or every editor's acceptance.
