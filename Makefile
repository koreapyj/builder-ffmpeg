# Local-only patch-authoring and test-build workflow for the jellyfin-ffmpeg builder.
# GitHub Actions does NOT use this Makefile -- see .github/workflows/build.yaml.
#
# The heavy part of an upstream build is compiling 30+ dependencies from source
# on every run (docker-build.sh, no caching). This Makefile bakes those deps
# into a digest-cached builder image ONCE, then bind-mounts the patched source so
# ffmpeg's object files persist on the host -> seconds-to-minutes patch loop.

SHELL := /bin/bash

FF_REPO  ?= https://github.com/jellyfin/jellyfin-ffmpeg.git
FF_REF   ?= v7.1.4-3

# Default target = same as host (both overridable). Codename falls back to
# bookworm if the host distro isn't one upstream's `build` script supports.
SUPPORTED_CODENAMES := bullseye bookworm trixie jammy noble resolute
HOST_CODENAME := $(shell . /etc/os-release 2>/dev/null; echo $$VERSION_CODENAME)
CODENAME ?= $(if $(filter $(HOST_CODENAME),$(SUPPORTED_CODENAMES)),$(HOST_CODENAME),bookworm)
ARCH     ?= $(shell dpkg --print-architecture 2>/dev/null || echo amd64)

# Dependency/feature profile for the LOCAL build:
#   lean (default) - bake only the software-codec deps and drop the GPU/HWA
#                    --enable flags; small disk, fast bake, tests libaribcaption.
#   full           - upstream's exact dependency set and config (heavy: mesa,
#                    vulkan, libplacebo, AMF, Intel media-driver, CUDA, ...).
# CI always builds full; this only affects the local Makefile workflow.
PROFILE ?= lean

SRC        := src
# Two-tier patch model -- our patches always layer ON TOP OF jellyfin's, never under:
#   patches/        build/packaging patches (docker-build*.sh, debian/rules, *.install).
#                   git-applied to the checkout BEFORE the build runs (docker-build.sh
#                   must already carry them when it executes). Never touch ffmpeg source.
#   source-patches/ ffmpeg-source patches (libav*/fftools). Appended to jellyfin's
#                   debian/patches/series, so dpkg-source (Linux) and quilt push (Win64,
#                   via the debian/patches symlink) apply them LAST -- on top of
#                   jellyfin's source patches. Authored with quilt against that series.
PATCHES    := patches
SRCPATCHES := source-patches
QUILTRC    := $(CURDIR)/.quiltrc

# Upstream's base build image (toolchain + apt build-env + ENVs from Dockerfile.in)
# and our deps-baked builder image layered on top.
BASE_IMAGE    ?= jellyfin-ffmpeg-build-$(CODENAME)
BUILDER_IMAGE ?= ffmpeg-builder:$(CODENAME)-$(ARCH)-$(PROFILE)
DOCKERFILE    := support/Dockerfile.builder
BUILD_SCRIPT  := support/build-ffmpeg.sh
IMAGE_STAMP   := .image-stamp

