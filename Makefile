APP_NAME = NeckRelief
BUNDLE_ID = com.hayhaydz.neckrelief
INSTALL_DIR = $(HOME)/Applications
APP_DIR = $(INSTALL_DIR)/$(APP_NAME).app

# Stable self-signed identity keeps the Accessibility grant valid across rebuilds;
# falls back to ad-hoc signing (grant breaks on every reinstall) if not installed.
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(NeckRelief Dev\)".*/\1/p')

.PHONY: build test run install open clean logs

logs:
	@log stream --predicate 'subsystem == "com.hayhaydz.neckrelief"' --style compact

# Plain `swift build` fails under a pure Command Line Tools install (XCBuild
# init error); point DEVELOPER_DIR at Xcode when it's present, like `test` does.
build:
	@if [ -d /Applications/Xcode.app ]; then \
		DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release; \
	else \
		swift build -c release; \
	fi

test:
	@if [ -d /Applications/Xcode.app ]; then \
		DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test; \
	else \
		swift test; \
	fi

run: build
	.build/release/$(APP_NAME)

install: build
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp .build/release/NeckRelief "$(APP_DIR)/Contents/MacOS/$(APP_NAME)"
	cp Support/Info.plist "$(APP_DIR)/Contents/Info.plist"
ifneq ($(SIGN_IDENTITY),)
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP_DIR)"
	@echo "Signed with stable identity: $(SIGN_IDENTITY)"
else
	codesign --force --sign - "$(APP_DIR)"
	@echo "WARNING: signed ad-hoc — Accessibility grant will break on every reinstall."
endif
	@echo "Installed → $(APP_DIR)"

open: install
	open "$(APP_DIR)"

clean:
	swift package clean
	rm -rf "$(APP_DIR)"
