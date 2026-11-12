# Chatmail core feature backlog

Audit date: 2026-09-25. Baseline: installed JSON-RPC core **2.62.0**,
upstream `main` at `7e070efc28f576a187226166434e3efe336f8829`, and Parla
at `6681d8a`.

This backlog covers remaining user-facing features and integration gaps.
Most capabilities below already existed before core 2.55; the entries for
APIs introduced after that release identify their versions explicitly.
All listed RPC methods are available in core 2.62.0. The additional
`PinnedMessagesChanged` JSON-RPC event on audited `main` is already handled.

Task IDs are stable: keep an ID when its scope is refined, and mark completed
entries Done rather than renumbering them. Each implementation should have a
separate commit; large tasks can use several commits referencing the same ID.

Priorities: **P1** fixes an existing limitation or replaces a workaround;
**P2** adds useful core-backed functionality; **P3** needs a larger subsystem,
external support, or a product decision. Priorities are implementation
recommendations, not release commitments.

## Task index

| ID | Priority | Status | Task |
| --- | --- | --- | --- |
| [CORE-001](#core-001-full-history-conversation-search) | P1 | Done | Full-history conversation search |
| [CORE-002](#core-002-search-messages-across-chats) | P2 | Done | Search messages across chats |
| [CORE-003](#core-003-retry-failed-messages) | P1 | Done | Retry failed messages |
| [CORE-004](#core-004-detailed-read-receipts) | P2 | TODO | Detailed read receipts |
| [CORE-005](#core-005-channel-view-counts) | P2 | TODO | Channel view counts |
| [CORE-006](#core-006-native-saved-messages) | P2 | TODO | Native Saved Messages |
| [CORE-007](#core-007-export-and-restore-backup-files) | P2 | TODO | Export and restore backup files |
| [CORE-008](#core-008-keep-sending-while-work-is-pending) | P2 | TODO | Keep sending while work is pending |
| [CORE-009](#core-009-relay-provided-app-update-information) | P3 | TODO | Relay-provided app update information |
| [CORE-010](#core-010-webxdc-realtime-channels) | P2 | Done | Webxdc realtime channels |
| [CORE-011](#core-011-voice-and-video-calls) | P3 | TODO | Voice and video calls |
| [CORE-012](#core-012-location-messages-and-live-sharing) | P3 | TODO | Location messages and live sharing |
| [CORE-013](#core-013-contact-cards-and-vcard-importexport) | P2 | Done | Contact cards and vCard import/export |
| [CORE-014](#core-014-native-forwarding-between-profiles) | P1 | TODO | Native forwarding between profiles |
| [CORE-015](#core-015-group-and-channel-descriptions) | P2 | TODO | Group and channel descriptions |
| [CORE-016](#core-016-core-controlled-composer-availability) | P1 | TODO | Core-controlled composer availability |
| [CORE-017](#core-017-complete-contact-freshness-presentation) | P3 | TODO | Complete contact freshness presentation |
| [CORE-018](#core-018-network-change-and-resume-notification) | P2 | TODO | Network change and resume notification |
| [CORE-019](#core-019-webxdc-activity-links) | P2 | TODO | Webxdc activity links |
| [CORE-020](#core-020-persistent-profile-order) | P3 | TODO | Persistent profile order |

Suggested next sequence: CORE-014, CORE-016, then CORE-004/CORE-005.

## CORE-001: Full-history conversation search

**Status:** Done (2026-09-27).

**Implemented:** Conversation search uses core's `search_messages` across the
full history, with a match counter, previous/next buttons, and Enter/Shift+Enter
navigation. Typing is debounced, and replies for superseded queries, chats, or
profiles are discarded. Deleted results are rechecked before navigation.

Distant jumps load at most 61 surrounding messages instead of every intervening
page. Scrolling can extend that window in either direction. Closing search
restores the original reading position or follows the newest messages again.
Only messages actually visible after scrolling settles can be marked seen.

**Validation:** [RPC regression tests](tests/message_search_test.vala) cover
query debounce, stale replies, profile changes, cancellation, errors, and
Unicode snippets. [History tests](tests/message_history_test.vala) check the
bounded context. The optional [GTK test](tests/search_ui_test.py) exercises
real conversation widgets against an offline 2,000-message fixture, including
stale context loads, deleted results, restoration, and off-screen read state.

**Entry points:** [conversation_view.vala](src/conversation_view.vala),
[message_history.vala](src/message_history.vala),
[message_search.vala](src/message_search.vala), [rpc_client.vala](src/rpc_client.vala).

## CORE-002: Search messages across chats

**Status:** Done (2026-09-27).

**Implemented:** The existing sidebar search field searches chat names and
message history together. Message results appear below matching chats, with
plain-text excerpts around the query, chat names, authors, dates, and archived
status. The heading identifies the selected profile. There are no search-mode
buttons.

Global search calls `search_messages` with a null chat ID and loads
`message_ids_to_search_results` in pages of 50. The 1,000-result cap is shown
as `1,000+`, and the keyboard-accessible Load more action focuses the first new
result. Opening a result revalidates it and navigates directly to its chat,
including archived chats absent from the sidebar. Profile/query changes
invalidate pending result loads and navigation.

**Validation:** The [GTK test](tests/search_ui_test.py) checks that activated
results are visible and highlighted when switching chats or jumping within a
chat. It also covers archived results, all 1,000 result positions,
deleted-result recovery, and profile switches. The isolated
[native core test](tests/core_search_test.py)
checks both RPCs, Unicode matching, archived metadata, profile isolation, and
unchanged read state without configuring transport or starting network I/O.

**Entry points:** [window.vala](src/window.vala),
[search_results_view.vala](src/search_results_view.vala),
[message_search.vala](src/message_search.vala),
[conversation_view.vala](src/conversation_view.vala), [rpc_client.vala](src/rpc_client.vala).

## CORE-003: Retry failed messages

**Status:** Done (2026-09-26).

**Implemented:** Retry is available in the context menu and Message Details
for failed outgoing messages, including attachments. It calls native
`resend_messages` with the original message ID and lets core reuse its stored
content and attachment. The message model parses core's `error` field, and
Message Details shows it as plain text. Retry errors also appear in a toast
inside the dialog when it is open.

Eligibility is rechecked against core before retrying; incoming messages,
info messages, drafts, pending sends, and delivered/read messages are excluded.
Concurrent activations are guarded, requests retain the originating account,
and stale callbacks cannot update another profile. The row and open details
refresh after the attempt, including when core reports an error; Retry
disappears when the message is no longer failed.

**Validation:** [RPC regression tests](tests/message_retry_test.vala) cover
eligibility, text/attachments, stale state, concurrent activation, account
switches, and error recovery. The optional
[GTK integration test](tests/message_retry_ui_test.py) checks the dialog,
literal error text, visible failure toasts, and state refresh. The isolated
[native core test](tests/core_retry_test.py), verified with core 2.62.0, checks
failed retries without a configured transport, preserving original IDs,
stored attachments, and failure reasons. Successful queueing is covered by
the offline RPC fixture; live relay delivery is not exercised.

**Entry points:** [message_actions.vala](src/message_actions.vala),
[message_details_dialog.vala](src/message_details_dialog.vala),
[rpc_client.vala](src/rpc_client.vala), [rpc_parsers.vala](src/rpc_parsers.vala),
[models.vala](src/models.vala).

## CORE-004: Detailed read receipts

**Gap:** Delivery/read ticks are implemented, but Message Details does not show
which contacts sent receipts or when.

**Implement:** Load `get_message_read_receipts`, resolve contact IDs, and add a
Read by section with timestamps. Refresh an open details view when relevant
receipt events arrive. Present only information core returns; absence of a
receipt does not establish that someone has not read a message.

**Done when:** Direct and group messages show available receipts accurately;
missing/deleted contacts and an empty receipt list are handled. Switching
profiles or closing the dialog invalidates outstanding loads. Channel reader
identities follow core's restrictions, with channel counts covered by CORE-005.

**Entry points:** [message_details_dialog.vala](src/message_details_dialog.vala),
[event_handler.vala](src/event_handler.vala), [rpc_client.vala](src/rpc_client.vala).

## CORE-005: Channel view counts

**Gap:** Parla handles `MsgReadCountChanged` as a refresh event, but does not
fetch or display the associated count.

**Implement:** Use `get_message_read_receipt_count` to show view feedback for
messages in channels owned by the profile. Add a compact row indicator and/or
details entry, refreshing only affected messages. Core documents this count as
feedback for the channel owner.

**Done when:** Counts update after new receipts, zero and unavailable are
distinguished, and other chat types do not show a misleading channel counter.
Avoid fetching a count for every message in every chat.

**Entry points:** [event_handler.vala](src/event_handler.vala),
[message_row.vala](src/message_row.vala), [message_details_dialog.vala](src/message_details_dialog.vala).

## CORE-006: Native Saved Messages

**Gap:** Parla recognizes the Saved Messages chat, but lacks a dedicated native
save action and navigation between saved copies and their originals.

**Implement:** Add Save to Saved Messages for single and selected messages using
`save_msgs`. Parse `originalMsgId` and `savedMessageId`, and offer Show in
Original Chat where available. Use core's save operation so its copy/reference
semantics and synchronization with linked devices are retained.

**Done when:** Text and attachments can be saved and opened, existing saved
copies are recognized, and missing originals do not break navigation. Verify
the save operation with a second device using the same profile.

**Entry points:** [message_actions.vala](src/message_actions.vala),
[conversation_view.vala](src/conversation_view.vala), [rpc_parsers.vala](src/rpc_parsers.vala).

## CORE-007: Export and restore backup files

**Gap:** Profile transfer through `provide_backup`/`get_backup` is implemented;
backup-file export and restore are absent.

**Implement:** Add profile export with `export_backup` and restore into a new
profile with `import_backup`, including the optional passphrase. Reuse setup
progress/cancellation handling and core's required I/O lifecycle. Make the
destination, completion, and restore failure visible to the user.

**Done when:** Disposable profiles round-trip through both protected and
unprotected backups, retaining messages, attachments, and identity. Wrong
passphrases, cancellation, and interrupted imports leave existing profiles
untouched and do not leave a failed import selected as a usable profile.

**Entry points:** [profile_dialog.vala](src/profile_dialog.vala),
[account_creation.vala](src/account_creation.vala), [event_handler.vala](src/event_handler.vala).

## CORE-008: Keep sending while work is pending

**Gap:** Explicit quit currently tears down the application without checking
whether outgoing work remains across profiles.

**Implement:** Use `is_sending_finished()` (**new in 2.61**) to coordinate
pending-send feedback and platform background/suspend inhibition where
supported. Define how close-to-tray, background mode, explicit quit, and an
offline queue interact. Offer an explicit quit path rather than waiting
indefinitely for connectivity.

**Done when:** Pending sends in a background profile are included, lifecycle
holds are released when queues empty or the user quits, and normal idle close
behavior is preserved. An empty queue must not be presented as proof of remote
delivery. Do not use the tests-only `wait_for_all_work_done` API here.

**Entry points:** [application.vala](src/application.vala),
[window.vala](src/window.vala), [rpc_client.vala](src/rpc_client.vala).

## CORE-009: Relay-provided app update information

**Gap:** Parla has an engine updater but does not consume relay-provided client
release information.

**Implement:** Use `get_app_version(client_id, source_id)` (**new in 2.59**) for
Parla application update notices. Define Parla's client ID, distribution source
IDs, and monotonically increasing version integers. Query after relay metadata
has had time to arrive, then at the cadence described by core.

**Done when:** Published metadata for a supported Parla distribution produces
one appropriate update notice; absent metadata and already-current versions do
not. Distribution-managed installs follow their existing update mechanism.
Installing downloaded software still requires package authenticity checks.

**External dependency:** Relays must advertise matching Parla client/source
entries. The existence of this RPC alone does not supply Parla release data.
**Entry points:** [application.vala](src/application.vala),
[settings_dialog.vala](src/settings_dialog.vala), [rpc_client.vala](src/rpc_client.vala).

## CORE-010: Webxdc realtime channels

**Status:** Done (2026-09-28).

**Implemented:** `joinRealtimeChannel()` exposes `setListener`, `send`, and
`leave` through the shared JavaScript bridge on all three web-view backends.
Payloads are `Uint8Array`, limited to 128000 bytes and validated again at the
native boundary. The Webxdc settings include **Realtime Channels**, enabled
by default with a persisted opt-out. Disabled apps do not expose the API;
Restrict App Permissions also turns realtime off.

Open windows and events are scoped to the originating profile and message,
including background profiles. Core handles incoming peer advertisements;
Parla never automatically joins a closed app or replies with an advertisement
loop. Closing, deleting, disabling, or changing app permissions stops traffic
immediately and leaves after outstanding RPCs complete. Queued sends are
dropped, and a reopened window or explicitly rejoined JS channel waits for the
previous leave. Direct Internet permissions and browser sandbox policies are
unchanged.

**Validation:** [Host/RPC tests](tests/webxdc_realtime_test.vala) exercise binary
validation, profile routing, failed joins and closure/rejoin races. The shared
[JavaScript contract test](tests/webxdc_realtime_test.js) checks two-peer binary
exchange and stale handles. [Settings and optional WebKitGTK integration
tests](tests/webxdc_realtime_test.py) check persisted opt-out and two actual
web views exchanging data through an offline core fixture, as well as profile
isolation, deletion and disabling apps. Live relay/Iroh connectivity and native
macOS/Windows execution are not exercised by these local tests.

**Entry points:** [webxdc.vala](src/webxdc.vala),
[webxdc_realtime.vala](src/webxdc_realtime.vala),
[event_handler.vala](src/event_handler.vala), [Webxdc platform notes](docs/webxdc.md).

## CORE-011: Voice and video calls

**Gap:** Core exposes call signaling, but Parla has no calling UI, call event
handling, or call media engine.

**Implement:** Add outgoing, ringing, accepted, ended, and failed call states
using `place_outgoing_call`, `accept_incoming_call`, `end_call`, `call_info`, and
`ice_servers`. Route incoming/accepted/ended events even for background
profiles. Choose and integrate a WebRTC media implementation, with microphone,
camera, audio-device, mute, and hang-up controls.

**Done when:** Audio and video calls interoperate with another core-based
client; answering on another linked device stops local ringing. Decline,
timeout, connection loss, permissions, and shutdown release media resources.
Unsupported platforms expose an accurate capability state.

**Dependencies:** A media backend and platform device-permission integration;
JSON-RPC supplies signaling and ICE configuration, not the media implementation.
**Entry points:** [event_handler.vala](src/event_handler.vala),
[window.vala](src/window.vala), [rpc_client.vala](src/rpc_client.vala).

## CORE-012: Location messages and live sharing

**Gap:** Parla does not render location messages or expose location sharing.

**Implement:** First support fixed locations through the `send_msg` location
field, `hasLocation`, and `get_locations`. Then add explicitly enabled,
time-limited live sharing using `set_location`, `send_locations_to_chat`,
`is_sending_locations`, `is_sending_locations_to_chat`, and
`stop_sending_locations`. Handle location events and choose a map presentation
or the optional core Webxdc integration.

**Done when:** Received coordinates can be viewed; sharing shows its target
chat and remaining duration, stops on request/expiry, and handles unavailable
location permission or providers. Profile switches cannot obscure an active
sharing session.

**Dependencies:** Platform location providers and a map/display choice. A
Webxdc-based map may use `set_webxdc_integration`/`init_webxdc_integration`.
**Entry points:** [compose_bar.vala](src/compose_bar.vala),
[message_row.vala](src/message_row.vala), [event_handler.vala](src/event_handler.vala).

## CORE-013: Contact cards and vCard import/export

**Status:** Done (2026-11-12).

**Implemented:** `vcardContact` metadata provides contact thumbnails in chats
and the Files gallery. The composer supports sharing contacts, including self,
and previews attached VCF files. Contact details and profiles expose vCard
view/share/export. Desktop file opening and New Chat's Open vCard action load
single- and multi-contact files into a viewer with explicit import/start-chat
actions for cards with email addresses. Standard cards without email addresses
can also be previewed, saved, shared, or opened with the system handler from
conversation and gallery context menus. Core's `parse_vcard`,
`import_vcard_contents`, and `make_vcard` preserve
keys and resolve identity/duplicates; preview alone never imports contacts.
Import uses the reviewed snapshot, caps files at 4 MiB, and reports unsupported
or malformed data. Imported contacts are opened by ID, rather than address.

**Validation:** Metadata and type regression tests, plus an optional real-core
test for multi-contact import, deduplication, profile isolation, export, public
key preservation, invalid UTF-8, and oversized files. The `--vcard-ui` smoke
mode additionally checks thumbnails in each message layout and the composer.

**Entry points:** [rpc_parsers.vala](src/rpc_parsers.vala),
[message_row.vala](src/message_row.vala), [contact_picker_dialog.vala](src/contact_picker_dialog.vala).

## CORE-014: Native forwarding between profiles

**Gap:** The destination picker already supports other profiles. However,
`copy_messages_to_account` fetches text/files and re-sends them; its comment
incorrectly states that core cannot forward across accounts. This bypasses
native forwarding semantics, including the forwarded marker.

**Implement:** Replace that copy loop with `forward_messages_to_account`,
capturing both profile IDs and the destination chat when the action starts.
Keep same-profile forwarding on `forward_messages`. Remove the obsolete
workaround and its comment after native behavior is verified.

**Done when:** Cross-profile forwarding handles text, media, and multiple
messages with core's ordering and forwarding behavior. Switching profiles
while the picker or RPC is open cannot redirect the operation. Do not promise
preservation of original sender identity or Webxdc updates: core forwarding
deliberately excludes those.

**Entry points:** [message_actions.vala](src/message_actions.vala),
[contact_picker_dialog.vala](src/contact_picker_dialog.vala), [rpc_client.vala](src/rpc_client.vala).

## CORE-015: Group and channel descriptions

**Gap:** Chat Details exposes names, avatars, and membership, but lacks the
core-backed description field.

**Implement:** Display `get_chat_description` and allow eligible group/channel
edits with `set_chat_description`. Reuse the existing chat editability rules
and refresh after chat metadata changes. Account for core-generated status
messages when a published description changes.

**Done when:** Descriptions round-trip between clients, empty descriptions are
handled, and incoming channels or otherwise non-editable chats are read-only.
Failed saves preserve the user's draft text.

**Entry points:** [chat_info_dialog.vala](src/chat_info_dialog.vala),
[chat_actions.vala](src/chat_actions.vala), [rpc_client.vala](src/rpc_client.vala).

## CORE-016: Core-controlled composer availability

**Gap:** Chat Details and deletion eligibility use `canSend`, but the
conversation's compose controls mainly account for contact requests. Core's
send permission is not consistently reflected across sending entry points.

**Implement:** Apply the full-chat `canSend` value or `can_send` to the text
composer, attachments/drop targets, voice recording, and forwarding
destinations. Refresh after membership/chat changes and provide an explanation
when sending is unavailable. Preserve drafts across permission changes.

**Done when:** Incoming channels, left groups, and other non-sendable chats
cannot initiate sends through mouse, keyboard, or drop actions. Accepting a
request or regaining permission enables the appropriate controls; core still
validates the final send.

**Entry points:** [conversation_view.vala](src/conversation_view.vala),
[compose_bar.vala](src/compose_bar.vala), [window.vala](src/window.vala),
[contact_picker_dialog.vala](src/contact_picker_dialog.vala).

## CORE-017: Complete contact freshness presentation

**Gap:** The **2.61** `freshness` field is consumed, but reduced to the existing
recent-presence boolean. `Normal` and `Old` currently look the same.

**Implement:** Preserve the complete freshness enum in contact/chat models and
decide on a restrained presentation for contacts core classifies as Old.
Provide an accessible text explanation where that distinction is shown. Keep
unknown enum values compatible with future engines.

**Done when:** RecentlySeen, Normal, and Old are modeled distinctly, unknown
values degrade gracefully, and the UI does not invent an exact last-seen time
or treat freshness as a guarantee of current online status.

**Dependencies:** A UI decision about where Old is useful to show.
**Entry points:** [rpc_parsers.vala](src/rpc_parsers.vala),
[models.vala](src/models.vala), [chat_row.vala](src/chat_row.vala).

## CORE-018: Network change and resume notification

**Gap:** Parla has no application-side network-change hook calling core's
reconnection hint.

**Implement:** Notify core with `maybe_network()` after relevant network changes
and resume events, using the platform network monitor. Coalesce repeated
notifications and tolerate an engine that is starting, restarting, or offline.
Keep connection recovery independent of whether a window is visible.

**Done when:** A network reconnect or suspend/resume prompts core to retry
without a manual application restart, including background profiles. Repeated
network events do not flood RPC or require reconfiguring the profile.

**Entry points:** [application.vala](src/application.vala),
[rpc_client.vala](src/rpc_client.vala), [background behavior](docs/background.md).

## CORE-019: Webxdc activity links

**Gap:** The message parser does not retain `webxdcHref` or the parent-message
relationship needed to open a Webxdc activity message at its referenced state.

**Implement:** Handle Webxdc info messages using their parent instance and
`webxdcHref`/`get_webxdc_href`. Open or reuse the correct app instance with the
referenced in-app location, preserving its profile scope and existing launch
policy. Use core's metadata rather than guessing from the displayed text.

**Done when:** Activating an app's activity message reaches the intended app
location. Deleted instances, unavailable downloads, and disabled Webxdc have
clear outcomes. The href cannot escape the app's resource and navigation rules.

**Entry points:** [rpc_parsers.vala](src/rpc_parsers.vala),
[conversation_view.vala](src/conversation_view.vala), [webxdc.vala](src/webxdc.vala).

## CORE-020: Persistent profile order

**Gap:** The profile UI does not expose reordering backed by core.

**Implement:** Add accessible move controls or drag-and-drop in profile
management and persist the result through `set_accounts_order`. Render profiles
in core's returned order while keeping selection/default-profile preferences
separate from ordering.

**Done when:** Ordering survives restart, the active profile does not change
when moved, and adding/removing profiles produces a valid order. Provide a
keyboard alternative to dragging. Do not imply cross-device synchronization
unless core explicitly provides it.

**Entry points:** [profile_dialog.vala](src/profile_dialog.vala),
[window.vala](src/window.vala), [account_finder.vala](src/account_finder.vala).

## Already implemented

The following work is complete and should not be reintroduced as open tasks:

- Native mark-unread for the open chat, serialized read-state calls, opening at
  the first unread message, an unread separator, and visibility-based seen
  calls: `398e1ef`, `b70d177`, `6681d8a`.
- Presence compatibility using `freshness`, removal of obsolete verification
  metadata/OAuth transport arguments, and outgoing identity based on SELF:
  `0e2694d`, `61a5133`, `c71b7ee`, `e388540`.
- Profile addresses from transports, relay-change refresh, and native
  multi-relay onboarding: `82c53ab`, `92c5147`, `78b187b`.
- Core-provided Webxdc instance identity: `b8f004f`.
- Pinned-message event handling: `9b88a1f`; native pin/unpin UI already exists.
- Anonymous aggregate reaction counts and permitted channel reaction choices:
  `a2bba3d`, `c468d31`.

Message editing, disappearing-message timers, forwarding within a profile,
partial-message download, contact requests/blocking, relay management, and
device-to-device profile transfer also already have implementations. Extend
those paths when a task needs them.

## Implementation and validation notes

- Bind each asynchronous operation to its initiating profile and chat. Ignore
  stale responses after navigation, profile removal, or view closure.
- Keep RPC method availability separate from UI capability. Older/custom
  engines should get a clear unsupported state where a feature requires a newer
  method. Do not hide unrelated RPC failures as compatibility fallbacks.
- Preserve keyboard access, screen-reader labels, and narrow-window layouts.
  Webxdc/media changes need explicit platform coverage or a supported fallback.
- Add regression coverage for the behavior being changed. Use temporary
  profiles for native-core integration tests and another client/device for
  protocol interoperability or synchronization claims.
- Reuse existing test entry points: `meson test -C builddir --print-errorlogs`,
  [core compatibility tests](tests/core_compat_test.vala),
  [native unread tests](tests/core_unread_test.py), and
  [display-based unread tests](tests/unread_ui_test.py).
- `wait_for_all_work_done` is explicitly tests-only. Deprecated helpers such as
  `send_sticker` do not need adoption where Parla already uses their replacement.
  Batch RPCs and event batching are performance options to evaluate with
  measurements. `get_similar_chat_ids` is experimental and needs a separate
  product decision before becoming a feature commitment.
- Localization/core stock strings and local encrypted storage are tracked in
  [release readiness](docs/release-readiness.md); keep their scope there.

## Reference sources

- [Core 2.62 JSON-RPC methods](https://github.com/chatmail/core/blob/v2.62.0/deltachat-jsonrpc/src/api.rs)
- [Core 2.62 message fields](https://github.com/chatmail/core/blob/v2.62.0/deltachat-jsonrpc/src/api/types/message.rs)
- [Core 2.62 events](https://github.com/chatmail/core/blob/v2.62.0/deltachat-jsonrpc/src/api/types/events.rs)
- [Core 2.62 changelog](https://github.com/chatmail/core/blob/v2.62.0/CHANGELOG.md)
- [Audited main API](https://github.com/chatmail/core/blob/7e070efc28f576a187226166434e3efe336f8829/deltachat-jsonrpc/src/api.rs)
- [Parla RPC client](src/rpc_client.vala), [event handling](src/event_handler.vala),
  and [message models](src/models.vala)
