# Terminal UI library

`terminal/` builds `libparla-terminal.a`, `parla-terminal.h`, and
`parla-terminal.vapi`. Its Vala API is in `Parla.Terminal`; Meson consumers
link `parla_terminal_dep`. It depends only on GLib/GIO and a small POSIX C
adapter for termios, terminal size, and SIGWINCH. It does not depend on GTK,
JSON, curses, or Parla's backend. The current backend supports ANSI/VT
terminals on Linux and macOS. Windows continues to build the plain REPL.

```sh
meson setup builddir-cli -Dgui=false
meson compile -C builddir-cli
./builddir-cli/parla-cli  # opens the TUI with the saved default profile
meson test -C builddir-cli terminal terminal-pty terminal-commands cli --print-errorlogs
```

Interactive stdin/stdout select the TUI automatically; piped input uses the
line-oriented REPL. The permanent Contacts tab lists conversations, including contacts and groups,
with unread counts. Open one to load its latest 100 messages. Core events
refresh the conversation list and active tab; switching tabs refreshes that
tab. Group/channel labels have a `#` prefix and direct chats an `@` prefix
in the contacts list, tabs and `/list`; commands accept prefixed or plain names.
Messages use `HH:MM <nick> text`, with a stable color for each sender
and Markdown in the body. Continuation lines align with the body after the
nick. Own nicks use a separate color from remote senders. Pending messages
show `--:--` until Core reports delivery, when the timestamp updates in place.
Unread contacts have `*` before their name; pinned chats have 📌 in a separate
column. Both marker columns reserve their space so every name, time and
grey message preview stays aligned. Open conversations are cyan and the
selected contact has a background highlight. Unread chat tabs show their
own count; the Contacts badge totals unread messages from chats without an
open tab. Merely visiting Contacts does not mark those messages read.
Opening a chat marks its
displayed incoming messages as read and clears its unread marker.

Commands work from every chat. Their replies and errors go to the permanent
Parla tab, which gets an unread marker when output arrives in the background.
Esc+1 selects Parla. `/help` lists commands and keys; `/version` prints the
version; `/quit` exits. `/close` and `/part` close the current tab. Reopening
a contact restores its draft, history and scroll position for this session.
Use `//text` to send a literal leading slash.

`/account` lists configured accounts; `/account ID`, `/account next` and
`/account prev` switch between them. Account views retain their chat tabs and
drafts; input recall is shared across all tabs and accounts. `/query NAME|ADDRESS|ID`
opens an existing conversation or starts a direct chat with a contact, adding
an unknown address to contacts when needed. Names accept an optional `@`
prefix; `#NAME` and numeric IDs refer to existing chats. Ambiguous contact
names require an address. `/join ID|NAME` opens existing conversations only.
New accounts are still configured in the GUI.

Click a message to select it; its ID appears in the status line. `/reply TEXT`
quotes the selected message, or the latest incoming message if none is selected.
`/reply` alone enters selection mode: j/k or arrows move between messages,
Enter selects one and prepares `/reply ` in the input, and Escape cancels.
`/reply @USER TEXT` targets that user's latest message; `/reply #ID TEXT`
targets an explicit message in the current chat. Escape outside selection
mode clears a clicked selection. Default/sender lookup searches older history
in batches if the target is outside the visible 100-message scrollback.

`/react EMOJI` adds a reaction to the selected/latest incoming message while
preserving your other reactions. `/unreact EMOJI` removes that reaction;
`/unreact` removes all your reactions on the target. Both accept `#ID` before
the emoji. Reactions from other people are unaffected. `/react` alone also
enters message selection mode. Command results are printed in Parla.

Local image and file attachments display a filename/path hyperlink using
OSC 8. Use your terminal's link-opening gesture (often Ctrl/Cmd-click) to
open it; an ordinary click selects the message. Undownloaded attachments are
labelled as such. Images are represented by file links rather than inline
bitmap protocols, keeping the renderer portable and incremental.

`/invite` (also `/qr`) prints the current group's invite link and QR code in
Parla. In a direct chat or Parla it shares your own contact; `/invite self`
always shares your contact. The QR uses black and white half blocks with a
quiet zone, independent of theme colors. Enlarge the terminal to fit the
reported dimensions, and hide panels if necessary. A narrow viewport shows
a width notice instead of wrapping and corrupting the QR. The link remains
available if a future Core version returns an unsupported SVG format.

## Preferences and colors

Preferences are saved in `$XDG_CONFIG_HOME/parla/terminal.ini` (normally
`~/.config/parla/terminal.ini`), separate from GUI preferences. Contact grouping
and sorting changed with the keyboard also persist. Pins are stored by Core
and shared with the GUI. Existing saved choices take precedence over defaults.

