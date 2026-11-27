RUST_DIR := rust-core
APP_DIR := macos-app
BUILD_DIR := build
APP := $(BUILD_DIR)/GitCraft.app
UNIFFI := $(RUST_DIR)/target/release/uniffi-bindgen

SWIFT_FLAGS := -Xswiftc "-I$(CURDIR)/$(APP_DIR)/Sources/Generated" -Xcc "-fmodule-map-file=$(CURDIR)/$(APP_DIR)/Sources/Generated/gitcraft_coreFFI.modulemap" -Xlinker "-L$(CURDIR)/$(RUST_DIR)/target/release"

.PHONY: all rust bindings swift test-swift ui-tests bundle dmg clean

all: bundle

rust:
	cargo build --release --manifest-path $(RUST_DIR)/Cargo.toml

bindings: rust
	@set -eu; \
	TMP_DIR="$$(mktemp -d)"; \
	trap 'rm -rf "$$TMP_DIR"' EXIT; \
	cargo run --release --manifest-path $(RUST_DIR)/Cargo.toml --bin uniffi-bindgen -- generate "$(RUST_DIR)/src/gitcraft_core.udl" --language swift --crate gitcraft_core --out-dir "$$TMP_DIR"; \
	mkdir -p "$(APP_DIR)/Sources/Generated"; \
	for f in "$$TMP_DIR"/*; do \
		dest="$(APP_DIR)/Sources/Generated/$$(basename "$$f")"; \
		if [ ! -f "$$dest" ] || ! cmp -s "$$f" "$$dest"; then \
			cp "$$f" "$$dest"; \
		fi; \
	done

swift: rust bindings
	cd "$(APP_DIR)" && swift build -c release $(SWIFT_FLAGS)

test-swift: rust bindings
	cd "$(APP_DIR)" && swift test $(SWIFT_FLAGS)

ui-tests: bundle
	cd $(APP_DIR)/UITests && xcodegen generate --spec project.yml --project .
	TEST_RUNNER_GITCRAFT_APP_PATH=$(CURDIR)/$(APP) xcodebuild test -project $(APP_DIR)/UITests/GitCraftUITests.xcodeproj -scheme GitCraftUITests -destination 'platform=macOS'

bundle: swift
	rm -rf $(APP) $(BUILD_DIR)/AppIcon.iconset
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(APP_DIR)/.build/release/GitCraft $(APP)/Contents/MacOS/GitCraft
	@SDK_VER="$$(xcrun --show-sdk-version 2>/dev/null || true)"; \
	if [ -n "$$SDK_VER" ] && xcrun --find vtool >/dev/null 2>&1; then \
		xcrun vtool -set-build-version macos 15.0 "$$SDK_VER" -replace \
			-output $(APP)/Contents/MacOS/GitCraft $(APP)/Contents/MacOS/GitCraft; \
	fi
	cp $(APP_DIR)/Info.plist $(APP)/Contents/Info.plist
	@if xcrun --find actool >/dev/null 2>&1; then \
		xcrun actool $(APP_DIR)/Resources/Assets.xcassets \
			--compile $(APP)/Contents/Resources \
			--platform macosx \
			--minimum-deployment-target 15.0 \
			--app-icon AppIcon \
			--output-partial-info-plist $(BUILD_DIR)/assetcatalog_generated_info.plist >/dev/null 2>&1 || true; \
	fi
	@if [ ! -f $(APP)/Contents/Resources/Assets.car ] && [ ! -f $(APP)/Contents/Resources/AppIcon.icns ]; then \
		echo "actool produced no icon; falling back to iconutil"; \
		mkdir -p $(BUILD_DIR)/AppIcon.iconset; \
		sips -z 16 16     $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16.png >/dev/null; \
		sips -z 32 32     $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_16x16@2x.png >/dev/null; \
		sips -z 32 32     $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32.png >/dev/null; \
		sips -z 64 64     $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_32x32@2x.png >/dev/null; \
		sips -z 128 128   $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128.png >/dev/null; \
		sips -z 256 256   $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png >/dev/null; \
		sips -z 256 256   $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256.png >/dev/null; \
		sips -z 512 512   $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_256x256@2x.png >/dev/null; \
		sips -z 512 512   $(APP_DIR)/Resources/AppIcon-1024.png --out $(BUILD_DIR)/AppIcon.iconset/icon_512x512.png >/dev/null; \
		cp $(APP_DIR)/Resources/AppIcon-1024.png $(BUILD_DIR)/AppIcon.iconset/icon_512x512@2x.png; \
		iconutil -c icns $(BUILD_DIR)/AppIcon.iconset -o $(APP)/Contents/Resources/AppIcon.icns; \
		rm -rf $(BUILD_DIR)/AppIcon.iconset; \
	fi
	cp $(APP_DIR)/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Light-1024.png $(APP)/Contents/Resources/AppIcon-Light.png
	cp $(APP_DIR)/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark-1024.png $(APP)/Contents/Resources/AppIcon-Dark.png
	python3 scripts/generate_licenses.py --manifest-path $(RUST_DIR)/Cargo.toml --output $(APP)/Contents/Resources/THIRD_PARTY_LICENSES.txt
	codesign --force --deep --sign - $(APP)

dmg: bundle
	rm -rf $(BUILD_DIR)/dmg-staging $(BUILD_DIR)/GitCraft.dmg
	mkdir -p $(BUILD_DIR)/dmg-staging
	cp -R $(APP) $(BUILD_DIR)/dmg-staging/
	ln -s /Applications $(BUILD_DIR)/dmg-staging/Applications
	hdiutil create -volname "GitCraft" -srcfolder $(BUILD_DIR)/dmg-staging -ov -format UDZO $(BUILD_DIR)/GitCraft.dmg
	rm -rf $(BUILD_DIR)/dmg-staging

clean:
	rm -rf $(BUILD_DIR) $(APP_DIR)/.build $(RUST_DIR)/target
