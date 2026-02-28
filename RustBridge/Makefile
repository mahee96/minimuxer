TARGET=rust_bridge
RUST_DIR="."
SCHEME=Minimuxer
BUILD_DIR=build
FRAMEWORK_NAME=Minimuxer

.PHONY: all build rust clean framework xcframework zip

# --- Core Build ---

all: build

build: rust

rust:
	@echo "--- Building Rust Bridge ---"

	@# iOS device (arm64)
	cd $(RUST_DIR) && cargo build --target aarch64-apple-ios --release

	@# iOS Simulator (Apple Silicon)
	cd $(RUST_DIR) && cargo build --target aarch64-apple-ios-sim --release

	@# macOS (arm64)
	cd $(RUST_DIR) && cargo build --target aarch64-apple-darwin --release

	@mkdir -p $(RUST_DIR)/lib

	@# copy outputs
	cp $(RUST_DIR)/target/aarch64-apple-ios/release/lib$(TARGET).a \
	   $(RUST_DIR)/lib/lib$(TARGET)-ios.a

	cp $(RUST_DIR)/target/aarch64-apple-ios-sim/release/lib$(TARGET).a \
	   $(RUST_DIR)/lib/lib$(TARGET)-ios-sim.a

	cp $(RUST_DIR)/target/aarch64-apple-darwin/release/lib$(TARGET).a \
	   $(RUST_DIR)/lib/lib$(TARGET)-macos.a


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
	@echo "--- Building .xcframework (iOS + Simulator + macOS) ---"

	@# iOS device
	xcodebuild archive \
		-scheme $(SCHEME) \
		-destination "generic/platform=iOS" \
		-archivePath $(BUILD_DIR)/$(FRAMEWORK_NAME)-iOS.xcarchive \
		SKIP_INSTALL=NO \
		BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
		OTHER_LDFLAGS="-L$$(pwd)/$(RUST_DIR)/lib -l$(TARGET)"

	@# iOS Simulator
	xcodebuild archive \
		-scheme $(SCHEME) \
		-destination "generic/platform=iOS Simulator" \
		-archivePath $(BUILD_DIR)/$(FRAMEWORK_NAME)-Simulator.xcarchive \
		SKIP_INSTALL=NO \
		BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
		OTHER_LDFLAGS="-L$$(pwd)/$(RUST_DIR)/lib -l$(TARGET)"

	@# macOS
	xcodebuild archive \
		-scheme $(SCHEME) \
		-destination "generic/platform=macOS" \
		-archivePath $(BUILD_DIR)/$(FRAMEWORK_NAME)-macOS.xcarchive \
		SKIP_INSTALL=NO \
		BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
		OTHER_LDFLAGS="-L$$(pwd)/$(RUST_DIR)/lib -l$(TARGET)"

	@# Create xcframework
	xcodebuild -create-xcframework \
		-framework $(BUILD_DIR)/$(FRAMEWORK_NAME)-iOS.xcarchive/Products/Library/Frameworks/$(FRAMEWORK_NAME).framework \
		-framework $(BUILD_DIR)/$(FRAMEWORK_NAME)-Simulator.xcarchive/Products/Library/Frameworks/$(FRAMEWORK_NAME).framework \
		-framework $(BUILD_DIR)/$(FRAMEWORK_NAME)-macOS.xcarchive/Products/Library/Frameworks/$(FRAMEWORK_NAME).framework \
		-output $(BUILD_DIR)/$(FRAMEWORK_NAME).xcframework

zip: xcframework
	@echo "--- Creating zip ---"
	cd $(BUILD_DIR) && zip -r $(FRAMEWORK_NAME).xcframework.zip $(FRAMEWORK_NAME).xcframework


# --- Cleanup ---

clean:
	@echo "--- Cleaning project ---"
	cd $(RUST_DIR) && cargo clean
	rm -rf $(RUST_DIR)/lib
	rm -rf .build $(BUILD_DIR)
