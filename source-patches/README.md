# source-patches/

ffmpeg **source** patches (files under `libav*/`, `fftools/`, …) that layer **on top of**
jellyfin-ffmpeg's own `debian/patches`.

At build time (both the local `make` flow and CI) every `*.patch` here is copied into the
checkout's `debian/patches/` and **appended to `debian/patches/series`**, so it is applied
**last** — after jellyfin's source patches — by `dpkg-source --before-build` (Linux) and by
`quilt push -a` (Windows, via the `debian/patches` symlink in `Dockerfile.win64.in`). This
means a patch here is developed and refreshed against the *real* jellyfin-patched ffmpeg and
can never break one of jellyfin's patches.

Author them with quilt on top of the debian series:

```sh
make clean prepare QUILT=1
export QUILTRC="$PWD/.quiltrc"
cd src && QUILT_PATCHES=debian/patches quilt push -a      # jellyfin + our source patches
quilt new 0001-my-change.patch && quilt add libavformat/hlsenc.c
quilt edit libavformat/hlsenc.c                            # ... make changes ...
quilt refresh
cd .. && make update                                       # copies it back here
```

> Build/packaging changes (configure flags, dependency builds, packaging) do **not** go here —
> they belong in the top-level `patches/` directory, which is git-applied to the checkout
> *before* the build runs. See the repo README.
