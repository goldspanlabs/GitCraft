RUST_DIR := rust-core
APP_DIR := macos-app
BUILD_DIR := build
APP := $(BUILD_DIR)/MiniGit.app
UNIFFI := $(RUST_DIR)/target/release/uniffi-bindgen

.PHONY: all rust bindings swift bundle clean

all: bundle

rust:
	cargo build --release --manifest-path $(RUST_DIR)/Cargo.toml

bindings: rust
	@test -x "$(UNIFFI)" || cargo install uniffi_bindgen --version 0.28.3 --root "$(RUST_DIR)/target"
	"$(UNIFFI)" generate "$(RUST_DIR)/minigit_core.udl" --language swift --out-dir "$(APP_DIR)/Sources/Generated"

swift: rust bindings
	cd $(APP_DIR) && swift build -c release -Xlinker -L$(CURDIR)/$(RUST_DIR)/target/release

bundle: swift
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(APP_DIR)/.build/release/MiniGit $(APP)/Contents/MacOS/MiniGit
	cp $(APP_DIR)/Info.plist $(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP)

clean:
	rm -rf $(BUILD_DIR) $(APP_DIR)/.build $(RUST_DIR)/target
