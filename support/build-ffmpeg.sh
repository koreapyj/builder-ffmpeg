#!/usr/bin/env bash
#
# Fast incremental ffmpeg build for local patch development.
# Runs INSIDE the deps-baked builder image (support/Dockerfile.builder), with the
# host's patched jellyfin-ffmpeg checkout bind-mounted at the working directory.
# All dependencies are already installed in ${TARGET_DIR} by the image; here we
# only (re)build ffmpeg itself, reusing object files across runs for incrementality.
#
# Invoked by `make build`. Not used by CI.

set -euxo pipefail

# Apply jellyfin's own debian/patches (debian/source/format is "3.0 (quilt)", ~94
# hwaccel patches) so the in-tree source matches the packaged build. dpkg-source
# does this with its built-in quilt support -- no `quilt` binary required -- and is
# idempotent (a no-op once .pc/ records them as applied).
if [ -f debian/patches/series ]; then
    dpkg-source --before-build . || true
fi

# Pull the exact configure flags straight out of debian/rules so we never
# duplicate them. CONFIG references ${TARGET_DIR} (from the image env) and appends
# arch-specific flags keyed on DEB_HOST_MULTIARCH, so set that the way
# dpkg-buildpackage would.
export DEB_HOST_MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
cat > /tmp/_cfg.mk <<'EOF'
include debian/rules
_showconfig:
	@printf '%s ' $(CONFIG)
EOF
CONFIG="$(make -s -f /tmp/_cfg.mk _showconfig)"
rm -f /tmp/_cfg.mk

# In the lean profile the GPU/HWA deps were not baked, so drop the configure
# flags that would require them (and LTO, which only slows the dev link). The
# software-codec flags -- including --enable-libaribcaption -- are kept.
if [ "${PROFILE:-lean}" != "full" ]; then
    LEAN_DROP="--enable-lto=auto --enable-opencl --enable-libdrm --enable-vaapi \
               --enable-amf --enable-libvpl --enable-vulkan --enable-libplacebo \
               --enable-libshaderc --enable-ffnvcodec --enable-cuda \
               --enable-cuda-llvm --enable-cuvid --enable-nvdec --enable-nvenc"
    filtered=""
    for tok in ${CONFIG}; do
        drop=0
        for d in ${LEAN_DROP}; do [ "${tok}" = "${d}" ] && drop=1 && break; done
        [ "${drop}" -eq 0 ] && filtered="${filtered} ${tok}"
    done
    CONFIG="${filtered} --disable-vaapi --disable-vulkan"
fi

# Configure once; reuse it on every subsequent incremental rebuild. ffmpeg writes
# ffbuild/config.mak when configured.
if [ ! -f ffbuild/config.mak ]; then
    ./configure ${CONFIG}
fi

make -j"$(nproc)"

# Artifacts were created as root inside the container; hand them back to the host
# user that owns the bind mount.
chown -R "$(stat -c %u:%g /ws)" .
