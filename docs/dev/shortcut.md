# Keyboard shortcuts (developer guide)

Parla handles keyboard shortcuts centrally in `Window`, with feature-specific
logic extracted into modules under `src/shortcuts/`. This document describes the
current layout and how to extend it.

## Entry point

`Window` installs a capture-phase `Gtk.EventControllerKey` in `build_ui()` and
dispatches keys from `on_window_key_pressed()` in `src/window.vala`.

Order of handling:

1. Image / video viewer overlays (when visible)
2. Escape (dismiss transient UI, focus compose entry, cancel reply/edit)
3. Type-ahead (printable keys redirected to the compose entry)
4. **Shortcut modules** — e.g. `chat_switcher.handle_key()`
5. Global shortcuts with the platform primary modifier (Ctrl on Linux/Windows,
   Command on macOS)

Return `true` from a handler to consume the key; `false` lets GTK propagate it.

## Directory layout

```
src/shortcuts/
  chat_switcher.vala   # in-conversation chat navigation
```

New shortcut groups should get their own file here (e.g. `compose.vala`,
`global.vala`) rather than growing `window.vala` further.

Register new `.vala` files in `meson.build` alongside
`src/shortcuts/chat_switcher.vala`.

## Application state shortcuts depend on

| State | Where | Used for |
| --- | --- | --- |
| Chat open | `Window.current_chat_id`, `Window.current_view()` | Whether in-conversation shortcuts apply |
| Modal open | `Window.active_modal` | Block shortcuts while a dialog is open; cleared on `dialog.closed` |
| Visible chat | `content_stack.visible_child_name` | `"chat_<id>"` vs `"empty"` |
| Focus | `Window.focus_widget` / `get_focus()` | Whether focus is in sidebar, search, dialog, etc. |

`present_modal()` sets `active_modal` and, on close, restores focus to the
compose entry via `current_view().focus_entry()`.

## `ChatSwitcher` (`src/shortcuts/chat_switcher.vala`)

Handles **in-conversation chat navigation** — moving between chats while
viewing a conversation, without opening the sidebar.

### Bindings

| Action | Linux / Windows | macOS |
| --- | --- | --- |
| Previous chat | `Alt+Up` | `Option+Up` |
| Next chat | `Alt+Down` | `Option+Down` |
| Previous chat | `Ctrl+Page Up` | `Command+Page Up` |
| Next chat | `Ctrl+Page Down` | `Command+Page Down` |

Navigation stops at the first and last chat (no wrap-around).

### When shortcuts apply (`can_switch()`)

Allowed when:

- A chat is open (`current_view() != null`)
- No modal is open (`active_modal == null`)
- Focus is not in a blocking widget:
  - `Adw.Dialog` or `Gtk.Popover`
  - Any `Gtk.SearchEntry` (sidebar search or in-conversation search)
  - The sidebar, when `split_view.show_sidebar` is true

Allowed even when focus is on the content header or elsewhere in the content
pane — e.g. after closing the shortcuts dialog.

### Navigation logic

1. Build an ordered list of visible chat IDs from `chat_listbox`, respecting the
   sidebar search filter via `Window.shortcuts_filter_chat_row()`.
2. If the listbox has no visible rows, fall back to `chat_store` order.
3. Find the current chat index; move by `delta` (`-1` = previous, `+1` = next).
4. Call `Window.select_chat_by_id()` to switch.

### Construction

`ChatSwitcher` is created at the end of `Window.build_ui()`:

```vala
chat_switcher = new ChatSwitcher (
    this, chat_listbox, chat_store, sidebar_box, split_view);
```

It holds `unowned` references to window widgets passed in at init time.

### Shortcuts dialog

`ChatSwitcher.SHORTCUT_ENTRIES` is a flat `title, accelerator` pair array.
`append_shortcut_rows()` renders those rows in the keyboard-shortcuts dialog.

`Window.show_keyboard_shortcuts_dialog()` inserts them between two static
sections:

- `SHORTCUTS_BEFORE_CHAT_SWITCHER`
- `SHORTCUTS_AFTER_CHAT_SWITCHER`

Other global shortcut labels remain in `window.vala`.

## `Window` helpers for shortcut modules

Shortcut modules in `src/shortcuts/` cannot access `Window` private fields.
Expose the minimum via `internal` methods on `Window` (visible within the same
Vala build):

| Method | Purpose |
| --- | --- |
| `shortcuts_modal_open()` | Whether a modal dialog is open |
| `shortcuts_focus_widget()` | Effective keyboard focus |
| `shortcuts_filter_chat_row()` | Sidebar search filter for chat list rows |

Public `Window` APIs used by shortcut modules today:

- `current_chat_id`, `current_view()`, `select_chat_by_id()`

Prefer adding a small `internal` helper on `Window` over making unrelated
fields public.

## Adding a new shortcut module

1. Create `src/shortcuts/<name>.vala` with a class in namespace `Dc`.
2. Add a `handle_key(uint keyval, Gdk.ModifierType state) -> bool` method.
3. Optionally add `SHORTCUT_ENTRIES` and `append_shortcut_rows()` for the
   shortcuts dialog.
4. Store an instance on `Window` (e.g. `private ComposeShortcuts compose_shortcuts`).
5. Construct it in `build_ui()` once required widgets exist.
6. Call `handle_key()` from `on_window_key_pressed()` at the appropriate priority.
7. Add the file to `meson.build`.

### Checklist for in-conversation shortcuts

- [ ] Gate on `current_view() != null`
- [ ] Respect `shortcuts_modal_open()`
- [ ] Walk focus ancestors; block sidebar / search / dialogs when needed
- [ ] Return `true` when the key is consumed (including at list boundaries)
- [ ] Document bindings in `SHORTCUT_ENTRIES` if user-facing

## Shortcuts still in `window.vala`

These remain in `on_window_key_pressed()` behind
`Platform.has_primary_modifier()`:

- New chat / group / channel
- Settings, search in conversation, quick switch
- Account menu, refresh, sidebar toggle/compact
- Font size adjust (keys and Ctrl+scroll)
- Close window, quit

`Ctrl+Tab` / `Ctrl+Shift+Tab` for chat switching were removed intentionally;
re-add via a shortcut module when needed.

## Platform notes

- Use `<Primary>` in accelerator strings; resolve with
  `Platform.primary_accelerator_prefix()` for display labels.
- `Platform.has_primary_modifier()` maps to Ctrl (non-macOS) or Command (macOS).
- Alt+arrow bindings use `Gdk.ModifierType.ALT_MASK` explicitly (Option on macOS).