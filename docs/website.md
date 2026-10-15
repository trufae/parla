# Project website

The GitHub Pages site lives in `www/`, following the buildless structure used
by `trufae/pmai`. It uses local assets, system fonts and plain HTML/CSS/JS.
No package installation, external font service or browser-side API request is
needed. Navigation, screenshots and release links work without JavaScript;
JavaScript adds the mobile menu, light/dark screenshot switch and image viewer.

## Preview

From the repository root:

```sh
python3 -m http.server 8080 --directory www --bind 127.0.0.1
```

Open `http://127.0.0.1:8080`. In the source tree, download buttons point to the
latest release page. Deployment resolves them to individual release assets.

## Verify and package

```sh
node --check www/app.js
gh api repos/trufae/parla/releases/latest > /tmp/parla-release.json
gh api repos/trufae/parla-haiku/releases/latest > /tmp/parla-haiku-release.json
python3 scripts/build-website.py \
  --release /tmp/parla-release.json \
  --haiku-release /tmp/parla-haiku-release.json \
  --output /tmp/parla-pages
```

Use a new output directory each time. Omit the release arguments for an offline
build with release-page fallback links. The builder checks local assets,
fragment links, unique IDs, image alt attributes and download mappings. A
missing package falls back to its project's release page; an invalid API
response fails the build instead of silently publishing incorrect downloads.

## Deployment

`.github/workflows/pages.yml` publishes `www/` to
<https://trufae.github.io/parla/> with GitHub Actions. In repository **Settings →
Pages**, the publishing source must be **GitHub Actions** (already configured
when this site was added). Changes to the site, builder or workflow on `main`
deploy automatically; the workflow can also be run manually. Published or edited
releases refresh download links. Successful tag CI runs cover releases created
with `GITHUB_TOKEN`, which do not fire a second workflow's release event.
The website always uses source from `main`.

The Haiku repository has its own release schedule. After a new Haiku preview,
run this repository's **Pages** workflow manually to refresh its direct links.

## Artwork and screenshots

- `www/assets/parla.svg` and `parla.png` copy the project's root artwork.
- `welcome.png`, `welcome-dark.png` and `audio-player-mobile.png` copy files
  from `data/screenshots/`. The audio screenshot is an offline UI test with
  sample messages, identified as such on the page.
- `haiku-conversation.png` is the public screenshot asset from the
  [Haiku v0.1.5 preview](https://github.com/trufae/parla-haiku/releases/tag/v0.1.5).

Keep these copies current when replacing the source screenshots or logo.
Use sanitized sample conversations when adding screenshots. The Haiku image
documents a separate native client in development, not GTK feature parity.

The name section paraphrases dictionary entries and links directly to
[the Catalan GDLC](https://www.diccionari.cat/GDLC/parla),
[Treccani](https://www.treccani.it/vocabolario/parlare/) and
[the Spanish DLE](https://dle.rae.es/parla).
Resource-use copy is qualitative: no measured RAM figure is claimed.
