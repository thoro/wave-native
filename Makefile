# Copyright 2026, Command Line Inc.
# SPDX-License-Identifier: Apache-2.0
#
# Thin wrapper over scripts/. The real logic lives in the shell scripts; these
# targets just give them memorable names and chain the build → bundle → notarize flow.
#
#   make app          debug build, bundle into dist/WaveNative.app, run it
#   make dev          debug build, run FOREGROUND in the isolated test home (logs → terminal)
#   make bundle       release build + bundle (ad-hoc signed, local only)
#   make release      bundle + Developer ID sign + notarize + staple (ship build)
#   make sign         bundle + Developer ID sign only (no notarize)
#   make wavesrv      rebuild the bundled Go server (bin/wavesrv.arm64)
#   make run          debug build + bundle + open
#   make testapp      side-by-side TEST build (WaveNativeTest.app, isolated settings dir), run it
#   make testbundle   the same TEST build without launching it
#   make clean        remove dist/ and .build/

.PHONY: app bundle release sign wavesrv run dev testapp testbundle clean

SWIFT_FLAGS := -Xcc -Ivendor/libghostty/include -Xlinker -Lvendor/libghostty/lib
PARENT := $(abspath ..)

# Identity + isolated settings home for the side-by-side test build. It writes to
# ~/Library/Application Support/waveterm-native-test (baked into LSEnvironment), so it
# never touches the real waveterm-native home and runs alongside the main app.
TEST_APP_NAME := WaveNativeTest
TEST_APP_DISPLAY := Wave Native (Test)
TEST_APP_BUNDLE_ID := dev.commandline.wave-native.test
TEST_DATA_HOME := $(HOME)/Library/Application Support/waveterm-native-test

TEST_ENV := WAVE_APP_NAME="$(TEST_APP_NAME)" \
	WAVE_APP_DISPLAY_NAME="$(TEST_APP_DISPLAY)" \
	WAVE_APP_BUNDLE_ID="$(TEST_APP_BUNDLE_ID)" \
	WAVE_DATA_HOME="$(TEST_DATA_HOME)"

app run:
	./scripts/bundle-app.sh debug
	open dist/WaveNative.app

# Debug build run in the FOREGROUND directly from the binary, so the app's own logs
# (NSLog/print/stderr) stream to THIS terminal (`open` routes them to the unified log).
# Runs in the ISOLATED test namespace/home so it never disturbs — or hands off to — a live
# Wave: a shared data home makes the single-instance gate hand the launch off and exit at
# once (no foreground), so isolation is also what keeps it in the terminal. A direct run
# doesn't get the bundle's LSEnvironment, so the home is passed explicitly. wavesrv's Go
# logs go to $(TEST_DATA_HOME)/wavesrv.log. Ctrl-C stops the app.
dev:
	$(TEST_ENV) ./scripts/bundle-app.sh debug
	WAVETERM_DATA_HOME="$(TEST_DATA_HOME)" WAVETERM_CONFIG_HOME="$(TEST_DATA_HOME)/config" \
		"dist/$(TEST_APP_NAME).app/Contents/MacOS/WaveApp"

bundle:
	./scripts/bundle-app.sh release

testapp:
	$(TEST_ENV) ./scripts/bundle-app.sh debug
	open "dist/$(TEST_APP_NAME).app"

testbundle:
	$(TEST_ENV) ./scripts/bundle-app.sh release

# Ship build: bundle first (release), THEN Developer ID sign + notarize + staple.
# Codesigning must be the last step — re-bundling re-signs ad-hoc and discards it.
release: bundle
	./scripts/sign-and-notarize.sh

sign: bundle
	./scripts/sign-and-notarize.sh --sign-only

# Rebuild the Go server that bundle-app.sh copies in as Resources/wavesrv.
wavesrv:
	cd $(PARENT) && CGO_ENABLED=1 GOARCH=arm64 go build \
		-tags "osusergo,sqlite_omit_load_extension" \
		-o wave-native/bin/wavesrv.arm64 cmd/server/main-server.go

# Rebuild the wsh binary that backs durable shells (the "wsh jobmanager" daemon).
# bundle-app.sh copies it into Resources/bin/; wavesrv resolves it under
# $WAVETERM_APP_PATH/bin (cwd-relative bin/ in the dev run).
wsh:
	cd $(PARENT) && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build \
		-o wave-native/bin/wsh-0.0.0-darwin.arm64 ./cmd/wsh

clean:
	rm -rf dist .build
