# Usability before the next release

## Chat actions

Use the same labels in the chat list, chat details, message menu, selection
toolbar, and media gallery. "Local" and "both" are too ambiguous: a profile
can have several devices, and a chat can have several participants.

| Action | Effect |
| --- | --- |
| Delete for Me | Remove messages and their attachments (including in-chat apps) from this history; request deletion on the server and linked devices using this profile. Other participants keep their copies. Server/device synchronization can take time or fail; this is not a guaranteed remote wipe. |
| Delete for Everyone | Also send a deletion request to other participants. Only encrypted messages sent by this profile, in one chat where it can still send, qualify. Saved, forwarded, or otherwise copied messages can remain. |
| Clear Chat | Delete the messages counted before confirmation for this profile. Keep the chat, its draft and messages arriving while the confirmation is open. |
| Delete Sent Messages for Everyone | Delete the eligible encrypted, non-status messages sent by this profile. Keep received, unencrypted and status messages. The confirmation counts the selected messages before deletion. |
| Delete Chat | Delete the chat, its draft and its history for this profile. It does not leave a group/channel, unsubscribe from a mailing list or block a contact; new messages can recreate the chat. |
| Leave Group / Leave Channel | Leave an encrypted group or an incoming channel and keep history. Published groups notify members; incoming channels do not send that group notice. Already-left chats do not offer this action. Outgoing channels and ad-hoc email groups do not offer Leave. |
| Leave and Delete | Leave first, then delete the chat, draft and history for this profile. A leave failure does not trigger deletion, but core may already have changed membership before reporting a send failure. |
| Block Contact / Block Chat | Hide the chat while keeping its history; sync blocking to linked devices. Blocking a contact does not hide their messages in shared groups. Blocking a channel/list does not unsubscribe. Unblock under Profile → Blocked Contacts. |
| Delete Request | Group requests use Delete Chat, with confirmation. Core's `block_chat` deletes groups without blocking the sender or leaving; do not label that action Block. |
| Remove Member / Remove Subscriber | Confirm removal beside that person in Chat Details. Messages already received are kept. Published groups notify members; outgoing channels remove the subscriber. |
| Remove Profile | Remove this profile's chats, contacts, downloaded attachments and keys from this device. Keep the server account, other devices, other participants, backups and files saved elsewhere. A backup or another device is needed to regain access. |
| Reset Settings | Reset Parla preferences and quit. Keep profiles and messages; a custom storage folder must be selected again. |

Cancel is the default and Escape response for destructive confirmations.
Deleting an entire chat "for everyone" is not an available core operation.
The old Disband Group shortcut mixed membership changes, remote message
deletion, leaving, and local deletion, with no rollback on partial failure.
Use the individual member and message actions instead.

Downloaded/exported files, forwarded copies and backups are not deleted by
message/chat deletion. Media gallery deletion deletes the message as well as
its attachment; it is not a device-only cache action.

Chat-list menus keep Clear, Leave and Delete together after a separator.
Chat Details groups destructive history actions separately from blocking and
creating another group/channel. Sent-message bulk deletion lives in Chat
Details; individual deletion lives in message menus, selection and media.
Member controls, invite links and avatar editing require an editable encrypted
group or outgoing channel; incoming channels, left groups and ad-hoc email
groups do not expose those controls. Profile removal and blocked-contact
recovery live in Profile; resetting application preferences lives in Settings.

The wording follows the [GNOME writing guidelines](https://developer.gnome.org/hig/guidelines/writing-style.html),
[GNOME dialog guidelines](https://developer.gnome.org/hig/patterns/feedback/dialogs.html),
and [Delta Chat terminology](https://delta.chat/en/help).
The deletion scope is verified against core's
[delete_msgs_ext](https://github.com/chatmail/core/blob/c41657d7fd261823406214eb57ad48d87a6712f9/src/message.rs)
and [ChatId::delete](https://github.com/chatmail/core/blob/c41657d7fd261823406214eb57ad48d87a6712f9/src/chat.rs),
including synchronization beyond the local device. The separate leave choices
also match the [official desktop client](https://github.com/deltachat/deltachat-desktop/blob/5e5d71b3aefb89c82c5f170b50196c3136909181/packages/frontend/src/components/dialogs/LeaveGroupDialog.tsx).
The follow-up also checks [the JSON-RPC methods](https://github.com/chatmail/core/blob/c41657d7fd261823406214eb57ad48d87a6712f9/deltachat-jsonrpc/src/api.rs),
[chat types and editability](https://github.com/chatmail/core/blob/c41657d7fd261823406214eb57ad48d87a6712f9/deltachat-jsonrpc/src/api/types/chat.rs),
[contact blocking](https://github.com/chatmail/core/blob/c41657d7fd261823406214eb57ad48d87a6712f9/src/contact.rs)
and [account removal](https://github.com/chatmail/core/blob/c41657d7fd261823406214eb57ad48d87a6712f9/src/accounts.rs).

## Remaining priorities

1. **Keyboard and screen-reader release check.** Recheck the complete path from
   profile setup to composing, selecting, and deleting messages with Orca and
   keyboard navigation. [Issue #57](https://github.com/trufae/parla/issues/57)
   reports a user unable to use the app; the focused composer work in
   [PR #76](https://github.com/trufae/parla/pull/76) should be reviewed alongside
   this. Keep focus visible and confirm that Escape/Enter cannot delete data.
2. **Localization after the English wording settles.** `src/` currently uses
   literal English strings and `meson.build` has no gettext integration.
   Add gettext initialization, extraction and catalogs, desktop/AppStream
   translation, and plural forms together. Include dates, relative times,
   accessibility labels, and the core's stock messages. Translate complete
   messages with placeholders rather than assembling translated fragments;
   test a longer translation and a right-to-left locale. Follow the system
   language by default. Do not ship a language selector before catalogs exist.
3. **Integrate encrypted storage as a separate feature.** `safestore/` is a
   standalone project; the main Meson build and RPC startup do not use it.
   Wire unlock into startup before opening the account manager, and close the
   RPC process and file users before locking. Specify migration, cancellation,
   crash recovery and backup/restore behavior before exposing an encryption
   switch. Define whether downloaded attachments, previews, temporary files,
   exports and backups are covered. End-to-end encryption is not encryption
   of the local profile. The ZIP backend documented by SafeStore has weaker
   protection and leaves plaintext while unlocked; it must not be presented
   as equivalent to a mounted encrypted vault.

## Manual release checks

- In both the chat list and details, cancel Clear Chat/Delete Chat/Leave Group;
  verify nothing changes. Leave while keeping history, then verify the group
  still opens and the leave action is no longer offered. Exercise Leave and
  Delete separately and verify a failed leave does not delete history.
- Test single-message, selected-message and gallery deletion with sent,
  received, unencrypted and system messages; include a gallery selection from
  multiple chats, a left group and Saved Messages. Only supported selections
  should offer Delete for Everyone. Check with two linked devices and another
  participant to verify the scope promised by the dialogs.
- Reset preferences while using a custom profile storage folder; reselect it
  and verify the profiles are intact. Remove a disposable profile and confirm
  that another device still has it. Check narrow dialogs and larger text.
- Clear a chat with a draft; receive another message while confirmation is
  open and verify both are kept. Cancel group-request deletion and member
  removal. Block/unblock a direct contact, mailing list and incoming channel;
  confirm history remains available after unblocking. Check channel Leave
  and group membership controls in both the chat list and Chat Details.

`meson test -C builddir --print-errorlogs` includes regression cases for remote
deletion eligibility (including mixed batches and missing/null metadata),
group/channel action availability and distinct group-request action labels.
