# Reach gametype support

Fresh uploads accept compiled Reach `.bin` and `.game` BLF files. Editable
`.megalo` scripts must first be compiled in ReachVariantTool. Maps continue to
use `.mvar`. Other MCC titles' map and gametype downloads use a separate BLF
validator and preserve the received bytes.

## Recovered native metadata

The installed MCC executable SHA-256 is
`be70d6dcd1a884f10ceb342a7a2dcb35ee0fa43181b66a1d19c3d830e9834691`.
Bounded Ghidra analysis, without executing or modifying the game, established:

- `0x140592f04`: game subtype calls the common metadata serializer and writes
  string-valued `GameCategory`; it writes `IsForgeVariant` only when true.
- `0x140593048`: gametype tags contain the game and unified category, with no
  built-in map descriptor.
- `0x1404824e0`: content type `GameVariant`; tags are the game name, category
  name, and platform name. The traced PC platform is `2` / `PC`.
- `0x1420858a0`: unified category numbers map to `GameCategory_*` tag strings.
- Reach vtable `0x180995048`, category accessor `0x180067f04`: the category
  comes from the multiplayer body, with the translation below.
- Reach Forge accessor `0x180067f50` compares engine type with `1`.

The private analysis artifacts live under the ignored local directory
`investigation/private-gametypes-20261021/`. They are not game files that should
be redistributed with the source.

| Reach body category | MCC category | Category tag suffix |
| ---: | ---: | --- |
| 0 | 0 | CTF |
| 1 | 1 | Slayer |
| 2 | 2 | Oddball |
| 3 | 3 | KOTH |
| 4 | 4 | Juggernaut |
| 5 | 15 | Territories |
| 6 | 16 | Assault |
| 7 | 5 | Infection |
| 8 | 14 | VIP |
| 9 | 23 | Invasion |
| 10 | 21 | Stockpile |
| 11 or 16 | 24 | ActionSack |
| 12 | 7 | Race |
| 13 | 22 | Headhunter |
| 30 | 26 | PreGameWarmUp |

Forge engine `1` with category `-1` maps to `13` / `GameCategory_Sandbox`.
Firefight engine `4` maps to `20` / `GameCategory_Firefight`. Unknown categories
are rejected for fresh catalog upload, rather than assigned an invented mode.

For example, a fresh user-compiled Vanishing Floor variant has body category
`16`. Its metadata is `ContentType = GameVariant`, `GameEngine = "6"`,
`GameCategory = "24"`, and tags `HaloReach`, `GameCategory_ActionSack`, `PC`.
It does not receive `BuiltInMapId` or `IsForgeVariant`.

Fresh metadata follows the existing map publication identity contract: a new
lowercase UUID is the filename; `CreatorId` is the authenticated uploader;
source author and editor XUIDs remain separate. The request contains the BLF
core through `_eof`, followed by the metadata JSON. Local padding is omitted.
Nonzero physical trailers block fresh publication because their provenance
cannot be safely transferred by this fresh-upload path.

## Reader and verification scope

The reader checks bounded BLF chunks, Reach content headers, MPVR versions
`50.1`/`54.1`, known multiplayer encoding versions, and the actual SHA-1 input
framing. RVT exports use the Reach salt and a little-endian stored length;
installed MCC variants also exercise the big-endian unsalted form.

The UGC header duplicates the category, but the native accessor reads the
separate multiplayer category. The reader traverses the custom options,
conditional traits, loadouts, option values and bounded string tables to reach
that field. It never substitutes the UGC copy when they disagree. This prefix
layout was checked against the local ReachVariantTool native format sources.
It is not a full Megalo interpreter or proof that the game can execute a script.

Offline inspection passed for 63 real compiled files: 54 installed Reach
variants, five RVT examples, blank multiplayer/Forge/Firefight exports, and the
user's Vanishing Floor export. The ignored `reach-corpus-inspection.json`
records their hashes and observed category mappings. Native test coverage adds
Unicode metadata, distinct UGC/body categories, every supported mapping,
request framing, source-byte preservation, unknown categories, corruption,
wrong games and types, provenance trailers, download-kind checks and atomic
`.bin` saving.

These checks establish parsing and request construction. A successful service
upload, subsequent catalog listing/download, and an MCC/Xbox import are
separate runtime checks; the offline corpus does not establish them.
