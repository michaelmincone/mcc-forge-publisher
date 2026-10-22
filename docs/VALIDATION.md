# Validation

Date: 2026-10-21. Scope: Halo: Reach maps and gametypes in MCC Shared Files, including search and bulk upload/download/delete. Xbox-local Private Files are excluded by the user's amended instructions and are not an open requirement.

## Current implementation

| Requirement | Current state and evidence |
| --- | --- |
| Shared maps and gametypes | Implemented in the core, app, and CLI. Native category mappings were recovered from MCC/Reach; 63 real Reach gametype files parsed successfully. |
| Shared search and bulk upload/download/delete | Implemented with content filters, visible-selection binding, per-file results, cancellation between operations, and exact account/item checks. |
| Interrupted upload recovery | Durable account/entity/kind/core-hash/upload-ID intents precede submission. Refresh reconciles matching owned catalog entries; explicit review is required to allow a new attempt after an uncertain result. |
| Delete recovery | Durable intents and read-only reconciliation retain uncertain results. Confirmed deletion retires only the matching receipt. |
| Remove Check Download | Removed from the app and automatic post-upload flow. Legacy receipt fields remain readable; separate CLI research diagnostics remain available. |
| Streamlined UI | Final single-library app installed, launched, and visually inspected with the signed-in account. The actual app uploaded and bulk-downloaded the approved map/gametype pair; search, kind filters, visible selection, and the delete confirmation/cancel flow were exercised. |

## Completed offline checks

- Core, history, and deletion suites: 78 counted cases, plus authentication offline checks.
- App model: 8 cases, including single-library filtering and selection, actual temporary-disk failures, repair, retained unsaved receipts, journal cleanup, and history reload.
- Shared upload journal: 4 cases covering restart protection, exact identity matching, failed persistence, bounded records, and credential exclusion.
- `scripts/test-native.sh` passed before the shared-only UI simplification. After removing the Private Files category and collection state, `scripts/test-library-model.sh` passed the updated 8 model and 4 upload-journal cases.
- `swift build --product mcc-publish` passed.
- `scripts/build-app.sh` passed after the shared-only UI simplification and produced a signed bundle; its Info.plist declares map/gametype document support. No GUI was launched or installed during this build check.
- The final single-library build is installed at `~/Applications/MCC Forge Publisher.app`. Signing and Info.plist validation passed; the installed executable matches the build output, SHA-256 `7973ac5d81455653998fd022f19c8909907ff807a3bb64a370c2385f26aa629b`. Its actual connected window, upload queue, bulk download, and final reconciled library were inspected.
- Previous installed bundle retained under ignored `build/previous-installed/`.
- `git diff --check` passed. Preexisting research and build-script edits were preserved.

## Reverse engineering

REA 6.7.0 and Ghidra 12.1.4 with OpenJDK 21.0.13 were installed and used for bounded static analysis. Game binaries were inspected without running MCC or modifying them. See [GAMETYPE_PROTOCOL.md](GAMETYPE_PROTOCOL.md) and [PRIVATE_FILES_PROTOCOL.md](PRIVATE_FILES_PROTOCOL.md).

The read-only legacy cloud probe found historical records. Official migration documentation establishes why those records cannot represent today's Private Files. Legacy codecs, auth experiments, read clients, and mutation prototypes are archived under ignored `investigation/legacy-cloud-prototype/`, outside the shipping package. No deprecated-cloud private upload or deletion was performed. Shared Files live validation is tracked separately below.

## Completed live Shared Files checks

The user authorized uploading, downloading, and deleting only two disposable test copies. A complete owned-catalog baseline of 130 existing IDs was captured before the uploads, including the user's `Publisher Private Probe`. The installed app submitted both files once in a single bulk queue. MCC accepted them immediately and listed both after approximately five minutes; no upload was repeated during that delay.

| Test copy | New catalog ID | Download size | Source and downloaded SHA-256 |
| --- | --- | --- | --- |
| Publisher Storage Test (Reach gametype) | `0a50ed77-c098-4358-a2bc-1990fb2928d3` | 21,289 bytes | `d23b5f3839573e3767ee934c6aa9312fdbf99549bd5b3c64250ded2b5ccdd4c5` |
| Publisher Storage Test Map (Reach map) | `64277b47-cd21-436b-bbcc-8085b3138b93` | 29,481 bytes | `4e756c7c803ecc08c6c3135c1c9d4e004596eb4f9e05dc3b606b73eec2e087c4` |

- The app's bulk download saved both files to a new directory; both matched their source bytes exactly. An independent validation helper also adopted the app's exact receipts, checked fresh owned metadata and upload identity, and verified the downloads.
- Search located exactly the two test copies. Maps/Gametypes filters retained only visible selection and disabled actions when no visible files were selected.
- The app's bulk-delete confirmation displayed the exact two titles, kinds, and catalog IDs; Cancel was exercised. The final destructive GUI submission was not exercised. The authorized cleanup helper used the shipping core deletion service to delete each exact test ID once. Initial responses were uncertain; subsequent read-only reconciliation confirmed both absent without repeating either deletion.
- The final complete catalog check retained all 130 baseline IDs, including `Publisher Private Probe`, and confirmed both test IDs absent. No baseline item was a cleanup target.
- To exercise app recovery after helper cleanup, two exact local deletion intents were staged through the app's journal API while the app was closed. On restart, explicit Refresh performed read-only reconciliation, cleared both intents, and retired exactly their two publication receipts. History changed from 52 to 50 receipts; every unrelated receipt remained identical. The journal ended empty.
- Final UI checks showed 130 Shared Files, one result for `Publisher Private Probe`, and zero results for `Publisher Storage Test`. The app was left open with its search cleared.

Local evidence is retained under ignored `investigation/private-write-test/`: `live-state.json`, `app-bulk-download-evidence.json`, `final-recovery-evidence.json`, exact downloaded fixtures, and the pre-recovery history backup. These records contain account-specific metadata and are not shipping resources. Screenshots are under ignored `build/`: `live-upload-queue-ready.png`, `live-bulk-upload-success.png`, `live-bulk-download-success.png`, and `live-final-shared-library.png`.

## Runtime limit

MCC/Xbox import, recognition, and gameplay were not exercised. Native parsing, successful catalog transport, and byte-identical downloads establish the publisher workflow; they do not prove console acceptance of a particular map or gametype. The disposable fixtures were used for storage validation.

Private-file management is intentionally outside this scope. The shipping app contains no Private Files category, unsupported-provider placeholder, legacy-cloud provider, or private mutation path.
