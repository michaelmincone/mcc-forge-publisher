# MCC Forge Publisher

A Mac app that uploads a Halo: Reach Forge map (`.mvar`) to your Halo: The Master Chief Collection File Share. Once it's there, you open File Share in MCC on your Xbox and download the map, with no Windows PC needed.

## How you use it

1. Open **MCC Forge Publisher** and choose **Sign in with Microsoft**. Microsoft's own sign-in window opens; the app never sees your password.
2. Drag a `.mvar` map onto the app, or click **Choose Map**. Its name and description show up.
3. Click **Upload to File Share**. The app uploads the map, then downloads it back and checks it arrived unchanged.
4. On your Xbox, open MCC, go to your File Share and download the map.

Before signing in, fully quit MCC on your Xbox (including Quick Resume). Xbox lets an account use MCC on one device at a time, and the app signs in as MCC, so Xbox refuses it while the game is open (the app shows error `0x8015DC1E`).

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

## Good to know

- Your original map file is never changed.
- It handles standard Halo: Reach multiplayer map variants on the stock maps.
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
