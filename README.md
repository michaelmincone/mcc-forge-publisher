# MCC Forge Publisher

A Mac app for uploading Halo: Reach Forge maps (`.mvar`) to your Halo: The Master Chief Collection File Share, browsing your shared maps, and downloading them to your Mac. No Windows PC is needed.

## How you use it

1. Open **MCC Forge Publisher** and choose **Sign in with Microsoft**. Microsoft's own sign-in window opens; the app never sees your password.
2. Drag a `.mvar` map onto the app, or click **Choose Map**. Its name and description show up.
3. Click **Upload to File Share**. The app uploads the map, then downloads it back and checks it arrived unchanged.
4. On your Xbox, open MCC, go to your File Share and download the map.

Before signing in, fully quit MCC on your Xbox (including Quick Resume). Xbox lets an account use MCC on one device at a time, and the app signs in as MCC, so Xbox refuses it while the game is open (the app shows error `0x8015DC1E`).

## Download your shared maps

1. Sign in and open **File Share**.
2. Click **Refresh** to load the maps on that account's share, including maps uploaded from Xbox, MCC on PC, or another tool.
3. Select a map, click **Download**, and choose where to save its `.mvar` file.
4. Use **Reveal in Finder** to find the saved file.

You do not need the original map file or a receipt from this app. The browser shows map variants across MCC titles; uploading still uses the existing Reach validation. Download checks verify the file's structure and saved bytes, rather than whether a particular game or editor can load it. An incomplete listing is explicitly marked; it is never reported as an empty or complete share.

## Delete a shared map

1. Open **File Share** and select the map you want to remove.
2. Click **Delete from File Share…**. Check the map's name, game, and item ID in the confirmation.
3. Choose **Delete from File Share** to remove the shared copy, or **Cancel** to keep it.

The app cannot undo deletion. Download a backup first if you want one. Files already saved on your Mac are kept.

The app checks that the map belongs to the signed-in account and verifies its absence after sending the request once. If the outcome is uncertain, use **Refresh** to check again; the app does not repeat the deletion automatically. Confirmed deletion retires only that map's matching upload receipt, allowing it to be published again. If receipt cleanup fails, Refresh retries the local cleanup while keeping duplicate-upload protection.

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

There is also a command-line tool for checking a map file without uploading it:

```bash
swift build --product mcc-publish
.build/debug/mcc-publish inspect /path/to/map.mvar
```

The CLI can also list your share and download a map using the app's saved sign-in, without uploading anything:

```bash
swift build --product mcc-publish
.build/debug/mcc-publish list
.build/debug/mcc-publish download ITEM_ID /absolute/path/to/map.mvar
```

The download command refuses to replace an existing file. The app's save dialog lets you choose whether to replace one.

## Good to know

- Your original map file is never changed.
- Uploading handles standard Halo: Reach multiplayer map variants on the stock maps. Downloading does not require the Reach upload parser or a previous publication receipt.
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
