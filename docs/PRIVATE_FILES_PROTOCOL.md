# Legacy Xbox UGC storage research

Research date: 2026-10-21. The cloud records described here belong to MCC's old
Xbox UGC storage. They are not an implementation of the current **Private Files**
tab. Current Private Files management remains an unfulfilled requirement.

## Official migration behavior

[Halo Support's legacy UGC documentation](https://support.halowaypoint.com/hc/en-us/articles/360049447211-Halo-The-Master-Chief-Collection-Legacy-User-Generated-Content-UGC-Support)
states that MCC deprecated its old Xbox-specific cloud storage in November 2020.
On the first subsequent Xbox sign-in, private UGC migrates to storage on that
Xbox, while public File Share content migrates to the newer cross-platform
cloud. This resolves the earlier ambiguity around the retained numeric cloud
slots: successfully reading them establishes access to a legacy archive, not
access to the console's present private library.

An upload or deletion against the old archive must not be presented as an upload
or deletion in current Private Files. The archive must stay separate from the
live library, and its content must never silently replace current console files.

## Evidence and tools

REA 6.7.0 inspected the installed MCC PE resources, and Ghidra 12.1.4 performed
bounded decompilation with general autoanalysis disabled. The PC executable is
67,179,480 bytes, SHA-256
`be70d6dcd1a884f10ceb342a7a2dcb35ee0fa43181b66a1d19c3d830e9834691`.
Game binaries and decompiler output remain in the ignored `investigation/`
directory; they are not repository fixtures or redistributed app dependencies.

MCC function `0x1405319f4` constructs the Temporary, Private, and Shared UI
categories. The Private category uses native category 3, `$LOCAL`, and the
`FileShareLocalSmall` icon. Function `0x140483090` maps that category to
`LocalFiles`; `0x14058e160` constructs its platform-local game/content path.
Private and Shared must therefore have different service operations. Publishing
another catalog item is not a private-file upload.

The PC binary did not expose the Xbox save migration strings `AceUserContent`,
`MigrationState`, or `savedgame` during the targeted scan. It cannot, by itself,
prove how the current Xbox build consumes older Connected Storage records.

## Read access observed to the legacy archive

A read-only probe used the publisher's own legitimate saved sign-in, the
existing MCC registration, and the generic Xbox relying party
`http://xboxlive.com`. It did not use PlayFab credentials to authorize saves.
It did not launch MCC, acquire or break a storage lock, or issue a save write.

MCC's installed `app.config` supplies SCID
`77290100-225e-4768-9373-98164430a9f8`. A live title-details read independently
returned that SCID and package family `Microsoft.Chelan_8wekyb3d8bbwe`.
Authenticated reads to the legacy Connected Storage namespace
`https://titlestorage.xboxlive.com/connectedstorage/users/xuid(<own XUID>)/scids/<SCID>`
returned nine retained save containers, including:

| Container | Observed contents |
| --- | --- |
| `UserContent/Map,savedgame` | 13 numbered atoms |
| `UserContent/GameTypes,savedgame` | 9 numbered atoms |
| `Saves/AceUserContent,savedgame` | One `data` atom |

Legacy container detail replies contained an `atoms` dictionary mapping each numerical
slot name to an atom UUID with the `,binary` suffix. Reading those atom URLs
returned individual historical private-file records. Atom references, signed-in IDs, and
downloaded private content stay in local research files rather than this document.

The observed requests used contract version 107, the title's package family,
and the generic Xbox authorization. The experimental auth extension, codec,
read client, mutation prototype, and tests are archived outside the shipping
package under ignored `investigation/legacy-cloud-prototype/`. The publisher's
production authentication was restored unchanged. The archived prototype kept
Xbox tokens in memory, redacted their descriptions, and checked account binding;
these properties do not establish access to current console-local Private Files.

## Version-6 record format

All six independently inspected records used this little-endian outer format.
The BLF payload inside it retains its own byte order.

| Offset | Field |
| --- | --- |
| 0 | UInt32 metadata byte count, excluding this initial length field |
| 4 | UInt32 metadata version, observed as 6 |
| 8 | UInt32 file kind: 0 gametype, 1 map |
| 12 | 16-byte Windows GUID; the first three GUID components are little-endian |
| 28 | UInt32 discriminator, observed as 1; other values are not interpreted |
| 32 | UInt32 MCC game engine; observed samples were Halo 3, engine 2 |
| 36 onward | Locale key, title, description: each UInt32 UTF-8 byte count, those bytes, then a NUL excluded from the count |
| After text | Author XUID, author FILETIME, editor XUID, editor FILETIME: four UInt64 fields |
| After authors | UInt32 subtype: built-in map enum or unified gametype category |
| Gametype only | One-byte Forge flag |
| Through 275 | Remaining metadata slot bytes |
| 276 | UInt32 logical payload byte count |
| 280 | Original BLF bytes and any bytes included in the declared logical payload |
| After payload | Remaining physical slot bytes |

The metadata capacity is 272 bytes. The six records were 59,672 bytes for maps
and 118,040 bytes for gametypes, corresponding to a 280-byte prefix plus payload
capacities `0xe800` and `0x1cc00`. Native loader functions `0x14058d288` and
`0x14058f36c` use those capacities when allocating buffers; larger and different
platform formats have not been established as writable by this implementation.

The payload length is authoritative. The map samples' logical payloads ended at
their BLF EOF. The gametype samples declared 956 bytes although their BLF core
ended at byte 953; one of the three additional bytes was nonzero in one sample.
The decoder preserves those three bytes. Trimming at EOF or the last nonzero
byte would lose or invent original file data.

`PrivateFileEnvelope` keeps the full atom as `rawData` and exposes exactly the
declared logical payload for export. It bounds every metadata field, checks the
container kind, Windows GUID, record version and payload length, and invokes the
game-independent BLF validator. Export does not rewrite provenance or signatures.

## Offline legacy-record construction

The offline legacy-record constructor preserves the full source bytes. It uses a
new record GUID, engine 6, source author/editor identities and timestamps, and
the existing verified Reach map and gametype enum mappings. Source Unix-second
timestamps are converted to FILETIME; they are not replaced with the current
time. Private metadata overflow or a payload larger than the established slot
is rejected rather than silently truncated.

The shipped `Data/careerdb/careerdb.xml` establishes Reach map locale keys:
built-in enums 190 through 209 map to `$HReach_MPMap_R-1_Title` through
`$HReach_MPMap_R-20_Title`. Its `GameCategories` table supplies exact gametype
labels, including `$GAMETYPE_KINGOFTHEHILL`, `$GAMETYPE_BASIC_EDITING`,
`$GAMECAT_ACTION_SACK`, and `$GAMETYPE_PRE_GAME`. A preset's display label must
not be substituted for its category label.

Offline construction and reinspection succeeded for a Reach Slayer fixture,
the local Vanishing Floor gametype, and Skybranch v03. Their source files and
payload bytes were unchanged. Synthetic protocol tests separately cover the
observed wire layout, Unicode lengths, GUID order, FILETIME, kind mismatch,
truncation, and opaque payload trailers.

## Current console storage access investigation

The `AceUserContent` data atom begins with a `NOSJ` header and migration JSON.
Its completed private-file GUID set had 22 entries, matching the 13 map and nine
gametype slots. This is consistent with the officially documented migration.
It does not make the archived blobs the current private library.

Current private-file access requires an authorized route to the retail console's
local MCC storage or an MCC feature that exposes those files. No such file API
has been established for this Mac app. The following alternatives were checked:

| Route | Evidence and limitation |
| --- | --- |
| Xbox Device Portal | Microsoft's documented setup targets a development console. Its save tools address game saves through SCID/PFN, not a documented bridge into another retail game's local UGC. |
| Retail-console Developer Mode | Microsoft distinguishes it from Retail Mode; retail games and apps cannot run there. Enabling it is not evidence that a companion app can access retail MCC's private files. |
| GDK remote console file tools | Microsoft documents file access from a development PC while the development title is running. These tools are not a verified customer-console service available to the Mac publisher. |
| Xbox Remote Play | Officially exposes console game streaming and controller interaction. It can show MCC's existing file-management UI, but no documented binary file transfer API was found. |
| Connected Storage | The observed UGC atoms are the old migration source. No currently synchronized private-UGC container has been identified; a successful archive GET is not evidence that one exists. |

Sources: [Device Portal for Xbox](https://learn.microsoft.com/en-us/previous-versions/windows/uwp/xbox-apps/device-portal-xbox),
[Xbox development FAQ](https://learn.microsoft.com/en-us/windows/uwp/xbox-apps/frequently-asked-questions),
[GDK local-storage documentation](https://learn.microsoft.com/en-us/gaming/gdk/docs/features/console/storage/local-storage?view=gdk-2604),
and [Xbox's Remote Play announcement](https://news.xbox.com/en-us/2025/04/16/xbox-april-update-buy-games-xbx-app-stream-your-own-game-console/).

The local PC binary confirms the private category's filesystem path; its targeted
string scan did not reveal a companion file server or Device Portal endpoint.
This is bounded negative evidence, not a proof that no future supported route
could exist. Console-local storage isolation is also consistent with Microsoft's
[title-specific local-storage model](https://learn.microsoft.com/en-us/gaming/gdk/docs/features/console/storage/local-storage?view=gdk-2604).

A future console-side integration would need evidence that it can read and modify
the actual current MCC library, with access authorized by the console and title.
It would then require disposable-file runtime tests for upload, download, delete,
and bulk behavior. Publishing private content to Shared Files as an intermediate
step changes its visibility and is not an equivalent implementation. Legacy
archive reads, schema construction, and mocked mutation tests must not be
described as completed current Xbox Private Files management.
