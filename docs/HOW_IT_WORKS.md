# How MCC Forge Publisher works

A standalone native macOS app for publishing Halo Reach Forge maps exported from Blender to MCC File Share. The app uses SwiftUI, WebKit, Foundation, CryptoKit, macOS Keychain and system zlib. It does not run Windows binaries, CrossOver, .NET, Node or Python.

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

## Build and verify

From the repository folder:

```sh
scripts/test-native.sh
scripts/build-app.sh
scripts/install-app.sh
```

The installer copies the app to the current user's Applications directory unchanged, without replacing an unrelated bundle, so both copies share one signature. The build is signed with the hardened runtime. It uses a "Developer ID Application" or "Apple Development" certificate when one is in the keychain (a free Apple Development certificate is available from Xcode > Settings > Accounts), or `MCC_SIGNING_IDENTITY`; otherwise it is ad-hoc signed. With a certificate the signature stays the same across builds and macOS stops asking after updates. The installed copy avoids file-provider attributes added by the synced Documents folder.

The current test script passed the 10-case Reach suite, authentication checks, 10-case publication suite, and 6-case publication-history suite. These cover map inspection, PKCE and request signing, callback rejection, metadata, core/suffix framing, credential binding, endpoint validation, receipt restoration and duplicate protection. A conditional runner works with Command Line Tools that do not include XCTest. Standard XCTest branches remain available when that framework is installed. The installed app's local code signature was also verified.

The inspection CLI can be built independently:

```sh
swift build --product mcc-publish
.build/debug/mcc-publish inspect /absolute/path/to/map.mvar
```

Later Blender integration can open this app with the existing exported file. The exporter repository was inspected read-only; none of its existing changes were replaced.
