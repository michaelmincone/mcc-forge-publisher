# MCC Reach fresh-upload specification

Reviewed 2026-10-12. This combines bounded static analysis of the **shipped MCC
Windows client** with a legitimate-account native macOS sign-in and live upload.
Microsoft/Xbox/PlayFab sign-in, upload permission, explicit upload success,
catalog publication, byte-identical authenticated CDN readback, and successful
Xbox download have been observed for both an untouched original map and the
edited Headstrong export. The successful edited upload used the updated native
macOS GUI. The first failed publication used two metadata values that differed
from the recovered native path: `CreatorId = "0"` and a human-readable `.mvar`
basename. Both are corrected in the successful fresh uploads; isolated causality
has not been established. The publisher reads only its own Keychain entries
and does not scrape other apps' credentials or execute the game. The server's
true minimum field set remains untested.

## Practical fresh request

Use the full twelve-field metadata shape below, valid Reach BLF core bytes,
the user's legitimate PlayFab session/entity credentials, the authenticated
uploader XUID, and discovered service URLs. For fresh unsigned provenance,
omit `FileAdditionalMetadata`; do not invent a signature, certificate, or
downloaded-item identity. Block a live publish when map mapping, endpoint
configuration, or valid authentication is missing.

The smallest **MCC-shaped** fresh metadata is not proven to be the smallest
server-accepted document. Empty defaults still appear as JSON fields. In the
traced creation path, `Type` is an empty string; the `ugc` value seen in public
catalog response schemas is not an established fresh-upload requirement.

```json
{
  "Title": {"neutral": "A map title"},
  "Description": {"neutral": "A map description"},
  "DisplayProperties": {
    "BuiltInMapId": "209",
    "CreatorId": "<authenticated-uploader-decimal-xuid>",
    "FileName": "b54c15c6-3c52-43b3-8745-c49a508371be",
    "FileSize": "29481",
    "GameEngine": "6"
  },
  "Platforms": ["2"],
  "Tags": ["HaloReach", "_map_id_haloreach_forge_world", "PC"],
  "CreationDate": "",
  "LastModifiedDate": "",
  "StartDate": "",
  "ETag": "",
  "Id": "",
  "Type": "",
  "ContentType": "MapVariant"
}
```

The illustrated values belong to a synthetic fresh Forge World record. They
must not be applied to an arbitrary map. The files in `upload-fixtures/` contain
nonsecret deterministic metadata and framing expectations, not a usable map or
service-valid credentials.

## Confirmed field types and defaults

| Field | Shipped fresh behavior | Publisher rule |
|---|---|---|
| Title | Language-keyed object; native converter writes lowercase `neutral` | Use the source/user-entered title; do not encode as a bare string |
| Description | Same object shape and lowercase key | Preserve source/user-entered description |
| DisplayProperties | Object with string-valued entries | Decimal numbers are strings |
| Platforms | Array of strings; native conversion adds decimal `2` | `['2']` for the traced PC publishing path |
| Tags | Array of strings | Reach + map enum tag + PC, as explained below |
| CreationDate | Empty string when optional native catalog timestamp is unset | Preserve empty fresh default |
| LastModifiedDate | Empty string when unset | Preserve empty fresh default |
| StartDate | Empty string when unset | Preserve empty fresh default |
| ETag | Constructor initializes empty string | Empty for a new catalog item |
| Id | Converter copies native **catalog ID** string | Empty for fresh item; do not substitute local GUID or chdr unique ID |
| Type | Constructor initializes empty string; traced fresh converter does not change it | Empty MCC-shaped default accepted in the observed fresh upload |
| ContentType | Map subtype assigns `MapVariant` | Exact case `MapVariant` |

When optional catalog timestamps are present, serializer helper `0x140478ed8`
formats `%Y-%m-%dT%H:%M:%S.000Z`. These are distinct from the native map's
author/editor timestamps carried in DisplayProperties. The fresh creation path
does not automatically promote those author/editor timestamps to catalog dates.

## DisplayProperties and identities

`0x140591c2c` converts the native file metadata object into catalog metadata:

