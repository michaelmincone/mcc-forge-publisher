# MCC Forge Publisher

A native Mac app for managing Halo: Reach maps (`.mvar`) and compiled gametypes (`.bin`) on your MCC account. Search Shared Files and upload, download, or delete individual files or selections.

## Manage your library

1. Open **MCC Forge Publisher** and choose **Sign in with Microsoft**. Complete Microsoft's sign-in window.
2. Choose **Shared Files** in the sidebar, then **Refresh**.
3. Search by name, description, game, type, or item ID. Use the **Maps** and **Gametypes** filters to narrow the results.
4. Select files with Command or Shift, then choose **Download**. A single file uses a save dialog; a selection goes into a new folder so existing downloads stay intact.
5. Use **Reveal in Finder** to open the saved result.

Before signing in, fully quit MCC on your Xbox, including Quick Resume. Xbox permits an account to run MCC on one device at a time; the publisher uses MCC's sign-in, and the game being open can cause error `0x8015DC1E`.

## Upload maps and gametypes

1. Choose **Shared Files**, then **Upload Files**, or drag several Reach maps and compiled gametypes into the window.
2. Review the upload queue and choose **Upload**. Each file shows its result.
3. Choose **Cancel remaining** to stop after the current file. Uploads are never retried automatically.
4. Open MCC on Xbox to download the published files from Shared Files.

MCC may take a few minutes to add an accepted upload to its File Share listing. Use **Refresh** to check for it; the saved receipt prevents submitting the same file again while it is appearing.

The app saves publication receipts to prevent duplicate uploads. It no longer has a Check Download action or an automatic download after uploading. A connection failure after submission can leave an uncertain result. Shared upload recovery records survive restarts and block duplicate submissions. **Refresh** recovers a matching upload by its unique upload ID; **Review…** lets you inspect the library and explicitly allow a fresh attempt if needed. That action only resets the queue entry and never submits it automatically. **Retry failed** resets known failures while keeping uncertain attempts protected.

## Delete shared files

Select one or more files in **Shared Files**, choose the trash button, and review the named files in the confirmation. Cancel is the default. Shared deletion checks ownership before the request and verifies absence afterward. An uncertain result is retained for read-only checking on **Refresh**; it never triggers an automatic second deletion.

Deleting a shared copy leaves existing downloads on your Mac. Confirmed absence retires only the matching publication receipt. Recovery records survive app restarts and account changes.

An incomplete listing is marked explicitly. Structure and byte checks do not establish whether a file loads or plays correctly in MCC; verify that in the game.

## What you need

- A Mac running macOS 14 or later
- The Command Line Tools with Swift 6 (`xcode-select --install`; full Xcode is not needed)
- A Microsoft account that owns Halo: The Master Chief Collection

## Set it up with AI

Open [Claude Code](https://claude.com/claude-code), or another AI assistant that can run commands on your Mac, and paste this:

```text
Set up MCC Forge Publisher from https://github.com/michaelmincone/mcc-forge-publisher on my Mac.
Clone it and read README.md and docs/HOW_IT_WORKS.md. Make sure the Command Line Tools are installed,
run scripts/test-native.sh, then scripts/build-app.sh and scripts/install-app.sh, and tell me where the
app ended up. Don't sign in or upload anything for me; I'll do that in the app.
```

## Set it up by hand

```bash
xcode-select --install
git clone https://github.com/michaelmincone/mcc-forge-publisher.git
cd mcc-forge-publisher
scripts/test-native.sh
scripts/build-app.sh
scripts/install-app.sh
```

The app is installed as `~/Applications/MCC Forge Publisher.app`. Your sign-in is saved in the macOS Keychain. Each new build has a new signature, so after you rebuild, macOS asks once for your Mac password to let the new build read the saved sign-in; choose **Allow** or **Always Allow**.

There is also a command-line tool for inspecting a Reach map or gametype without uploading it:

```bash
swift build --product mcc-publish
.build/debug/mcc-publish inspect /path/to/map.mvar
.build/debug/mcc-publish inspect /path/to/gametype.bin
```

The CLI can also list your share and download a map using the app's saved sign-in, without uploading anything:

```bash
swift build --product mcc-publish
.build/debug/mcc-publish list
.build/debug/mcc-publish list "survival"
.build/debug/mcc-publish download ITEM_ID /absolute/path/to/map.mvar
.build/debug/mcc-publish download ITEM_ID /absolute/path/to/gametype.bin
```

The download command refuses to replace an existing file. The app's save dialog lets you choose whether to replace one.

## Good to know

- Original map and gametype files remain unchanged.
- Fresh uploads focus on Halo: Reach. Catalog downloads retain support for other MCC map and gametype envelopes; they do not require an earlier publication receipt.
- It never retries an upload by itself. If a connection drops mid-upload, check your File Share before trying again, because the upload may have gone through.
- [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) explains the sign-in, the upload protocol and what has been tested, and [research/](research/) holds the protocol specs.

## Related tools

- [Mjolnir Forge Editor for Mac](https://github.com/michaelmincone/mjolnir-forge-editor) builds and edits Forge maps in Blender.
- [ReachVariantTool for Mac](https://github.com/michaelmincone/halo-reach-variant-tool) edits Halo: Reach game types.

## Credits and license

- Written by [michaelmincone](https://github.com/michaelmincone) with Claude Code.
- The Microsoft and Xbox sign-in flow was derived in part from HaloCache's MIT-licensed [halo-mcc-auth](https://github.com/HaloCache/halo-mcc-auth); its license is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

No license has been chosen for this app yet, so it is all rights reserved for now.

This is an unofficial tool. It is not made, endorsed or supported by Microsoft, Xbox or 343 Industries, and it uses File Share the same way MCC does, at your own risk. Halo and Halo: The Master Chief Collection are trademarks of Microsoft Corporation.
