RUST_DIR := rust-core
APP_DIR := macos-app
BUILD_DIR := build
APP := $(BUILD_DIR)/MiniGit.app

.PHONY: all rust swift bundle clean

all: bundle

rust:
	cargo build --release --manifest-path $(RUST_DIR)/Cargo.toml

swift: rust
	cd $(APP_DIR) && swift build -c release

bundle: swift
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(APP_DIR)/.build/release/MiniGit $(APP)/Contents/MacOS/MiniGit
	cp $(APP_DIR)/Info.plist $(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP)

clean:
	rm -rf $(BUILD_DIR) $(APP_DIR)/.build $(RUST_DIR)/target