# Inputs whose change should trigger a builder-image rebuild. Evaluated lazily
# (recursive '=') because the $(SRC)/* inputs only exist after `make prepare`.
IMAGE_INPUTS = $(DOCKERFILE) $(BUILD_SCRIPT) $(SRC)/docker-build.sh \
               $(SRC)/Dockerfile.in $(SRC)/debian/control $(PATCHES)/*.patch
IMAGE_DIGEST = $(shell { cat $(IMAGE_INPUTS) 2>/dev/null; \
               printf '%s\n' '$(CODENAME)' '$(ARCH)' '$(PROFILE)' '$(FF_REF)'; } | sha256sum | cut -d' ' -f1)

.DEFAULT_GOAL := help
.PHONY: help prepare stage-source-patches image force-image build run package update refresh repatch clean clean-image

help:
	@echo 'Local patch-authoring / test-build workflow (not used by CI).'
	@echo
	@echo 'Targets:'
	@echo '  prepare [QUILT=1]  clone jellyfin-ffmpeg into $(SRC)/; git-apply $(PATCHES)/ (build)'
	@echo '                     and append $(SRCPATCHES)/ to debian/patches/series (source, applied'
	@echo '                     last). QUILT=1 prints source-patch authoring steps.'
	@echo '  image              build/refresh the deps-baked builder image (idempotent)'
	@echo '  force-image        rebuild builder image even if stamp matches'
	@echo '  build              fast incremental ffmpeg build -> $(SRC)/ffmpeg (runnable binary)'
	@echo '  run [ARGS=...]     run the freshly built ffmpeg (default: -version)'
	@echo '  package            faithful dpkg-buildpackage -nc -> .deb (parity with CI; needs PROFILE=full)'
	@echo '  update             copy our quilt-refreshed source patches back to $(SRCPATCHES)/'
	@echo '  refresh            rebase OUR source patches against current source, then update'
	@echo '  repatch            re-apply edited $(SRCPATCHES)/ onto the clone (no re-clone),'
	@echo '                     then "make build" recompiles incrementally'
	@echo '  clean              remove $(SRC)/ and the image stamp'
	@echo '  clean-image        remove the builder image'
	@echo
	@echo 'Variables: FF_REF (default $(FF_REF)), FF_REPO,'
	@echo '           CODENAME (default $(CODENAME)), ARCH (default $(ARCH)),'
	@echo '           PROFILE (default $(PROFILE); lean=software codecs only, full=all HWA)'
	@echo
	@echo 'Source-patch authoring:  make clean prepare QUILT=1  ->  quilt push/new/edit/refresh  ->  make update'
	@echo 'Test build:              make prepare build  ->  make run'

$(SRC)/.git:
	git clone --branch $(FF_REF) $(FF_REPO) $(SRC)

prepare: $(SRC)/.git
	@# 1) build/packaging patches: git-applied to the checkout (idempotent).
	@set -e; \
	for p in $$(cd $(PATCHES) && ls *.patch 2>/dev/null | sort); do \
		if git -C $(SRC) apply --reverse --check "$(CURDIR)/$(PATCHES)/$$p" >/dev/null 2>&1; then \
			echo "Build patch $(PATCHES)/$$p already applied"; \
		else \
			echo "Applying build patch $(PATCHES)/$$p"; \
			git -C $(SRC) apply "$(CURDIR)/$(PATCHES)/$$p"; \
		fi; \
	done
	@# 2) ffmpeg-source patches: appended to jellyfin's debian/patches/series.
	@$(MAKE) --no-print-directory stage-source-patches
ifeq ($(QUILT),1)
	@echo
	@echo 'Source-patch authoring (our patches sit on top of jellyfin debian/patches):'
	@echo '  export QUILTRC=$(QUILTRC)   # or: cp .quiltrc ~/.quiltrc'
	@echo '  cd $(SRC) && QUILT_PATCHES=debian/patches quilt push -a   # apply jellyfin + our source patches'
	@echo '  quilt new <NNNN-name>.patch ; quilt add <file> ; quilt edit <file> ; quilt refresh'
	@echo '  cd .. && make update                                      # copy our source patches back'
endif

# Rebuild debian/patches/series = pristine jellyfin series + our source patches
# (appended, so they apply LAST). Idempotent: rebuilt from a one-time snapshot of
# the pristine series, so re-running never duplicates. Both build paths read this
# series -- Linux via dpkg-source --before-build, Win64 via `quilt push -a` over
# the debian/patches symlink (Dockerfile.win64.in).
.PHONY: stage-source-patches
stage-source-patches:
	@set -e; sdir=$(SRC)/debian/patches; \
	test -f $$sdir/series.orig || cp $$sdir/series $$sdir/series.orig; \
	cp $$sdir/series.orig $$sdir/series; \
	if ls $(SRCPATCHES)/*.patch >/dev/null 2>&1; then \
		for p in $$(cd $(SRCPATCHES) && ls *.patch | sort); do \
			echo "Appending source patch $(SRCPATCHES)/$$p -> debian/patches/series"; \
			cp "$(CURDIR)/$(SRCPATCHES)/$$p" $$sdir/; \
			echo "$$p" >> $$sdir/series; \
		done; \
	fi

# Build the builder image if its inputs changed (digest stamp + local image
# presence check). Idempotent: a no-op when nothing relevant changed.
image:
	@test -d $(SRC) || { echo "No $(SRC)/ -- run 'make prepare' first"; exit 1; }
	@set -e; \
	digest="$(IMAGE_DIGEST)"; \
	stamp=$$(cat $(IMAGE_STAMP) 2>/dev/null || true); \
	if [ "$$stamp" = "$$digest" ] && docker image inspect $(BUILDER_IMAGE) >/dev/null 2>&1; then \
		echo "Builder image $(BUILDER_IMAGE) up to date (digest $$digest)."; \
		exit 0; \
	fi; \
	case "$(CODENAME)" in \
	  bullseye) distro=debian:bullseye gcc=10 llvm=16 spirv=11;; \
	  bookworm) distro=debian:bookworm gcc=12 llvm=19 spirv=15;; \
	  trixie)   distro=debian:trixie   gcc=14 llvm=19 spirv=19;; \
	  jammy)    distro=ubuntu:jammy    gcc=11 llvm=15 spirv=15;; \
	  noble)    distro=ubuntu:noble    gcc=13 llvm=19 spirv=19;; \
	  resolute) distro=ubuntu:resolute gcc=15 llvm=20 spirv=20;; \
	  *) echo "Unsupported CODENAME=$(CODENAME)"; exit 1;; \
	esac; \
	echo "Generating base image $(BASE_IMAGE) ($$distro, gcc$$gcc, llvm$$llvm, $(ARCH))..."; \
	make -C $(SRC) -f Dockerfile.make DISTRO=$$distro GCC_VER=$$gcc LLVM_VER=$$llvm LLVMSPIRVLIB_VER=$$spirv ARCH=$(ARCH); \
	docker build $(SRC) -t $(BASE_IMAGE); \
	make -C $(SRC) -f Dockerfile.make clean; \
	echo "Baking '$(PROFILE)' dependencies into $(BUILDER_IMAGE) (digest $$digest)..."; \
	DOCKER_BUILDKIT=1 docker build -f $(DOCKERFILE) -t $(BUILDER_IMAGE) \
		--build-arg BASE=$(BASE_IMAGE) --build-arg PROFILE=$(PROFILE) support/; \
	printf '%s\n' "$$digest" > $(IMAGE_STAMP); \
	echo "Builder image ready."

force-image:
	@rm -f $(IMAGE_STAMP)
	@$(MAKE) image

# --entrypoint bash overrides the base image's docker-build.sh ENTRYPOINT (which
# would otherwise hijack our command and re-run the full dependency bake).
build: image
	docker run --rm -e PROFILE=$(PROFILE) --entrypoint bash \
		-v "$(CURDIR):/ws" -w /ws/$(SRC) "$(BUILDER_IMAGE)" /ws/$(BUILD_SCRIPT)
	@echo
	@echo 'Built: $(SRC)/ffmpeg  (run it with: make run)'

# The in-tree ffmpeg links against its own libav*/libsw* .so (each in its own
# module dir) plus the baked deps in TARGET_DIR/lib (already on LD_LIBRARY_PATH
# via the image env); point the loader at the in-tree dirs too.
run: image
	@test -x $(SRC)/ffmpeg || { echo "Not built -- run 'make build' first"; exit 1; }
	docker run --rm -it --entrypoint bash \
		-v "$(CURDIR):/ws" -w /ws/$(SRC) "$(BUILDER_IMAGE)" \
		-c 'for d in libav* libsw* libpostproc; do LD_LIBRARY_PATH=$$PWD/$$d:$$LD_LIBRARY_PATH; done; export LD_LIBRARY_PATH; ./ffmpeg $(if $(ARGS),$(ARGS),-version)'

# Faithful packaging path: identical flow to CI, but -nc (no-clean) reuses the
# incremental object files from `make build`. Native arch only.
package: image
	@test "$(PROFILE)" = "full" || { echo "package needs the full HWA deps: re-run as 'make package PROFILE=full'"; exit 1; }
	docker run --rm --entrypoint bash -v "$(CURDIR):/ws" -w /ws/$(SRC) "$(BUILDER_IMAGE)" \
		-euxc 'dpkg-buildpackage -b -nc -rfakeroot -us -uc; chown -R "$$(stat -c %u:%g /ws)" .'
	@echo
	@echo 'Built .deb(s) in $(SRC)/../ (alongside $(SRC)/).'

# Copy our source patches (everything in the series beyond the pristine jellyfin
# snapshot -- includes quilt-refreshed and newly `quilt new`-ed ones) back to
# $(SRCPATCHES)/ for review/commit. Does not touch jellyfin's patches.
update:
	@set -e; sdir=$(SRC)/debian/patches; \
	test -f $$sdir/series.orig || { echo "No $$sdir/series.orig -- run 'make prepare' first"; exit 1; }; \
	mkdir -p $(SRCPATCHES); \
	for p in $$(grep -vxF -f $$sdir/series.orig $$sdir/series); do \
		echo "Updating $(SRCPATCHES)/$$p"; \
		cp "$$sdir/$$p" "$(SRCPATCHES)/$$p"; \
	done; \
	echo "Source patches copied back to $(SRCPATCHES)/ -- review and commit."

# Re-apply edited source-patches/ onto the EXISTING clone after a build, without a
# re-clone and WITHOUT quilt (the build applies patches via dpkg-source, not quilt).
# Reverse whatever of our copies are actually applied, restage from source-patches/,
# then re-apply with plain `git apply` on top of jellyfin's already-applied patches.
# Only the files our patches touch change, so the next `make build` recompiles
# incrementally. (Use after editing a source-patches/*.patch by hand; if you edited
# the tree via quilt instead, `make build` alone is already incremental.)
repatch:
	@test -f $(SRC)/debian/patches/series.orig || { echo "Run 'make prepare' first"; exit 1; }
	@set -e; sdir=$(SRC)/debian/patches; \
	for p in $$(grep -vxF -f $$sdir/series.orig $$sdir/series 2>/dev/null | tac); do \
		if [ -f "$$sdir/$$p" ] && git -C $(SRC) apply -R --check "debian/patches/$$p" 2>/dev/null; then \
			echo "Reverting $$p"; git -C $(SRC) apply -R "debian/patches/$$p"; \
		fi; \
	done
	@$(MAKE) --no-print-directory stage-source-patches
	@set -e; sdir=$(SRC)/debian/patches; \
	for p in $$(grep -vxF -f $$sdir/series.orig $$sdir/series 2>/dev/null); do \
		echo "Applying $$p"; \
		git -C $(SRC) apply "debian/patches/$$p" || { \
			echo "  apply failed -- run 'make build' once first so jellyfin's patches are applied"; exit 1; }; \
	done
	@echo "Source patches re-applied -- run 'make build' to recompile incrementally."

# Rebase ONLY our source patches against the current source (jellyfin's patches
# are pushed but never refreshed), then copy them back.
refresh:
	@set -e; sdir=$(SRC)/debian/patches; \
	test -f $$sdir/series.orig || { echo "Run 'make prepare' first"; exit 1; }; \
	last_jf=$$(tail -n1 $$sdir/series.orig); \
	cd $(SRC) && QUILTRC=$(QUILTRC) QUILT_PATCHES=debian/patches sh -c '\
		quilt pop -a >/dev/null 2>&1 || true; \
		quilt push "'"$$last_jf"'" >/dev/null; \
		while quilt push; do quilt refresh; done'
	@$(MAKE) --no-print-directory update

clean:
	rm -rf $(SRC)
	rm -f $(IMAGE_STAMP)

clean-image:
	-docker image rm $(BUILDER_IMAGE)
	-docker image rm $(BASE_IMAGE)
	rm -f $(IMAGE_STAMP)
