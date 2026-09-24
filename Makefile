CC = clang
BUILD ?= build
ARCHS ?= -arch arm64 -arch x86_64
SIGN_IDENTITY ?= -
CPPFLAGS = -Iinclude -Ithird_party/zstd
CFLAGS = -O2 -g -Wall -Wextra -MMD -MP
MACFLAGS = -mmacosx-version-min=10.15
SENDFLAGS = -mmacosx-version-min=12.3
FRAMEWORKS = -framework Cocoa -framework CoreVideo -framework CoreMedia -framework VideoToolbox
CORE = $(wildcard src/core/*.c src/core/*/*.c) third_party/zstd/zstd.c
CORE_OBJS = $(patsubst %.c,$(BUILD)/%.o,$(CORE))
SEND_OBJS = $(patsubst %.m,$(BUILD)/%.o,$(wildcard src/sender/*.m))
RECV_OBJS = $(patsubst %.m,$(BUILD)/%.o,$(wildcard src/receiver/*.m))
APP = $(BUILD)/Sharp.app
SWIFT = $(wildcard app/*.swift)

.PHONY: all sharp test clean install package installer
all: sharp
sharp: $(APP)/Contents/MacOS/Sharp

$(BUILD)/%.o: %.c
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(CPPFLAGS) $(CFLAGS) $(MACFLAGS) -std=c11 -c $< -o $@

$(BUILD)/src/sender/%.o: src/sender/%.m
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(CPPFLAGS) $(CFLAGS) $(SENDFLAGS) -fobjc-arc -c $< -o $@

$(BUILD)/src/receiver/%.o: src/receiver/%.m
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(CPPFLAGS) $(CFLAGS) $(MACFLAGS) -fobjc-arc -c $< -o $@

$(BUILD)/SharpSender: $(SEND_OBJS) $(CORE_OBJS)
	$(CC) $(ARCHS) $(SENDFLAGS) $^ $(FRAMEWORKS) -framework ScreenCaptureKit -o $@

$(BUILD)/SharpReceiver: $(RECV_OBJS) $(CORE_OBJS) $(BUILD)/CursorImage.o
	$(CC) $(ARCHS) $(MACFLAGS) $^ $(FRAMEWORKS) -framework OpenGL -framework IOSurface -o $@

$(BUILD)/SharpWatchdog: app/sharp-watchdog.c
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(MACFLAGS) -O2 -Wall -Wextra $< -o $@

$(BUILD)/SharpBenchmarkScene: tools/benchmark-scene.m $(BUILD)/src/core/shtp_net.o
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(CPPFLAGS) $(CFLAGS) $(MACFLAGS) -fobjc-arc $^ -framework Cocoa -framework CoreVideo -o $@

$(BUILD)/CursorImage.o: src/platform/CursorImage.m src/platform/CursorImage.h
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(CFLAGS) $(MACFLAGS) -fobjc-arc -c $< -o $@

$(BUILD)/SharpAudio.o: app/SharpAudio.m app/SharpAudio.h
	@mkdir -p $(@D)
	$(CC) $(ARCHS) $(CFLAGS) $(MACFLAGS) -fobjc-arc -c $< -o $@

$(BUILD)/Sharp.icns: resources/Sharp.png
	@mkdir -p $(@D)
	@mkdir -p $(BUILD)/Sharp.iconset
	@for size in 16 32 128 256 512; do \
		sips -s format png -z $$size $$size $< --out $(BUILD)/Sharp.iconset/icon_$${size}x$${size}.png >/dev/null; \
		double=$$((size * 2)); \
		sips -s format png -z $$double $$double $< --out $(BUILD)/Sharp.iconset/icon_$${size}x$${size}@2x.png >/dev/null; \
	done
	iconutil -c icns $(BUILD)/Sharp.iconset -o $@

$(BUILD)/SharpStatus.png: resources/SharpStatus.svg
	@mkdir -p $(@D)
	sips -s format png $< --out $@ >/dev/null

$(APP)/Contents/MacOS/Sharp: $(SWIFT) app/Info.plist $(BUILD)/CursorImage.o $(BUILD)/SharpAudio.o $(BUILD)/SharpSender $(BUILD)/SharpReceiver $(BUILD)/SharpWatchdog $(BUILD)/SharpBenchmarkScene $(BUILD)/Sharp.icns $(BUILD)/SharpStatus.png resources/Cursors
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers $(APP)/Contents/Resources
	cp app/Info.plist $(APP)/Contents/Info.plist
	cp $(BUILD)/SharpSender $(BUILD)/SharpReceiver $(BUILD)/SharpWatchdog $(BUILD)/SharpBenchmarkScene $(APP)/Contents/Helpers/
	cp $(BUILD)/Sharp.icns $(BUILD)/SharpStatus.png $(APP)/Contents/Resources/
	ditto resources/Cursors $(APP)/Contents/Resources/Cursors
	swiftc -target arm64-apple-macosx11.0 -parse-as-library -import-objc-header app/SharpAudio.h $(SWIFT) $(BUILD)/SharpAudio.o $(BUILD)/CursorImage.o -framework CoreAudio -framework AudioToolbox -o $(BUILD)/Sharp-arm64
	swiftc -target x86_64-apple-macosx10.15 -parse-as-library -import-objc-header app/SharpAudio.h $(SWIFT) $(BUILD)/SharpAudio.o $(BUILD)/CursorImage.o -framework CoreAudio -framework AudioToolbox -o $(BUILD)/Sharp-x86_64
	lipo -create $(BUILD)/Sharp-arm64 $(BUILD)/Sharp-x86_64 -output $@
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app.sender $(APP)/Contents/Helpers/SharpSender
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app.receiver $(APP)/Contents/Helpers/SharpReceiver
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app.watchdog $(APP)/Contents/Helpers/SharpWatchdog
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app.benchmark $(APP)/Contents/Helpers/SharpBenchmarkScene
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app $(APP)

$(BUILD)/%-test: tests/%-test.c $(CORE_OBJS)
	$(CC) $(ARCHS) $(CPPFLAGS) -O2 -Wall -Wextra $(MACFLAGS) $^ -o $@

$(BUILD)/audio-ring-test: tests/audio-ring-test.m app/SharpAudio.m app/SharpAudio.h
	$(CC) $(ARCHS) -O2 -Wall -Wextra $(MACFLAGS) -fobjc-arc $< -framework Foundation -framework CoreAudio -framework AudioToolbox -o $@

test: $(BUILD)/hybrid-test $(BUILD)/tile-correctness-test $(BUILD)/audio-ring-test $(BUILD)/app-state-test
	$(BUILD)/hybrid-test
	$(BUILD)/tile-correctness-test
	$(BUILD)/audio-ring-test
	$(BUILD)/app-state-test

install: sharp
	-osascript -e 'tell application id "sh.sharp.app" to quit'
	ditto $(APP) /Applications/Sharp.app
	open /Applications/Sharp.app

package: sharp
	ditto -c -k --keepParent $(APP) $(BUILD)/Sharp.zip

installer: sharp
	rm -rf $(BUILD)/installer
	mkdir -p $(BUILD)/installer/.background
	ditto $(APP) $(BUILD)/installer/Sharp.app
	ln -s /Applications $(BUILD)/installer/Applications
	swift scripts/dmg-background.swift $(BUILD)/installer/.background/background.png
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app.sender $(BUILD)/installer/Sharp.app/Contents/Helpers/SharpSender
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app.receiver $(BUILD)/installer/Sharp.app/Contents/Helpers/SharpReceiver
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app.watchdog $(BUILD)/installer/Sharp.app/Contents/Helpers/SharpWatchdog
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app.benchmark $(BUILD)/installer/Sharp.app/Contents/Helpers/SharpBenchmarkScene
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier sh.sharp.app $(BUILD)/installer/Sharp.app
	hdiutil create -quiet -volname Sharp -srcfolder $(BUILD)/installer -format UDRW -ov /tmp/Sharp-installer-rw.dmg
	@test ! -e /Volumes/Sharp || { echo 'Eject the mounted Sharp installer before rebuilding'; exit 1; }
	hdiutil attach -quiet -nobrowse /tmp/Sharp-installer-rw.dmg
	@sleep 1
	@osascript scripts/style-dmg.applescript /Volumes/Sharp || { hdiutil detach -quiet /Volumes/Sharp; exit 1; }
	@sync
	hdiutil detach -quiet /Volumes/Sharp
	hdiutil convert /tmp/Sharp-installer-rw.dmg -quiet -format UDZO -ov -o $(BUILD)/Sharp-macOS-universal.dmg
	rm -f /tmp/Sharp-installer-rw.dmg
	rm -rf $(BUILD)/installer
	hdiutil verify -quiet $(BUILD)/Sharp-macOS-universal.dmg

clean:
	rm -rf $(BUILD)

-include $(CORE_OBJS:.o=.d) $(SEND_OBJS:.o=.d) $(RECV_OBJS:.o=.d) $(BUILD)/SharpAudio.d

MODEL_SWIFT = $(filter-out app/SharpApp.swift app/Views.swift,$(SWIFT))
$(BUILD)/app-state-test: tests/AppState.swift $(MODEL_SWIFT) $(BUILD)/SharpAudio.o $(BUILD)/CursorImage.o
	swiftc -parse-as-library -import-objc-header app/SharpAudio.h $(MODEL_SWIFT) $< $(BUILD)/SharpAudio.o $(BUILD)/CursorImage.o -framework CoreAudio -framework AudioToolbox -o $@
