# AppImage

Build a Linux AppImage from the repository root:

```sh
make appimage
```

The build writes:

- `dist/appimage/AppDir`
- `dist/appimage/out/parla-<arch>-<version>.AppImage`
- downloaded packaging tools under `dist/appimage/tools`

The RPC backend is not bundled by default. Set `PARLA_APPIMAGE_RPC_SERVER` only
for a local AppImage that should include a specific backend binary.

Useful overrides:

```sh
PARLA_APPIMAGE_RPC_SERVER=/path/to/deltachat-rpc-server make appimage
ARCH=x86_64 make appimage
PARLA_APPIMAGE_GTK_PLUGIN=0 make appimage
```
