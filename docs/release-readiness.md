# Usability before the next release

## Chat actions

Use the same labels in the chat list, chat details, message menu, selection
toolbar, and media gallery. "Local" and "both" are too ambiguous: a profile
can have several devices, and a chat can have several participants.

| Action | Effect |
| --- | --- |
| Delete for Me | Delete messages from this device and the server; core syncs deletion to linked devices using this profile. Other participants keep their copies. |
| Delete for Everyone | Also send a deletion request to other participants. Only encrypted messages sent by this profile, in one chat where it can still send, qualify. Saved, forwarded, or otherwise copied messages can remain. |
| Clear Chat | Delete messages for this profile and keep the chat in the list. |
| Delete Chat | Delete the chat and its history for this profile. It does not leave a group or block a contact; new messages can recreate the chat. |
| Leave Group | Notify members and stop receiving new group messages; keep existing history. |
| Leave and Delete | Leave first, then delete the chat and its history for this profile. |
| Remove Profile | Remove that profile's messages and keys from this device. Other devices and other participants are unaffected. A backup or another device is needed to regain access. |
| Reset Settings | Reset Parla preferences and quit. Keep profiles and messages; a custom storage folder must be selected again. |

Cancel is the default and Escape response for destructive confirmations.
Deleting an entire chat "for everyone" is not an available core operation.
The old Disband Group shortcut mixed membership changes, remote message
deletion, leaving, and local deletion, with no rollback on partial failure.
Use the individual member and message actions instead.

The wording follows the [GNOME writing guidelines](https://developer.gnome.org/hig/guidelines/writing-style.html),
[GNOME dialog guidelines](https://developer.gnome.org/hig/patterns/feedback/dialogs.html),
and [Delta Chat terminology](https://delta.chat/en/help).
The deletion scope is verified against core's
[delete_msgs_ext](https://github.com/chatmail/core/blob/c41657d7fd261823406214eb57ad48d87a6712f9/src/message.rs)
and [ChatId::delete](https://github.com/chatmail/core/blob/c41657d7fd261823406214eb57ad48d87a6712f9/src/chat.rs),
including synchronization beyond the local device. The separate leave choices
also match the [official desktop client](https://github.com/deltachat/deltachat-desktop/blob/5e5d71b3aefb89c82c5f170b50196c3136909181/packages/frontend/src/components/dialogs/LeaveGroupDialog.tsx).

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

`meson test -C builddir --print-errorlogs` includes regression cases for remote
deletion eligibility, including mixed batches and missing message metadata.
