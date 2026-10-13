SHELL := /bin/zsh
PREFIX ?= /usr/local
BUILD_DIR := $(CURDIR)/build
PRODUCT := $(CURDIR)/.build/release/siri-tts

.PHONY: all build debug test client-test live-test smoke benchmark install uninstall clean

all: build

build:
	swift build -c release
	mkdir -p "$(BUILD_DIR)"
	cp "$(PRODUCT)" "$(BUILD_DIR)/siri-tts"
	codesign --force --sign - "$(BUILD_DIR)/siri-tts"

debug:
	swift build

test:
	swift test
	$(MAKE) client-test

client-test:
	swift build --package-path Tests/Fixtures/SiriTTSClientConsumer

live-test: build
	SIRI_TTS_LIVE_TESTS=1 swift test --filter 'Live(System|Redesign)Tests'
	SIRI_TTS_BIN="$(BUILD_DIR)/siri-tts" ./scripts/client-live-smoke.sh

smoke: build
	SIRI_TTS_BIN="$(BUILD_DIR)/siri-tts" ./scripts/smoke.sh

benchmark: build
	SIRI_TTS_BIN="$(BUILD_DIR)/siri-tts" ./scripts/benchmark.sh

install: build
	install -d "$(DESTDIR)$(PREFIX)/bin"
	install -m 755 "$(BUILD_DIR)/siri-tts" "$(DESTDIR)$(PREFIX)/bin/siri-tts"

uninstall:
	rm -f "$(DESTDIR)$(PREFIX)/bin/siri-tts"

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"
