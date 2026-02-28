SIDESTORE_REPO ?= ../../../SideStore
TARGET=rust_bridge
RUST_DIR=Sources/RustBridge
SCHEME=Minimuxer
BUILD_DIR=build
FRAMEWORK_NAME=Minimuxer

.PHONY: all build rust swift clean framework xcframework zip

# --- Core Build ---

all: build

build: rust swift

rust:
	@echo "--- Building Rust Bridge ---"
	cd $(RUST_DIR) && cargo build --release
	@mkdir -p $(RUST_DIR)/lib
	cp $(RUST_DIR)/target/release/lib$(TARGET).a $(RUST_DIR)/lib/

swift:
	@echo "--- Building Swift (RustBridge + Minimuxer) ---"
	swift build

# --- Framework Targets ---

framework: rust
	@echo "--- Building .framework (iOS arm64) ---"
	xcodebuild archive \
		-scheme $(SCHEME) \
		-destination "generic/platform=iOS" \
		-archivePath $(BUILD_DIR)/$(FRAMEWORK_NAME)-iOS.xcarchive \
		SKIP_INSTALL=NO \
		BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
		OTHER_LDFLAGS="-L$$(pwd)/$(RUST_DIR)/lib -l$(TARGET)"

xcframework: rust
	@echo "--- Building .xcframework (iOS + Simulator) ---"
	@# Archive for iOS device
	xcodebuild archive \
		-scheme $(SCHEME) \
		-destination "generic/platform=iOS" \
		-archivePath $(BUILD_DIR)/$(FRAMEWORK_NAME)-iOS.xcarchive \
		SKIP_INSTALL=NO \
		BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
		OTHER_LDFLAGS="-L$$(pwd)/$(RUST_DIR)/lib -l$(TARGET)"
	@# Archive for iOS Simulator
	xcodebuild archive \
		-scheme $(SCHEME) \
		-destination "generic/platform=iOS Simulator" \
		-archivePath $(BUILD_DIR)/$(FRAMEWORK_NAME)-Simulator.xcarchive \
		SKIP_INSTALL=NO \
		BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
		OTHER_LDFLAGS="-L$$(pwd)/$(RUST_DIR)/lib -l$(TARGET)"
	@# Create xcframework
	xcodebuild -create-xcframework \
		-framework $(BUILD_DIR)/$(FRAMEWORK_NAME)-iOS.xcarchive/Products/Library/Frameworks/$(FRAMEWORK_NAME).framework \
		-framework $(BUILD_DIR)/$(FRAMEWORK_NAME)-Simulator.xcarchive/Products/Library/Frameworks/$(FRAMEWORK_NAME).framework \
		-output $(BUILD_DIR)/$(FRAMEWORK_NAME).xcframework

zip: xcframework
	@echo "--- Creating zip ---"
	cd $(BUILD_DIR) && zip -r $(FRAMEWORK_NAME).xcframework.zip $(FRAMEWORK_NAME).xcframework

# --- Cleanup ---

clean:
	@echo "--- Cleaning project ---"
	cd $(RUST_DIR) && cargo clean
	rm -rf $(RUST_DIR)/lib
	swift package clean
	rm -rf .build $(BUILD_DIR)
