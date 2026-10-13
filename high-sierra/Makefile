SHARP ?= ..
BUILD = build
APP = $(BUILD)/Sharp Receiver.app
FLAGS = -arch x86_64 -mmacosx-version-min=10.13 -O2 -fobjc-arc -Wall -Wextra -Werror=unguarded-availability -Werror=unguarded-availability-new

.PHONY: all engine installer test
all: engine
	$(MAKE) $(BUILD)/receiver.stamp

engine:
	$(MAKE) -C $(SHARP) BUILD="$(CURDIR)/$(BUILD)/engine" ARCHS='-arch x86_64' MACFLAGS='-mmacosx-version-min=10.13 -Werror=unguarded-availability -Werror=unguarded-availability-new' "$(CURDIR)/$(BUILD)/engine/SharpReceiver"
	$(MAKE) -C $(SHARP) build/Sharp.icns

$(BUILD)/receiver.stamp: ReceiverApp.m Info.plist $(SHARP)/app/SharpAudio.m $(BUILD)/engine/SharpReceiver $(SHARP)/build/Sharp.icns
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Helpers" "$(APP)/Contents/Resources"
	clang $(FLAGS) -I$(SHARP)/include ReceiverApp.m $(SHARP)/app/SharpAudio.m -framework Cocoa -framework IOKit -framework SystemConfiguration -framework CoreAudio -framework AudioToolbox -o "$(APP)/Contents/MacOS/SharpReceiverApp"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp $(BUILD)/engine/SharpReceiver "$(APP)/Contents/Helpers/SharpReceiver"
	cp $(SHARP)/build/Sharp.icns "$(APP)/Contents/Resources/Sharp.icns"
	ditto $(SHARP)/resources/Cursors "$(APP)/Contents/Resources/Cursors"
	codesign --force --sign - "$(APP)/Contents/Helpers/SharpReceiver"
	codesign --force --sign - "$(APP)"
	touch $@

installer: all
	./package.sh

test: all
	python3 test_receiver.py
