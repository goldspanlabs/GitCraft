RUST_DIR := rust-core
APP_DIR := macos-app
BUILD_DIR := build
APP := $(BUILD_DIR)/GitCraft.app
UNIFFI := $(RUST_DIR)/target/release/uniffi-bindgen

.PHONY: all rust bindings swift bundle clean

all: bundle

rust:
	cargo build --release --manifest-path $(RUST_DIR)/Cargo.toml

bindings: rust
	cargo run --release --manifest-path $(RUST_DIR)/Cargo.toml --bin uniffi-bindgen -- generate "$(RUST_DIR)/minigit_core.udl" --language swift --crate minigit_core --out-dir "$(APP_DIR)/Sources/Generated"

swift: rust bindings
	cd "$(APP_DIR)" && swift build -c release -Xswiftc "-I$(CURDIR)/$(APP_DIR)/Sources/Generated" -Xcc "-fmodule-map-file=$(CURDIR)/$(APP_DIR)/Sources/Generated/minigit_coreFFI.modulemap" -Xlinker "-L$(CURDIR)/$(RUST_DIR)/target/release"

bundle: swift
	rm -rf $(APP) $(BUILD_DIR)/AppIcon.iconset
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(APP_DIR)/.build/release/GitCraft $(APP)/Contents/MacOS/GitCraft
	@SDK_VER="$$(xcrun --show-sdk-version 2>/dev/null || true)"; \
	if [ -n "$$SDK_VER" ] && xcrun --find vtool >/dev/null 2>&1; then \
		xcrun vtool -set-build-version macos 13.0 15.0 -replace \
			-output $(APP)/Contents/MacOS/GitCraft $(APP)/Contents/MacOS/GitCraft; \
	fi
	cp $(APP_DIR)/Info.plist $(APP)/Contents/Info.plist
	@if xcrun --find actool >/dev/null 2>&1; then \
		xcrun actool $(APP_DIR)/Resources/Assets.xcassets \
			--compile $(APP)/Contents/Resources \
			--platform macosx \
			--minimum-deployment-target 13.0 \
			--app-icon AppIcon \
			--output-partial-info-plist $(BUILD_DIR)/assetcatalog_generated_info.plist >/dev/null; \
	else \
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
	codesign --force --deep --sign - $(APP)

clean:
	rm -rf $(BUILD_DIR) $(APP_DIR)/.build $(RUST_DIR)/target
