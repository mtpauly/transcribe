APP_NAME := Transcribe
SWIFT_PRODUCT := transcribe
EXECUTABLE := transcribe
BUNDLE_ID := com.mattpauly.transcribe
BUILD_DIR := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP_BUNDLE)/Contents
ENTITLEMENTS := bundle/Transcribe.entitlements
SIGN_IDENTITY ?= Transcribe Dev
SIGN_FLAGS ?= --timestamp=none
SWIFT_FLAGS ?=

.PHONY: test app run stop verify logs clean

test:
	swift test $(SWIFT_FLAGS)

app:
	swift build $(SWIFT_FLAGS) -c release --product "$(SWIFT_PRODUCT)"
	rm -rf "$(APP_BUNDLE)"
	mkdir -p "$(CONTENTS)/MacOS"
	cp bundle/Info.plist "$(CONTENTS)/Info.plist"
	cp ".build/release/$(SWIFT_PRODUCT)" "$(CONTENTS)/MacOS/$(EXECUTABLE)"
	codesign --force --options runtime $(SIGN_FLAGS) --entitlements "$(ENTITLEMENTS)" --sign "$(SIGN_IDENTITY)" --identifier "$(BUNDLE_ID)" "$(APP_BUNDLE)"

run: stop app
	open -g "$(APP_BUNDLE)"

stop:
	@pkill -TERM -x "$(EXECUTABLE)" 2>/dev/null || true
	@for attempt in $$(seq 1 50); do \
		if ! pgrep -x "$(EXECUTABLE)" >/dev/null 2>&1; then exit 0; fi; \
		sleep 0.1; \
	done; \
	echo "$(EXECUTABLE) did not stop" >&2; \
	exit 1

verify: app
	codesign --verify --deep --strict --verbose=2 "$(APP_BUNDLE)"
	codesign -d --entitlements - "$(APP_BUNDLE)"
	plutil -lint "$(CONTENTS)/Info.plist"
	plutil -lint "$(ENTITLEMENTS)"

logs:
	tail -f "$$HOME/Library/Logs/$(APP_NAME).log"

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"