| Property | Native source | Representation / confidence |
|---|---|---|
| GameEngine | Native object `+0x20`, passed through `0x1401e50b4` | Reach enum 6 yields decimal string `6`; confirmed |
| FileSize | Native object `+0x158` | Unsigned/large integer decimal string; must match the variant core payload |
| FileName | Upload task explicitly overwrites this property before serialization | Canonical lowercase hyphenated UUID with no extension, from native local metadata GUID |
| CreatorId | Native object `+0xc8`, only inserted when an existing property is absent | Decimal string; current authenticated owner XUID in the traced fresh-map save path |
| AuthorXuid | Native object `+0xd0`, omitted when zero | Original/source author, not necessarily uploader |
| EditorXuid | Native object `+0xe0`, omitted when zero | Original/source editor |
| LegacyAssetId | Native object string `+0x118`, omitted when empty | Preserve when known; do not fabricate from a UUID |
| AuthorTime | Native object `+0xd8`, omitted when zero | Native time string helper; conversion unit requires verified source parser |
| EditorTime | Native object `+0xe8`, omitted when zero | Same limitation |
| BuiltInMapId | Map subtype object `+0x468`, extracted by `0x1401c952c` | MCC map enum signed short, rendered decimal string |

`CreatorId` is separate from the source's `AuthorXuid` and header unique ID.
The native fresh-save path `0x1404d9584` gets the signed-in user through
`0x14038c2ec`; `0x14022ce5c` returns its XUID, saved at `0x1404d961e` and checked
nonzero at `0x1404d9622`. Calls to `0x140595010` at `0x1404da6f6` and
`0x1404db599` pass that XUID as argument 6. The chain
`0x140595010` → `0x140593d58` → `0x140593940` stores it in native metadata
`+0xc8`, which `0x140591c2c` serializes as `CreatorId`. A fresh publisher should
therefore use its authenticated uploader XUID. `0` in the initial implementation
was a constructor-default assumption, not the observed fresh native value.
The fixture uses a clearly synthetic nonzero XUID for deterministic framing;
real requests must replace it with the signed-in account's XUID. Evidence:
`filename-gate/asm/0x1404d9584.asm` and `filename-gate/pass-13` through `pass-14`.

The local metadata constructor `0x140590b50` calls `CoCreateGuid` at object
`+0x24`, while initializing catalog ID `+0xf8` to an empty UTF16 string. The
catalog converter copies that string to catalog `Id`, not the local GUID.
These IDs are also distinct from raw Reach content-header IDs and the new
`fileId` returned by the upload service.

## Reach map mapping and tags

Raw Reach scenario IDs are **not** MCC BuiltInMapId enum values.
`reach-map-id-registry.json` records all installed `.mapinfo` files, hashes,
the BLF `levl` first BE32 value and English UTF16BE title, and an independently
decoded MCC map-tag enum. Matching uses exact normalized English title against
the shipped `_map_id_haloreach_...` suffix. This is corroboration from shipped
resources and code, not a captured execution of the native conversion function.

| Installed level | Raw scenario ID | MCC BuiltInMapId | Map tag |
|---|---:|---:|---|
| Forge World (`forge_halo.mapinfo`) | 3006 | 209 | `_map_id_haloreach_forge_world` |
| Breakneck (`cex_headlong.mapinfo`) | 10050 | 208 | `_map_id_haloreach_breakneck` |

The shipped `hr_forgeWorld_asylum.mvar` independently contains raw map ID 3006
in both the content header and map body. There is no basis to map raw 10050 to
Forge World. Two campaign mapinfo entries did not match the tag names and remain
unresolved; unknown IDs must block publishing rather than extrapolate.

Map subtype tag method `0x140593834` sets game enum and built-in-map enum in a
tag descriptor, leaving the middle mode descriptor at `-1`. Generic converter
`0x1404824e0` adds game name, map tag, and PC. Thus the traced Forge World tags
are exactly `HaloReach`, `_map_id_haloreach_forge_world`, and `PC`; Breakneck
uses `_map_id_haloreach_breakneck`. Game name is a tag, while GameEngine is `6`.

The static enum walk in `map_tag_static_walk.py` interprets a deliberately
small instruction vocabulary in the leaf comparison tree. It never executes
the Windows binary. The JSON preserves every visited address per input.

