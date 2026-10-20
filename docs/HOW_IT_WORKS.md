# How MCC Forge Publisher works

A standalone native macOS app for publishing Halo Reach Forge maps, browsing your MCC File Share, and saving shared map variants to the Mac. The app uses SwiftUI, WebKit, Foundation, CryptoKit, macOS Keychain and system zlib. It does not run Windows binaries, CrossOver, .NET, Node or Python.

The specs in [research/](../research/) record the protocol details. The reverse-engineering evidence behind them (MCC binary analysis with Ghidra and REA) stays on the author's Mac and is not part of this repository, so some links inside those specs point to files that are not here.

The complete native publishing path has now been verified with the user's legitimate Microsoft account. Both an untouched original Reach map and the Blender-exported edited **Headstrong** map were published, retrieved with matching core SHA-256 hashes, and successfully downloaded in MCC on Xbox. This verifies those two maps and that account; it does not establish acceptance of every possible map variant.

## Use

1. Open MCC Forge Publisher and choose **Sign in with Microsoft**. Complete Microsoft's sign-in and any MFA in its authorization window.
2. Drag a `.mvar` file into the app, or select **Choose Map**. Its embedded name and description appear automatically.
3. Select **Upload to File Share**. The app discovers MCC's current service URLs, checks your account's upload permission, submits the file and checks the resulting download.
4. Open your File Share in MCC on Xbox to download the map. Xbox acceptance is a separate final check from retrieving the published file on macOS.

The original map is never rewritten. Only its core BLF bytes through `_eof` are uploaded; zero-filled local padding is retained in the original file. Signed or otherwise nonzero trailers are rejected because this first version cannot preserve their provenance safely. The tool supports standard Reach multiplayer map variants with a verified base-map catalog mapping.

## Authentication

Sign-in uses a Microsoft authorization code with PKCE, Xbox SISU and relying-party-specific XSTS, then MCC's PlayFab login. Credentials and the app's proof key are stored only in the app's own login-keychain item. macOS lets the build that created a keychain item read it without asking, and asks before any other build reads it. An ad-hoc signature changes with every build, so the first launch of a new build reads the previous build's item once (macOS asks for the Mac password; Allow or Always Allow both work), saves its own copy under its signature, and clears the older item. Later launches of that build never ask. The `mcc-publish` CLI reads the app's sign-in but never writes it, because a write from another build would reset macOS's approval for the app. The app does not read Steam, CrossOver or browser credential stores and does not collect a password. Routine requests never log raw authentication responses, tokens or authorization URLs.

The app signs in to Xbox as MCC, so Xbox's one-device-per-game rule applies to it. While MCC is open on an Xbox or PC with the same account (including suspended in Quick Resume), Xbox refuses the app's user authorization with HTTP 401 and XErr 0x8015DC1E (2148916254), and the app says so. Fully quit MCC there and open the app again. Xbox sends its reason for any refusal only as an XErr code (SISU in the `x-err` header with an empty body, XSTS in the body), and the app shows that code with the step that failed. MCC's own handling of these codes was traced from the game's PC binary; that evidence is not part of this repository.

The default uses the public MCC compatibility registration described in [AUTH_SPEC.md](../research/AUTH_SPEC.md). This is an unofficial client, not a Microsoft or Halo endorsement. Successful login for a legitimate account establishes that account's observed access; it does not establish approval of arbitrary app registrations. Provider restrictions and refusals stop the flow.

## Protocol

Service discovery is an unauthenticated HTTPS GET to the exact shipped PC settings selector, confirmed against the live official configuration. The resulting endpoint map supplies `MCCAzureFunctions_GetUploadPermission` and `MCCAzureFunctions_UploadFile`.

The upload is a custom PUT with a binary-map prefix followed by UTF-8 JSON metadata. `x-auth-token` contains the PlayFab session ticket, while `EntityToken` contains the PlayFab entity token. `ContentLength` and `MetadataLength` are custom headers and count the two body parts independently. The HTTP transport sends the complete body length. Fresh metadata uses the recovered MCC shape and omits fabricated provenance signatures.

[UPLOAD_SPEC.md](../research/UPLOAD_SPEC.md) contains native function addresses, observed constants, official configuration evidence and remaining assumptions. Protocol filenames use MCC's lowercase hyphenated UUID format without an extension in both the request header and `DisplayProperties.FileName`; the source filename remains unchanged. Fresh `CreatorId` identifies the authenticated uploader, while source author and editor identity remain separate fields.

The initial upload used `CreatorId = "0"` and the human-readable source basename. Both differed from the recovered native publication path. Correcting those fields and publishing fresh entries produced the successful Xbox downloads. A filename-only edit of the first entry did not resolve the reported download failure, making uploader identity the stronger suspect, but the exact causal field has not been isolated. The map core bytes were not changed to obtain success. [DOWNLOAD_FINDINGS.md](../research/DOWNLOAD_FINDINGS.md) records the failed and successful controls.

The publisher never automatically retries PUT. If a connection fails after submission, check the File Share before retrying, since a lost response can follow a successful publication. A recognized success response records an item ID; retrieving the same bytes by SHA256 provides a stronger verification. Neither result claims that an Xbox console has loaded the map successfully.

Publication receipts persist locally and match the account and uploaded core hash. Reselecting a previously published map restores its receipt and prevents a duplicate upload. **Check Download** retrieves and verifies that entry without publishing again. It verifies stored bytes, not the Xbox client's import behavior.

