# Deps-baked builder image for the local fast-incremental ffmpeg build.
#
# FROM jellyfin-ffmpeg's own base image (jellyfin-ffmpeg-build-<codename>), which
# already carries the toolchain, the apt build-environment, the patched source at
# ${SOURCE_DIR}=/ffmpeg (COPY . from the patched tree), and all the ENVs from
# Dockerfile.in (TARGET_DIR, PKG_CONFIG_PATH, LD_LIBRARY_PATH, LDFLAGS rpath, ...).
#
# The base image runs docker-build.sh only as its ENTRYPOINT (at container-run
# time), so no dependency is built during its `docker build`. Here we run just the
# dependency-preparation slice of docker-build.sh -- everything BEFORE the
# `dpkg-buildpackage` line -- which cmake/make-installs the 30+ source deps (incl.
# libaribcaption added by the patch) into ${TARGET_DIR} and runs `mk-build-deps -i`
# to install ffmpeg's apt Build-Depends. That expensive step is thus baked in ONCE.
# PROFILE selects how much of docker-build.sh's dependency phase to bake:
#   full - everything before the `dpkg-buildpackage` line (all source deps +
#          arch-specific GPU/HWA stack + `mk-build-deps`). Matches CI.
#   lean - only `prepare_extra_common` (software codecs incl. libaribcaption) +
#          `mk-build-deps`. Skips the heavy GPU/HWA deps. Default for fast dev.
ARG BASE
FROM ${BASE}
ARG PROFILE=lean

# SOURCE_DIR is fixed at /ffmpeg by Dockerfile.in; the patched source is already
# COPY'd there in the base image. `sed .../Q` prints up to (excluding) the marker
# line. The lean slice keeps only the function definitions, then appends a call to
# prepare_extra_common + mk-build-deps for ffmpeg's apt Build-Depends.
RUN set -eux; \
    if [ "$PROFILE" = "full" ]; then \
        sed '/^dpkg-buildpackage/Q' /ffmpeg/docker-build.sh > /tmp/deps.sh; \
    else \
        sed '/^# Set the architecture-specific options/Q' /ffmpeg/docker-build.sh > /tmp/deps.sh; \
        { echo 'apt-get update && apt-get dist-upgrade -y'; \
          echo 'prepare_extra_common'; \
          echo 'cd /ffmpeg'; \
          echo 'yes | mk-build-deps -i'; } >> /tmp/deps.sh; \
    fi; \
    bash /tmp/deps.sh; \
    rm -f /tmp/deps.sh; \
    git config --system --add safe.directory '*'

WORKDIR /ws