## Variant core and body framing

The upstream creator `0x14047fd68` determines the usable file prefix with
`0x14038696c` when a native core length is not already present, copies that
prefix, creates catalog metadata, and queues the upload worker. Therefore a
physical file's tail must not automatically become part of `ContentLength`.

An installed Asylum `.mvar` has physical size 29945, with `_eof` ending at
29481 and a trailing `_fsm` chunk of 464 bytes. `_fsm` carries file-share
metadata/provenance separately. For that envelope the source variant core
is the 29481-byte `_blf`/`chdr`/`mvar`/`_eof` prefix. Preserve a valid envelope,
validate all chunk bounds, and split trailing provenance before framing.

`0x14037b6d4` obtains compact UTF8 metadata JSON from `0x140479364`, appends
those exact JSON bytes to the core byte vector, and passes the vector to body
setter `0x1403864bc`:

```text
metadataData = UTF8(compact JSON, no BOM, no trailing NUL or newline)
body = variantCoreData || metadataData
custom ContentLength = decimal len(variantCoreData)
custom MetadataLength = decimal len(metadataData)
transport Content-Length = decimal len(body)
Content-Type = application/octet-stream
```

Serialize once, count **bytes**, and send those same bytes. Do not count Swift
characters or UTF16 code units. Preserve source metadata ordering when practical;
JSON ordering equivalence is a design assumption for an unsigned fresh request,
not a demonstrated server rule. No multipart encoding or base64 map body is used.

## Upload, permission, and authentication headers

Logical upload service: `MCCAzureFunctions_UploadFile`, method `PUT`.

| Header | Value |
|---|---|
| EntityToken | `data.EntityToken.EntityToken` from legitimate PlayFab LoginWithXbox |
| x-auth-token | PlayFab `data.SessionTicket` |
| Accept | `application/json` |
| FileName | Canonical lowercase hyphenated UUID, no extension; native upstream upload initiation derives it from local metadata GUID |
| ContentLength | Variant-core byte count, decimal ASCII |
| MetadataLength | UTF8 metadata suffix byte count, decimal ASCII |
| AuthorFileXuid | Authenticated current-user XUID, decimal ASCII |
| Sandbox | Platform identity provider's sandbox string; `RETAIL` only when that is the authenticated context |
| FileAdditionalMetadata | Optional serialized provenance header; omit in the fresh unsigned path |

`ContentLength` and `MetadataLength` are custom names without hyphens and are
separate from HTTP `Content-Length`. The HTTP layer sets octet-stream type and
combined body length. Keep each token bound to its issuer, title, relying party,
and expiry; do not replace a missing credential with a different token type.

**Filename correction from subsequent native tracing:** low-level upload
`0x140486dcc` forwards source object `+0x28` unchanged, but that value is already
a UUID. Upstream initiation `0x1403879ac` takes local metadata GUID `+0x24`,
formats it through `0x1404833ec` with flags `0x100` (lowercase, hyphens, no
braces/extension), and passes it to `0x140592c28`, which stores the string at
metadata `+0x1f8`. Its char pointer at `+0x210` is passed to `0x140483ec8`,
creating the source custom string at `+0x10`; its char pointer is the source
`+0x28` consumed by upload. A human-readable `.mvar` basename does not reproduce
this native behavior. Evidence: `filename-gate/pass-4` and `pass-5`.
This does not establish a strict Xbox download gate. A filename-only update of
the first entry was accepted but its Xbox retest still failed. Fresh entries
with both a native-format filename and the authenticated uploader's `CreatorId`
subsequently downloaded successfully on Xbox. This validates the corrected
combined request, not an isolated filename requirement. The local filename UUID
and catalog Id remain distinct identifiers.

Permission service: `MCCAzureFunctions_GetUploadPermission`, method `POST`,
two explicit headers `x-auth-token` and `Accept: application/json`; no body is
set in the selected builder. Parser `0x14037d470` consumes `isAllowed` boolean
and optional `localizeStringId`/`expiration` strings. Denial stops publication.