## File Share browser and downloads

The **File Share** area queries the signed-in account's share directly. It does not derive its list from publication receipts, so maps uploaded elsewhere are included. Only map variants are offered for `.mvar` download. Available catalog metadata supplies names, descriptions, game, base-map identity, sizes, and dates. Missing metadata remains unavailable; duplicate names retain distinct item IDs.

Listing uses `MCCAzureFunctions_GetPlayFabUgcItems` from service discovery with the account's entity ID in both `CreatorEntityId` and `UserEntityId`. Item details use the discovered `MCCAzureFunctions_GetPlayFabUgcItem` route and the existing entity-token authentication. Older saved service configurations receive the known read-only route defaults; supplied routes still pass service URL validation.

The recovered native owned-list request and parser have no pagination loop. The browser checks the returned count against the item array and marks incomplete or unrecognized continuation responses explicitly. Failed refreshes retain earlier results with an error. An unverified response never becomes a misleading empty share. Native evidence and framing findings are summarized in [the File Share specification](../research/FILESHARE_SPEC.md).

Downloading refreshes the selected catalog item, checks its identity and account ownership, and follows its map-data content URL on a recognized HTTPS host. No remote catalog changes or publication-history writes are made. A native save dialog controls the destination and replacement of an existing file; a failed download or save leaves no completed-looking partial file. The result includes **Reveal in Finder**.

Download validation checks the BLF map envelope independently of the Reach-only upload parser. Halo 3, Reach, Halo 4, and H2A use different map chunk versions; Halo 3 can use an `athr` header without Reach's `chdr`. Payload bytes and existing provenance trailers are preserved. The client does not fabricate signatures. A SHA-256 identifies the saved content; it does not certify the map's gameplay behavior. File structure, byte preservation, editor compatibility, and in-game acceptance are distinct checks.

## Deleting a map from File Share

**Delete from File Share…** captures the selected map's title, game, account, and catalog ID. The native confirmation defaults to Cancel. Account changes, publishing, downloading, and configuration changes are blocked from confirmation through completion. Deletion affects the shared catalog item; local downloaded files remain on disk. The app has no undo action.

Service discovery resolves `PlayFab_DeleteDraftItem` to MCC's `DeletePlayFabUgcItem` wrapper. A fresh owned-map lookup precedes one POST containing `ItemId` and authenticated by `X-EntityToken`. The detail route honors the native `PlayFab_GetPublishedItem` discovery key, retaining compatibility with older configuration aliases. Deletion does not fall back to a direct PlayFab API or retry a mutation. Even same-origin redirects are disabled for this request, because a redirect could replay the POST.

MCC's recovered completion callback treats successful transport as acknowledgement without requiring a JSON success field. This app additionally checks the account's complete raw item list, including non-map content types, or exact item-not-found evidence before reporting confirmed absence. Incomplete responses, stale entries, lost replies, cancellation after dispatch, and unreadable responses remain uncertain. Explicit Refresh can reconcile a pending uncertain result using reads alone.

Confirmed absent IDs are suppressed from stale list responses for the current account. Local receipt cleanup targets only the same account and catalog ID, preserving other items and any other publication of the same map bytes. Cleanup persists before retiring the in-memory receipt; a disk failure retains protection and is reported separately from remote success. Refresh can retry pending local cleanup without deleting again.

A private local intent journal is saved before mutation. Pending work survives restart and account switching, without storing credentials or automatically replaying deletion. Restored intents require fresh read-only confirmation on Refresh before any receipt is retired. If the journal cannot be saved or read safely, deletion is unavailable until that local problem is resolved.

The exact native contract, tests, and live-validation limits are in [DELETION_SPEC.md](../research/DELETION_SPEC.md).

## Build and verify

From the repository folder:

```sh
scripts/test-native.sh
scripts/build-app.sh
scripts/install-app.sh
```

The installer copies the app to the current user's Applications directory unchanged, without replacing an unrelated bundle, so both copies share one signature. The build is signed with the hardened runtime. It uses a "Developer ID Application" or "Apple Development" certificate when one is in the keychain (a free Apple Development certificate is available from Xcode > Settings > Accounts), or `MCC_SIGNING_IDENTITY`; otherwise it is ad-hoc signed. With a certificate the signature stays the same across builds and macOS stops asking after updates. The installed copy avoids file-provider attributes added by the synced Documents folder.

The native test script runs Reach map inspection, authentication, publication, publication-history, File Share, deletion, and durable deletion-journal suites. These cover PKCE and request signing, callback rejection, metadata, core/suffix framing, credential binding, endpoint validation, receipt restoration, duplicate protection, share parsing, map download validation, deletion reconciliation, and recovery after local persistence failures. A conditional runner works with Command Line Tools that do not include XCTest. Standard XCTest branches remain available when that framework is installed.

The inspection CLI can be built independently:

```sh
swift build --product mcc-publish
.build/debug/mcc-publish inspect /absolute/path/to/map.mvar
.build/debug/mcc-publish list
.build/debug/mcc-publish download ITEM_ID /absolute/path/to/map.mvar
```

The list and download commands reuse the app's saved sign-in without changing it or publication history. The CLI refuses to overwrite an existing destination.

Later Blender integration can open this app with the existing exported file. The exporter repository was inspected read-only; none of its existing changes were replaced.
