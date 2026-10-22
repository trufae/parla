# A little sticker goes a long way

Download the [starter collection](https://radare.org/parla-starter-stickers.zip)
and give your conversations a little more personality. No Telegram account,
bot token, or conversion tools are needed.

## Pick your pack

| Pack | What's inside | Stickers |
| --- | --- | ---: |
| Hot Cherry | Animated cherry reactions | 34 |
| Cupid Kitty | Animated orange cat reactions | 25 |
| Marceline | Animated Vampire Queen reactions | 20 |
| Radare | A small, static hacker-themed pack | 6 |

The starter ZIP contains all 85 stickers. Install everything, or copy only
files whose names start with your chosen pack name (for example, `Hot Cherry__`).
The animated packs use GIF; Radare uses WebP. These are a curated selection of the local WIP packs,
not a popularity ranking. Packs marked 18+ are outside this starter collection.

## Install in Parla

1. Quit Parla, including its tray or Dock instance.
2. Extract the downloaded ZIP into a temporary folder. You will find this
   README, `ATTRIBUTION.md`, and a folder named `stickers`.
3. Open Parla's data folder (see below). Create it if it does not exist.
   Copy the extracted `stickers` folder into it. If you already have stickers,
   **merge the folders**, keeping your existing files. On macOS, open both
   `stickers` folders and copy the files inside to avoid replacing a folder.
   Keep `ATTRIBUTION.md` beside the installed `stickers` folder so the credits
   and license status remain available.
4. Start Parla, open a conversation, and open the sticker picker beside the
   message composer. The installed packs appear under their own names.
   Pick a sticker to send it.

There is currently no ZIP import button: extract and copy the files; do not
send the ZIP to a chat or open it as an account backup. Keep the sticker
filenames unchanged: they carry the pack name and associated emoji.

### Find your data folder

Parla uses GLib's user data directory, followed by `parla`. Typical locations:

| System / package | Parla data folder |
| --- | --- |
| Linux (native / AppImage) | `~/.local/share/parla/` |
| Linux (Flatpak) | `~/.var/app/io.github.trufae.Parla/data/parla/` |
| macOS | `~/.local/share/parla/` |
| Windows | `%LOCALAPPDATA%\parla\` |

On Linux and macOS, `XDG_DATA_HOME` overrides `~/.local/share` if configured.
Earlier installations with accounts in `~/.config/parla/accounts/` keep using
`~/.config/parla/` instead (or `$XDG_CONFIG_HOME/parla/`). On Windows the legacy
location is the GLib user config folder, followed by `parla`.

To locate the folder in an existing installation, save a received sticker
with **Add Sticker…**, then open **Stickers** in the main menu. Right-click the saved
sticker and choose **Copy File Path**. Its parent folder is the active
`stickers` folder; copy your downloaded sticker files there.

For a standard Linux or macOS installation, you can also run:

```sh
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/parla/stickers"
unzip -n ~/Downloads/parla-starter-stickers.zip 'stickers/*' \
  -d "${XDG_DATA_HOME:-$HOME/.local/share}/parla"
```

Use the folder for your installation if it differs from the default. `-n`
keeps existing files. Reinstalling the same pack does not create extra copies.

## Make them yours

Use **Stickers** in the main menu to rename packs, change the emoji associated
with a sticker, move stickers between packs, or delete a pack. You can also
right-click a sticker received in a conversation and choose **Add Sticker…**
to keep it in an existing or new pack. Installed stickers are local to this
Parla installation; install packs separately on your other devices.

## Artwork

Read [artwork credits and license status](ATTRIBUTION.md), also included in every
ZIP, for artist and animator credits, public creator profiles, original Telegram
pack links, and unresolved copyright and license details. Creator emails are
listed only when verified; missing contacts are marked explicitly.

Artwork rights remain with their respective rights holders and are separate
from Parla's software license. Conversion and redistribution permissions have
not been verified for these packs; source links and credits do not grant them.
The archives include the converted sticker images and instructions, without
Telegram API responses or bot credentials.
