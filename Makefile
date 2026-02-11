SHELL := /bin/zsh

APP_NAME := AlfredAlternative
APP_BUNDLE := .build/$(APP_NAME).app
APP_BINARY := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
INFO_PLIST := $(APP_BUNDLE)/Contents/Info.plist

.PHONY: bridge build-app run run-cli release

bridge:
	./scripts/generate_swift_bridge.sh

build-app: bridge
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'	<key>CFBundleDevelopmentRegion</key>' \
		'	<string>en</string>' \
		'	<key>CFBundleExecutable</key>' \
		'	<string>AlfredAlternative</string>' \
		'	<key>CFBundleIdentifier</key>' \
		'	<string>com.serkandemirel.alfredalternative</string>' \
		'	<key>CFBundleInfoDictionaryVersion</key>' \
		'	<string>6.0</string>' \
		'	<key>CFBundleName</key>' \
		'	<string>Alfred Alternative</string>' \
		'	<key>CFBundlePackageType</key>' \
		'	<string>APPL</string>' \
		'	<key>CFBundleShortVersionString</key>' \
		'	<string>0.1.0</string>' \
		'	<key>CFBundleVersion</key>' \
		'	<string>1</string>' \
		'	<key>LSMinimumSystemVersion</key>' \
		'	<string>13.0</string>' \
		'	<key>NSHighResolutionCapable</key>' \
		'	<true/>' \
		'	<key>CFBundleIconFile</key>' \
		'	<string>AppIcon</string>' \
		'</dict>' \
		'</plist>' > $(INFO_PLIST)
	@cp resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@LIB_PATH=$$(if [[ -f swift/RustBridge/lib/libalfred_alt_universal.a ]]; then echo swift/RustBridge/lib/libalfred_alt_universal.a; else echo swift/RustBridge/lib/libalfred_alt_host.a; fi); \
	if [[ ! -f "$$LIB_PATH" ]]; then \
		echo "error: Rust static library not found. Expected $$LIB_PATH"; \
		exit 1; \
	fi; \
	swiftc \
		swift/App/*.swift \
		swift/RustBridge/Generated/*.swift \
		-I swift/RustBridge/Generated \
		-Xcc -fmodule-map-file=swift/RustBridge/Generated/alfred_alt.modulemap \
		"$$LIB_PATH" \
		-o $(APP_BINARY)
	@codesign --force --deep --sign - --entitlements entitlements.plist $(APP_BUNDLE)

run:
	$(MAKE) build-app
	open $(APP_BUNDLE)

run-cli: build-app
	$(APP_BINARY)

release:
	./scripts/release.sh