```text
/set contacts_grouped=on
/set contacts_sort=alphabetical
/set chat_info=on
/set timestamps=on
/set time_format=%H:%M:%S
/set message_layout=compact
/set markdown=on
/set nick_colors=on
/color theme=ocean
/color status=white:blue
/color selected_contact=white:blue
/color contact_preview=#999999
/color selected_message=white:#334155
/color own_nick=#4ade80
/color message=#e2e8f0:#0f172a
/color status=inherit
```

`/set` lists layout/printing options; `/set NAME` shows one value. Assignments
accept either `NAME=VALUE` or `NAME VALUE`. Ctrl-G selects Contacts. While
navigating the list, `g` toggles private/group sections, `a` toggles alphabetical
and recent-message ordering, and `p` pins/unpins the selected conversation.
`?` toggles a key guide above the list; Escape also dismisses the guide.
Pinned chats stay first in either order. Selection is preserved across changes.
Escape or clicking the input enables editing; typing `/` starts a command.
Parla and Contacts stay open; other tabs can be closed.

`chat_info=on` displays a separate right-side panel with the chat name, type,
members, permission to send, and disappearing-message duration. `/info` also
prints these details in Parla. The panel hides below 72 columns.

`/color` lists effective colors. Presets are `default`, `light`, and `ocean`.
Roles include `text`, `message`, `timestamp`, `own_nick`, `nick1`–`nick4`,
`status`, `tab`, `active_tab`, `unread_tab`, `contact`, `active_contact`,
`open_contact`, `selected_contact`, `input`, `separator`, `info`, `completion`,
`code`, `accent`, `error`, `contact_preview`, and `selected_message`. Values accept ANSI names (including `bright_`
variants), `#RRGGBB`, or `foreground:background`. `inherit` restores the preset
value. Remote nick colors that match the configured own-nick color fall back
to a contrasting color. Tab completes roles, presets and color names.

## API example

```vala
using Parla.Terminal;

int main () {
    var loop = new MainLoop ();
    var view = new View ();
    var alice = view.add_tab ("alice", "Alice");
    alice.append_message ("14:05", "Alice", "Hello **world**.");
    view.set_contacts ({ new Contact ("alice", "Alice", "online", 2) });
    view.set_status ("Connected · Alice");
    view.contact_activated.connect ((contact) => view.select_tab (contact.id));
    view.submitted.connect ((buffer, text) => {
        // Start your async send here. The draft has already been cleared.
        buffer.append_text ("You: " + text);
    });
    try {
        var terminal = new Session (view);
        view.quit_requested.connect (() => terminal.close ());
        terminal.closed.connect (() => loop.quit ());
        terminal.failed.connect ((message) => stderr.printf ("%s\n", message));
        loop.run ();
        terminal.close ();
    } catch (Error e) {
        stderr.printf ("%s\n", e.message);
        return 1;
    }
    return 0;
}
```

Use the default GLib main context for all API calls. `Session` owns raw mode,
the alternate screen, bracketed paste, SGR mouse reporting and resize handling. Call `close()`
before releasing it or quitting your main loop. Closing is idempotent;
stdin EOF/hangup, SIGINT, SIGTERM and SIGHUP also restore terminal state.
Only one session can own stdin/stdout at a time. Redirect application logs
away from stdout/stderr while the screen is active. A non-interactive or
`TERM=dumb` terminal is rejected before entering raw mode.

`View` provides the Contacts tab, tab strip, message viewport, status
line and input editor. `add_tab(id, title)` returns the existing tab for a
known ID; `select_tab(id)` activates it. Each `Buffer` owns its draft and
scroll offset. `append()` parses Markdown; `append_text()` displays literal
text; `append_message(time, nick, markdown)` adds an IRC-style message.
`clear()` clears history while preserving the draft. `set_contacts()`
preserves selection by ID and synchronizes tab unread counts from each
`Contact.unread_count`; `Buffer.set_unread()` also works independently.
`close_tab(id)` retains the buffer for reopening with `add_tab()`.
`set_contacts_grouped()` and `set_contacts_sort()` organize the list.
`contact_pin_requested` lets the application persist pin changes.
`Contact` metadata supplies type, pin, timestamp and preview; the library
does not fetch per-message data to populate previews. `set_status()` ignores unchanged values.
Supply `message_id` to `append_message()` for click/keyboard selection.
`begin_message_selection()` emits `message_selected` and
`message_selection_confirmed`. `Text.link()` and optional message attachment
arguments provide sanitized OSC 8 links, including during incremental redraws.
`set_info_visible()` and `set_info(title, text)` control the information pane.
`option_changed` reports interactive preference changes for application-side
persistence. `Session.set_view()` swaps account views while retaining terminal
ownership; `Session.use_theme()` applies a `Theme`. Share one `InputHistory`
between views to share recall while keeping drafts separate. `Completion`
handles prefix matching and cycling over application-provided candidates.

