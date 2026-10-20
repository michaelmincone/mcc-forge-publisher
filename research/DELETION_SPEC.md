# Delete an owned File Share map

Implemented on 2026-10-18. Deletion is an explicitly confirmed action on one
owned catalog map. No live shared map is deleted just to test this feature.

## Native request evidence

The official service document defines `PlayFab_DeleteDraftItem` as
`/api/DeletePlayFabUgcItem` on `mcc-production.azurefd.net`. Use this discovered
MCC wrapper rather than inferring a direct PlayFab Catalog operation from the
logical name. Saved service settings without the new field receive this known
default; supplied endpoints retain HTTPS/host validation.

```text
POST <discovered PlayFab_DeleteDraftItem URL>
X-EntityToken: <signed-in account entity token>
Accept: application/json
Content-Type: application/json

{"ItemId":"<confirmed catalog item ID>"}
```

Native constructor `0x140555670` captures the supplied catalog ID. Execute
`0x140555734` constructs the JSON body and request headers. Callback
`0x140560dac` checks cancellation and transport HRESULT; a nonnegative result
sets its success flag. No required JSON success property was found. Therefore
an empty successful response is an acknowledgement, not independent proof of
removal.

Evidence is pinned to installed MCC executable SHA-256
`be70d6dcd1a884f10ceb342a7a2dcb35ee0fa43181b66a1d19c3d830e9834691`,
image base `0x140000000`. Local-only constructor/execute Ghidra output,
completion disassembly, string constants, and manifest are preserved under
`research/fileshare-delete-native/`. The bounded decompilation succeeded, but
the following Ghidra project save encountered low disk space; the derived
artifacts, not an updated saved project, are the evidence. Game binaries were
read without execution or modification.

The real published-item discovery key is `PlayFab_GetPublishedItem`. The
client now honors it while retaining the older configuration alias and route
default used by earlier builds. Its authentication matches the already
working item-lookup flow. The authority's name alone is not evidence that a
second session-ticket header is mandatory.

## Scope and outcome rules

The UI captures the selected item's immutable ID and account before showing
the confirmation. Cancel is default and dispatches no request. Conflicting
actions remain disabled through confirmation, request, reconciliation, and
refresh. Local downloaded files are not removed. No undelete or provider
recovery contract has been established; the app offers no undo.

Before mutation, check account XUID/entity binding and perform a fresh detail
lookup. The detail must identify the same owned `MapVariant`; identity, type,
authorization, or ownership mismatches cannot authorize a request. If the
entry is already unavailable, a valid complete own-list can establish that
it was already absent without sending a deletion.

Send the mutation at most once. Do not follow redirects, rotate credentials,
switch endpoints, or retry POST on error. Cancel before dispatch sends
nothing; cancellation or a lost reply after dispatch can leave an uncertain
outcome. Responses and URLSession errors are never displayed verbatim.

After dispatch, inspect the complete raw owned-item list before filtering by
content type. Confirmed absence requires valid count/envelope/ownership and
no continuation or malformed entries. A still-present ID of another content
type is still present. If a complete list cannot establish the state, exact
provider `ItemNotFound` evidence may establish absence. A generic HTTP 404,
missing `Item`, malformed body, or failed list does not.

Only confirmed absence produces a `deleted` or `alreadyAbsent` result and
permits receipt cleanup. Explicit refusals are reported separately. Stale
presence or unreadable state after dispatch stays uncertain even after a
successful transport acknowledgement. Explicit Refresh reconciles pending
uncertain results using reads alone; it does not resend the mutation.

## Publication receipts

Retire entries matching both account XUID and exact catalog ID after a
confirmed-absent result. Preserve unrelated accounts, items, and any second
publication of the same core bytes. Persist the updated document atomically
before changing in-memory receipts. A failed cleanup keeps duplicate-upload
protection, reports remote success separately, and can be retried on Refresh.
Uncertain or refused deletions cannot remove receipts.

Confirmed-absent IDs stay suppressed from stale browser results for the
current account. Before mutation, persist an account-scoped intent containing
only the selected item's identity and display metadata in a private local
journal. If the journal cannot be saved, no deletion is dispatched. Keep an
intent until receipt cleanup succeeds or a known refusal/pre-dispatch failure
is handled. Other accounts' intents are preserved.

On restart or account switch, restore pending intents as uncertain targets.
The journal is never trusted as proof of remote deletion and never triggers a
mutation. Explicit Refresh performs fresh read-only reconciliation before
receipt cleanup. This also recovers a confirmed deletion whose local cleanup
failed before restart. Corrupt journals block new deletion until they can be
read safely; browsing and downloading remain independent.

## Verification boundaries

Mocked transport tests cover account binding, exact request framing, one
mutation, refusals, malformed/empty acknowledgements, cancellation, lost
responses, raw-list completeness, read-only reconciliation, configuration
migration, and targeted receipt cleanup. The native regression runner and
release build are the required checks. GUI validation exercises the actual
Delete confirmation and Cancel path with the signed-in share. A real
destructive end-to-end deletion requires a user-chosen map and confirmation;
it is not claimed by fixture tests or static protocol evidence.

The final native regression run passed: 15 deletion cases, eight durable
journal cases, 10 publication-history cases (including targeted retirement and
failure recovery), and all existing Reach/auth/publication/download checks.
The release build and installed code signature also passed verification; the
installed executable's SHA-256 matched the built executable.

The live public service configuration returned HTTP 200 and confirmed the
deletion, detail, and listing routes above. The installed app restored the
existing session and displayed 65 shared maps. The native Delete dialog showed
the selected map's exact title, game, and catalog ID, with Cancel as default.
Cancel returned to the same selected map with 65 items, unchanged publication
history bytes, and no deletion intent created. No live map was deleted; backend
acceptance of an actual deletion remains untested until the user chooses one.
