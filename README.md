# builder-ffmpeg

## Two kinds of patches

Our patches always layer **on top of** jellyfin's, never under:

- [`patches/`](patches/) — **build/packaging** patches (`docker-build*.sh`, `debian/rules`,
  `debian/*.install`). `git apply`-ed to the checkout **before** the build runs (so
  `docker-build.sh` carries them when it executes). These never touch ffmpeg source.
- [`source-patches/`](source-patches/) — **ffmpeg-source** patches (`libav*/`, `fftools/`).
  Appended to jellyfin's `debian/patches/series`, so `dpkg-source` (Linux) and `quilt push`
  (Win64) apply them **last**, on top of jellyfin's 94 source patches. Developed/refreshed
  against the real jellyfin-patched ffmpeg, so they can never break a jellyfin patch.

## Local fast-incremental build (patch development)

The [`Makefile`](Makefile) provides a **local-only** workflow (CI does not use it) for
developing patches without pushing a tag and waiting for the full matrix. Upstream rebuilds
30+ dependencies from source on every run; this bakes them into a digest-cached Docker
image **once**, then bind-mounts the patched source so ffmpeg's object files persist on the
host — turning a ~30+ min from-scratch build into a seconds-to-minutes patch loop.

Requirements: `docker`, `make` (and `quilt` only if you author patches with quilt).

### Test a patch

```sh
make prepare      # clone jellyfin-ffmpeg into ./src/, git-apply patches/, append source-patches/ to the series
make build        # bake deps (first run only) + incremental ffmpeg build
make run          # run the built binary  (make run ARGS='-i in.ts ... out.mkv')
```

`make build` produces a runnable `./src/ffmpeg`. Edit a patch / the source and
re-run `make build` — only changed files recompile.

### Author / edit an ffmpeg-source patch with quilt

Source patches are authored as quilt patches **on top of** jellyfin's `debian/patches` series:

```sh
make clean prepare QUILT=1
export QUILTRC="$PWD/.quiltrc"
cd src && QUILT_PATCHES=debian/patches quilt push -a   # apply jellyfin + our source patches
quilt new 0001-my-change.patch && quilt add libavformat/hlsenc.c
quilt edit libavformat/hlsenc.c                         # ... make changes ...
quilt refresh
cd .. && make update                                    # copy our source patches back to source-patches/
```

`make refresh` rebases only our source patches against the current source. Build/packaging
patches in `patches/` are edited by hand (they are git-applied, not quilt-managed).

### Profiles

| `PROFILE` | Dependencies / config | Use |
|-----------|----------------------|-----|
| `lean` (default) | software codecs only (x264/x265/dav1d/svt-av1/fdk-aac/libass/**libaribcaption**/…); GPU/HWA flags dropped | fast iteration, small disk |
| `full` | upstream's exact deps + config (mesa, vulkan, libplacebo, AMF, Intel media-driver, CUDA, …) | parity check; needs lots of disk |

```sh
make build PROFILE=full      # faithful full build
make package PROFILE=full    # dpkg-buildpackage -nc -> the same .deb as CI
```

The configure flags are read live from the cloned `debian/rules`, so they always match
upstream (lean simply filters out the HWA-specific `--enable-*`).

### Useful variables

`FF_REF` (upstream tag, default `v7.1.4-3`), `FF_REPO`, `CODENAME` / `ARCH`
(default: same as host), `PROFILE`. Run `make help` for the full list.

`make clean` removes the `./src/` workspace; `make clean-image` removes the
builder image.

## Credit
- vf_ivtc_opencl: From [QSVEnc](https://github.com/rigaya/QSVEnc) under MIT License by rigaya.