Upload parser `0x14037c808` consumes `result`, optional `errorText`,
`deniedUploadInfo`, `fileId`, and `fileShareMetadata`. Do not equate HTTP 200
with success: require the explicit recognized success result and a returned
file identity. The native success string is `success`; other table values are
`deniedUpload`, `signatureNotValid`, and `anyError`.

The bounded [post-upload audit](upload-finalize-audit.md) traced response
completion through local identity/provenance updates, operation coordination,
and the completed queue. It found no second catalog publish/finalization
network request in the ordinary publication path. The final indirect
application callback and the Xbox executable were not exhaustively examined.
The working fresh uploads therefore do not add a speculative
`PublishDraftItem` step after successful MCC `UploadFile`.

## Verified live publications

| Publication | Source | Catalog item | Verification |
|---|---|---|---|
| Headstrong - Original Control | `~/Local_Documents/Halo-MCC/forge/real-mvar-samples/0aaaf8c7-5ae6-43ba-bb4d-37c987f5e8b8.mvar` | `3c1ccd0e-5903-4d96-be82-7810f3676884` | `GetItemPublishStatus` succeeded; authenticated CDN core hash matched; user confirmed Xbox download |
| Headstrong, edited export | `~/Local_Documents/Halo-MCC/forge/maps/headstrong-star/Headstrong_Star.mvar` | `ed150b45-48fe-4189-9d6d-d537819333e3` | Updated native GUI published it; **Check Download** verified exact core hash; user confirmed Xbox download |

Both cores are 29,481 bytes. The original-control core SHA-256 is
`53d60e21eab7f2a3092199b9fb29aa592ab7b54edac660c39b1446aa37bce4fd`;
the edited core is
`24ce68b51b3f1aae8a3da7fe0879fa6c07e0cb5d79029f008700dfda6181156e`.
The source files and core bytes were not rewritten by publishing. Independent
source hashes are preserved in
[source-byte-comparison.json](reach-blob-audit/source-byte-comparison.json).

The user confirmed manually deleting the initial failed item
`14001448-a0e0-49ca-a2f0-e8f2290e15b3`; that accounts for its later
`ItemNotFound` response. Its disappearance is not evidence of automatic
moderation. Successful console downloading is established for the two new
entries; an isolated one-field rejection rule and a minimal-field elimination
test are not established.

## Fresh versus signed provenance

The upload metadata helper `0x14037cc9c` calls `0x1403b5e80` and clears its
result on false. That serializer checks the signature block's first word;
zero takes the empty path. Upload has separate eight-header and nine-header
branches, with `FileAdditionalMetadata` only in the nonempty branch.

Fresh upload is not evidence of permission to erase or forge somebody else's
provenance. If a source has nonempty signature/provenance data, preserve its
material and verify it through the documented workflow or stop until supported.
The fixture is an unsigned record, not a modified signed download.

## Bootstrap and current service URL resolution

Public HaloCache constants identify PlayFab title `EE38`,
`https://ee38.playfabapi.com/Client/LoginWithXbox`, and relying party
`rp://playfabapi.com/`. These public identifiers do not establish third-party
title authorization. See `AUTH_SPEC.md` for the registered/unofficial identity
boundary and refusal behavior.

**New static distinction:** `0x1402c6d54` is the real settings discovery
scheduler. It concatenates configured `SettingsBaseUri` (state `+0x170`) and
`PlatformSubUri` (`+0x190`) via `0x1402e0b7c`; it constructs settings task
`0x1402ed2c4` with title string `hmcc`. Execute `0x1402ed61c` builds a GET task
and adds `Accept: application/json`. Constructor `0x1402c6660` loads
`data\\careerdb\\base-service-settings-v3.json` into the configuration document
at state `+0x2038`. Its `SettingsBaseUri` virtual node selects by SandboxId;
the default/RETAIL host is `https://settings.svc.halowaypoint.com`.
`PlatformSubUri` selects by Platform. For `hmccpc`, the shipped base path is
`/settings/hmccpc/9d6dbeddd8bc478f92c6a6fac6424ca7`.

**Confirmed live discovery on 2026-10-12:** unauthenticated GET with
`Accept: application/json` to
`https://settings.svc.halowaypoint.com/settings/hmccpc/9d6dbeddd8bc478f92c6a6fac6424ca7`
returned HTTP 200, a 17678-byte JSON configuration, and these exact bindings:

| Logical service | Production URL | Method from shipped client |
|---|---|---|
| MCCAzureFunctions_UploadFile | `https://mcc-production.azurefd.net/api/UploadFile` | PUT |
| MCCAzureFunctions_GetUploadPermission | `https://mcc-production.azurefd.net/api/GetUploadPermission` | POST |
| MCCAzureFunctions_GetFileSharePublicKeys | `https://mcc-production.azurefd.net/api/GetFileSharePublicKeys` | POST |

The response authority `mccazurefunctions` declares hostname
`mcc-production.azurefd.net`, port `443`, scheme `2`, and authentication-method
array `[0]`. The named endpoint QueryString fields are empty. No Spartan token,
PlayFab credential, or password was required to fetch this configuration.
Configuration body SHA256:
`985efc2aa5f1250acbdc69b672b1b625f879c8d99e42c26ae2995a1e400fa018`.
Saved response/provenance: `official-service-config-2.json`,
`official-discovery-read-results.json`, and `confirmed-production-bindings.json`.

The installed halo-service override has a different PC resource ID beginning
`01a002...`, which returned 404. Current public GameCMS halo-service settings
were also fetched successfully and contain no bootstrap URI override, leaving
the shipped base values as the observed working bootstrap. Do not cycle sandbox
or platform identities after refusal; these are configuration selectors, not an
authentication workaround.

Endpoint parser `0x1402ed84c` reads `Endpoints` and `Authorities`, resolves
`Endpoints[name].AuthorityId` to `Authorities[id].Hostname`, and constructs
`https://` + hostname + endpoint Path (default `/`), with substitutions and
retry policies. Upload, permission, and public-key service names are table
indices 44,45,56, read from corresponding state string slots +0x7b0,+0x7d0,+0x930.

The separate later function `0x1402c7eb4` calls PlayFab GetTime with an
`X-Authentication` header. Ordinary official GetTime normally returns only
`data.Time`. It is not a verified source of the endpoint map.

Unauthenticated GET probes on 2026-10-12 returned 404 for guessed
`mcc-production.azurefd.net/api/UploadFile`, `/api/GetUploadPermission`, and
several simple settings paths. Those earlier wrong-method probes are not route
proof; the later official settings response is the authority for the confirmed
bindings above. Fetch and validate that configuration, require HTTPS with its
known intended MCC host, and resolve the three named services. Subsequent native
legitimate-account tests confirmed allowed permission and explicit upload success.

Sources: [official PC settings response](https://settings.svc.halowaypoint.com/settings/hmccpc/9d6dbeddd8bc478f92c6a6fac6424ca7),
[HaloCache API constants](https://github.com/HaloCache/halo-mcc-data/blob/main/src/constants/api.js),
[official GetTime](https://learn.microsoft.com/en-us/rest/api/playfab/client/title-wide-data-management/get-time?view=playfab-rest),
[HaloCache File Share reads](https://github.com/HaloCache/halo-mcc-api/blob/main/src/services/fileshare.service.js).

## Evidence and remaining gaps

Source MCC executable SHA256:
`be70d6dcd1a884f10ceb342a7a2dcb35ee0fa43181b66a1d19c3d830e9834691`.
Preferred PE base `0x140000000`; addresses need rebasing under ASLR.
`metadata-pass-1` through `metadata-pass-7` preserve selected Ghidra C,
assembly, references, and manifests against that exact source. Missing
prototypes/leaf routines and PE fragment boundaries remain explicit limitations.
The saved bounded project was reused; no whole-program analysis was started.

Unresolved: server minimum field validators; author-time chdr mappings;
signature support for imported signed files; isolated metadata-field causality;
and compatibility of other map variants beyond the two successful Xbox downloads.
The selected compatibility registration accepted this user's legitimate login;
that observation does not establish provider approval of third-party registrations.
Offline fixtures verify request preparation. Live outcomes and both control
identities are recorded above and in [DOWNLOAD_FINDINGS.md](DOWNLOAD_FINDINGS.md).
