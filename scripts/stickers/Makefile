RLOTTIE_REPOSITORY ?= https://github.com/Samsung/rlottie.git
RLOTTIE_REF ?= master
TOOLS_DIR ?= $(CURDIR)/.tools
SOURCE_DIR := $(TOOLS_DIR)/src/rlottie
BUILD_DIR := $(TOOLS_DIR)/build/rlottie
BIN_DIR := $(TOOLS_DIR)/bin
LOTTIE2GIF := $(BIN_DIR)/lottie2gif
PREFIX ?= $(HOME)/.local
ANIMATED_FORMAT ?= gif
ANIMATED_FPS ?= 30
ANIMATED_SCALE ?= 1
WEBM_CRF ?= 32

.PHONY: all lottie2gif path install macos-deps convert packs clean

all: lottie2gif

# Uses already downloaded and converted WIP packs; no network or bot token.
packs:
	python3 package.py

lottie2gif: $(LOTTIE2GIF)

$(SOURCE_DIR)/.git:
	command -v git >/dev/null || { echo "error: git is required" >&2; exit 1; }
	mkdir -p "$(dir $(SOURCE_DIR))"
	git clone --depth 1 --branch "$(RLOTTIE_REF)" \
		"$(RLOTTIE_REPOSITORY)" "$(SOURCE_DIR)"

# Upstream's formatting helper is named "format". With recent Xcode SDKs it
# shadows libc++'s <format> header because the source root is an include path.
$(SOURCE_DIR)/.parla-header-fix: $(SOURCE_DIR)/.git
	@if [ -f "$(SOURCE_DIR)/format" ]; then \
		mv "$(SOURCE_DIR)/format" "$(SOURCE_DIR)/format.rlottie-tool"; \
	fi
	@touch "$@"

$(BUILD_DIR)/build.ninja: $(SOURCE_DIR)/.git | $(SOURCE_DIR)/.parla-header-fix
	command -v meson >/dev/null || { echo "error: meson is required; run 'make macos-deps'" >&2; exit 1; }
	meson setup "$(BUILD_DIR)" "$(SOURCE_DIR)" \
		--buildtype=release -Ddefault_library=static \
		-Dtest=false -Dexample=true \
		-Dcpp_args=-U__ARM_NEON__

$(LOTTIE2GIF): $(BUILD_DIR)/build.ninja
	meson compile -C "$(BUILD_DIR)" lottie2gif
	mkdir -p "$(BIN_DIR)"
	cp "$(BUILD_DIR)/example/lottie2gif" "$@"

path: $(LOTTIE2GIF)
	@printf '%s\n' "$(LOTTIE2GIF)"

install: $(LOTTIE2GIF)
	mkdir -p "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 "$(LOTTIE2GIF)" "$(DESTDIR)$(PREFIX)/bin/lottie2gif"

macos-deps:
	command -v brew >/dev/null || { echo "error: install Homebrew from https://brew.sh" >&2; exit 1; }
	brew install meson ninja ffmpeg jq webp

convert: $(LOTTIE2GIF)
	@test -n "$(INPUT)" || { echo "usage: make convert INPUT=pack.zip [OUTPUT=converted.zip]" >&2; exit 2; }
	RLOTTIE_CONVERTER="$(LOTTIE2GIF)" \
		ANIMATED_FORMAT="$(ANIMATED_FORMAT)" \
		ANIMATED_FPS="$(ANIMATED_FPS)" \
		ANIMATED_SCALE="$(ANIMATED_SCALE)" \
		WEBM_CRF="$(WEBM_CRF)" \
		./convert.sh "$(INPUT)" $(if $(OUTPUT),"$(OUTPUT)")

clean:
	rm -rf "$(TOOLS_DIR)"
