# Sticker packs

## Just want stickers for Parla?

Download the [starter collection](https://radare.org/parla-starter-stickers.zip).
The [installation README](../../www/stickers/README.md) explains how to pick a
pack, merge it into Parla's sticker folder, and find it in the picker. These
downloads are ready to use: no Telegram account, token or converter is needed.

## Prepare the public downloads

From the repository root, with the downloaded, converted `HotCherry/`,
`CupidKitty/`, `VampireQueen/` and `Radare/` WIP directories available here:

```sh
make -C scripts/stickers packs
```

This writes the combined `parla-starter-stickers.zip`, four individual packs,
`manifest.json` and `SHA256SUMS` to `scripts/stickers/packs/`. All generated
downloads and metadata are ignored by Git and kept outside the website.
The website links only to the externally hosted starter ZIP at
<https://radare.org/parla-starter-stickers.zip>. Upload rebuilt starter archives
there separately. Other WIP downloads remain outside the starter collection.

`package.py` reads the converted metadata's sticker list, retains emoji and
animation, and names images in Parla's flat `Pack__emoji__checksum.gif` format.
Each ZIP contains a `stickers/` folder, the user README and the complete
[artwork credits and license status](../../www/stickers/ATTRIBUTION.md);
raw Telegram API responses and thumbnails are excluded. Rebuilds use fixed ZIP
timestamps and ordering. The source downloads are local inputs, not required
to build the app or website. For another input/output location, use
`python3 scripts/stickers/package.py --source /path/to/packs --output /path/to/output`.
Use `--starter-output /path/to/parla-starter-stickers.zip` to choose the combined
archive's destination. Upload rebuilt starter archives to the external host
when updating the published collection.

Maintain `www/stickers/ATTRIBUTION.md` as the shared credit document for the
website and all ZIPs. Preserve verified artist/animator names, public contact
links, original `t.me/addstickers/` links, original copyright notices and exact
license terms when available. Mark missing authors, contacts and permissions
explicitly instead of guessing or applying Parla's software license. The current
packs' conversion and redistribution permissions remain unverified; attribution
does not establish permission. Record permission evidence before treating a pack
as cleared for distribution.

The remainder of this document is for downloading and converting more packs.

This directory contains scripts to download Telegram and Signal sticker packs
into something standard and reusable for other apps.

Yeah, Telegram uses .tgs format which is a variant of the lottie
animated vector image format.

In the official DeltaChat app we can display stickers but there's
no way to manage or add them unless you have a custom keyboard
for iOS/Android that handles that.

To use Telegram stickers in here we need to download their packs
(those are just zip files with json files inside), the .tgs files
are gzipped jsons which can be converted to animated gifs with
the lottie2gif tool (there's a makefile for that).

## Caveats

The magic of tgs is that those are pretty small attachments, for animated
stickers we must drop some fps (default is 30, but 20 still looks good) and
scaling down the image to 30% saves about 90% of the full gif.

Ideally we may all use webm because thats kind of animated webp, it's not
vector based, but at least it's not a full new image for each frame and not
limited to 256 colors of the GIF, buuuut the vp9 renderers of ffmpeg do not
supporta alpha background, so they look with an ugly black square background.

In macOS you will need to install `brew install webp-pixbuf-loader` to render
the WebP stickers.

## Download a Telegram pack

Create any Telegram bot with
[@BotFather](https://t.me/BotFather), copy its token, and install the script's
dependencies: Bash, `curl`, `jq`, and `zip`. The bot does not need to be added to
a chat or own the pack.

```sh
export TELEGRAM_BOT_TOKEN='123456789:replace-with-your-token'
scripts/stickers/download.sh 'https://t.me/addstickers/XXX'
```

The default output is `abangtheo.zip`. An explicit destination can be passed as
the second argument:

```sh
scripts/stickers/download.sh \
  'https://t.me/addstickers/abangtheo' \
  /tmp/abangtheo.zip
```

## Download a Signal pack

Signal packs need no bot token. Install Bash, `curl`, `jq`, `openssl`, Python 3,
and `zip`, then pass the complete `signal.art` URL in quotes so the shell does
not interpret its `#` or `&` characters:

```sh
scripts/stickers/signal.sh 'https://signal.art/addstickers#pack_id=...&pack_key=...'
```

The default output name is `<pack-id>.zip`; pass a second argument to choose a
different destination. More public Signal packs can be found at
[signalstickers.org](https://signalstickers.org/).

## Converting a pack

The `convert.sh` file is a Bash script that takes an original Telegram pack and
generates a new zip with `.webm` or `.gif` images. It converts both TGS vector
stickers and VP9 WebM video stickers. For WebM input, FFmpeg's `libvpx-vp9`
decoder is selected explicitly so the alpha channel is retained.

```bash
ANIMATED_SCALE=0.3 ANIMATED_FPS=20 ANIMATED_FORMAT=gif \
       bash convert.sh hotcherry.zip hotcherry-gif.zip
```

For TGS input, if you don't have lottie2gif installed, the make paves the way
with:

```sh
make -C scripts/stickers macos-deps
make -C scripts/stickers lottie2gif
```

The second command clones Samsung's
[official rlottie repository](https://github.com/Samsung/rlottie), builds only
the `lottie2gif` target with Meson, and puts a stable copy at
`scripts/stickers/.tools/bin/lottie2gif`. `convert.sh` finds that copy
automatically. The local build also renames upstream's `format` maintenance
script to prevent it from shadowing the C++ `<format>` header in recent Xcode
SDKs, and disables rlottie's broken 32-bit NEON assembly path on Apple Silicon.
To put the resulting program on your normal `PATH` instead, use:

```sh
make -C scripts/stickers install PREFIX="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
```

## Further documentation

For more details you can learn about stickers:

Telegram:

* [Stickers](https://combot.org/stickers)
* [sticker documentation](https://core.telegram.org/stickers) and
[Bot API documentation](https://core.telegram.org/bots/api#stickers).

DeltaChat:

* [StickerBot](https://github.com/deltachat-bot/stickersbot)

Signal:

* [Stickers](https://signalstickers.org/)