`Frame`, `Row`, `Renderer`, `Text`, `Editor`, and `Input` can also be used
independently. For custom layouts, build a `Row`, fill it using `text()`, and
install it with `Frame.set_row()`. Treat installed rows as immutable and
replace changed rows. `Renderer.render(frame)` returns a single ANSI batch
or an empty string. Set `cursor_x`/`cursor_y` and `cursor_visible` on the frame; `invalidate()`
forces a repaint if external output has disturbed the screen. `View.draw()`
and `Input.feed()` work without a terminal, making them usable in tests.
`Input.mouse` emits `MouseEvent` objects with zero-based coordinates, a button
and press/release/motion state. `View.handle_mouse()` routes clicks and wheel events
using the rendered layout. Mouse reporting is disabled when the session closes;
mouse motion is not requested and stray motion events do not cause redraws.

## Interaction

| Key | Action |
| --- | --- |
| Ctrl-G | Toggle contact selection; j/k or arrows move, Enter opens |
| g / a / p in Contacts | Group chats / alphabetical vs recent / pin or unpin |
| Esc+x / middle-click a tab | Close tab; preserve its draft for reopening |
| Esc+1…9 / Esc+0 | Select tab 1…9 / tab 10 |
| Ctrl-W / Ctrl-U | Delete the previous word / clear input |
| Click a contact / tab | Open the conversation / select the tab |
| Click the input | Focus input and place the caret |
| Click a message | Select it for replies and reactions |
| Wheel over history / contacts / tabs | Scroll one row / move one contact / switch one tab |
| Tab / Shift-Tab | Complete `/commands`, settings, or `@members`; cycle forwards/backwards |
| Ctrl-P / Ctrl-N or Up / Down | Recall previous / next submitted input across tabs and accounts |
| Alt-Right / Alt-Left | Next / previous tab |
| Ctrl-B / Ctrl-F or Page Up / Page Down | Page up / down through message history |
| Enter | Submit the draft |
| Alt-Enter / Ctrl-J | Insert a newline |
| Left / Right, Home / End, Backspace / Delete | Edit the draft |
| Escape | Return focus to input, cancel message selection, or clear its target |
| Ctrl-L | Force a redraw |
| Ctrl-C / Ctrl-D | Request exit |

The input grows to five visible rows and scrolls around the caret. Bracketed
paste inserts literal text in one event; embedded newlines never submit it.
Contact time/preview columns hide below 48 columns, leaving room for names.
No function keys are bound. The status line shows account, chat, unread count,
connection state and scroll offset; binding help is in `/help`. Input recall
retains the last 100 distinct consecutive submissions for this session.

## Rendering and bounds

There is no periodic repaint or terminal-size polling. Invalidations schedule
one 16 ms timeout, coalescing input and data bursts. Input changes rebuild
only the footer unless its height changes. History is parsed on insertion
and wrapped once for the current viewport width; appending extends the
cache. Hidden-tab message updates do not invalidate the active viewport;
unread count changes update the tab strip. A resize
rewraps the active buffer and repaints the screen.

The renderer retains row references, skips unchanged rows, compares cells in
changed rows, and writes only their changed spans. It batches cursor and
style changes with the text. An unchanged frame produces **zero output**.
Full screen clearing occurs on startup, resize or explicit redraw. Scrollback
uses cell differences rather than terminal scroll regions, so panels
and the footer remain fixed. New messages preserve a scrolled-up viewport and
follow the bottom when already there.

Each tab retains at most 300 entries and 1 MiB of source text, with at most
4,000 wrapped rows. An entry is limited to 16 KiB, with a visible ellipsis
when truncated; drafts and pastes are limited to 64 KiB. The CLI additionally
limits loaded history to 100 messages. These limits bound allocation and
wrapping work when opening large conversations.

Markdown covers headings, bold, asterisk emphasis, inline code, fenced code,
bullets, blockquotes, and links with visible URLs. It is a lightweight subset,
not a CommonMark parser: tables, HTML, images, syntax highlighting and nested
block layout are not rendered. Raw ESC/C0/C1 control characters are stripped
from all displayed text. Unicode wide characters occupy two cells and
combining marks stay with their base; complex emoji grapheme clusters and
terminal-specific ambiguous widths are not fully modeled. Job-control
suspension is not implemented.

Tests cover cell diffs, zero-output idle frames, UTF-8 fragmentation, paste
boundaries, editing, scrolling, small terminal sizes and bounded history.
PTY tests exercise real raw-mode setup/restoration, resize signals, incremental
typing output, idle behavior, and the CLI's fake RPC backend.
