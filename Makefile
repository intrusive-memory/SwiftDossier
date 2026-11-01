# SwiftDossier Makefile
#
# This file is an interface: exit criteria and CI jobs are phrased as `make`
# targets, so the strings below are defined once. All builds and tests go
# through xcodebuild; SwiftPM's own drivers are not used in this project.

# The pinned dossier-format revision. Defined ONLY here.
DOSSIER_FORMAT_REF = v2.0.0-rc.3
DOSSIER_FORMAT_URL = https://github.com/intrusive-memory/dossier-format
FIXTURES_DIR = .dossier-format

# The -Package scheme contains every target, including the test targets.
SCHEME = SwiftDossier-Package
CLI_SCHEME = dossier
BINARY = dossier
BIN_DIR = ./bin

DESTINATION = 'platform=macOS,arch=arm64'
IOS_DESTINATION = 'platform=iOS Simulator,name=iPhone 17,OS=latest'
ARCH = ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
XCODE_FLAGS = -skipPackagePluginValidation -skipMacroValidation
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData

# Optional: TEST_FILTER=<name> make test. A test target (DossierCoreTests), a
# Target/Suite path, or a bare suite name (SchemaEvaluatorTests), which is found
# by the file under Tests/ that declares it. xcodebuild's -only-testing needs
# the target, so a bare name that matches no suite is passed through unchanged.
ifdef TEST_FILTER
TEST_ONLY = -only-testing:$(shell scripts/test-filter.sh "$(TEST_FILTER)")
endif

.PHONY: help build test test-ios fixtures release install clean resolve acceptance

.DEFAULT_GOAL := help

help:
	@echo "SwiftDossier - available targets:"
	@echo "  help        - Show this help message (default)"
	@echo "  build       - Build every target for macOS (arm64)"
	@echo "  test        - Run the test suite on macOS (arm64); honours TEST_FILTER; runs fixtures first"
	@echo "  test-ios    - Run the test suite on the iPhone 17 simulator; runs fixtures first"
	@echo "  fixtures    - Fetch dossier-format $(DOSSIER_FORMAT_REF) into $(FIXTURES_DIR)/"
	@echo "  release     - Release build of the dossier CLI, copied to $(BIN_DIR)/"
	@echo "  install     - Debug build of the dossier CLI, copied to $(BIN_DIR)/"
	@echo "  clean       - Remove build artifacts, $(BIN_DIR)/, and DerivedData"
	@echo "  resolve     - Resolve package dependencies"
	@echo "  acceptance  - Acceptance run (stub; Sortie 10 fills it)"
	@echo ""
	@echo "macOS destination: $(DESTINATION)"
	@echo "iOS destination:   $(IOS_DESTINATION)"

build:
	xcodebuild build -scheme $(SCHEME) \
	  -destination $(DESTINATION) \
	  $(XCODE_FLAGS) \
	  CODE_SIGNING_ALLOWED=NO \
	  $(ARCH)

test: fixtures
	xcodebuild test -scheme $(SCHEME) \
	  -destination $(DESTINATION) \
	  $(TEST_ONLY) \
	  $(XCODE_FLAGS) \
	  CODE_SIGNING_ALLOWED=NO \
	  $(ARCH)

test-ios: fixtures
	xcodebuild test -scheme $(SCHEME) \
	  -destination $(IOS_DESTINATION) \
	  $(TEST_ONLY) \
	  $(XCODE_FLAGS) \
	  COMPILER_INDEX_STORE_ENABLE=NO \
	  $(ARCH)

# Shallow clone of the pinned tag. Skipped when the directory is already at the
# ref. Never reads or writes any other dossier-format checkout.
fixtures:
	@if [ -d $(FIXTURES_DIR)/.git ] && \
	   [ "$$(git -C $(FIXTURES_DIR) describe --tags --exact-match 2>/dev/null)" = "$(DOSSIER_FORMAT_REF)" ]; then \
		echo "$(FIXTURES_DIR) already at $(DOSSIER_FORMAT_REF)"; \
	else \
		rm -rf $(FIXTURES_DIR); \
		git clone --quiet --depth 1 --branch $(DOSSIER_FORMAT_REF) $(DOSSIER_FORMAT_URL) $(FIXTURES_DIR) && \
		echo "Fetched dossier-format $(DOSSIER_FORMAT_REF) into $(FIXTURES_DIR)"; \
	fi

release: resolve
	xcodebuild build -scheme $(CLI_SCHEME) \
	  -destination $(DESTINATION) \
	  -configuration Release \
	  $(XCODE_FLAGS) \
	  $(ARCH)
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(ls -td $(DERIVED_DATA)/SwiftDossier-*/Build/Products/Release 2>/dev/null | head -1); \
	if [ -n "$$PRODUCT_DIR" ] && [ -x "$$PRODUCT_DIR/$(BINARY)" ]; then \
		cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
		echo "Installed $(BINARY) to $(BIN_DIR)/ (Release)"; \
	else \
		echo "Error: could not find $(BINARY) in $(DERIVED_DATA)/SwiftDossier-*/Build/Products/Release"; \
		exit 1; \
	fi

install: resolve
	xcodebuild build -scheme $(CLI_SCHEME) \
	  -destination $(DESTINATION) \
	  $(XCODE_FLAGS) \
	  $(ARCH)
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(ls -td $(DERIVED_DATA)/SwiftDossier-*/Build/Products/Debug 2>/dev/null | head -1); \
	if [ -n "$$PRODUCT_DIR" ] && [ -x "$$PRODUCT_DIR/$(BINARY)" ]; then \
		cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
		echo "Installed $(BINARY) to $(BIN_DIR)/ (Debug)"; \
	else \
		echo "Error: could not find $(BINARY) in $(DERIVED_DATA)/SwiftDossier-*/Build/Products/Debug"; \
		exit 1; \
	fi

resolve:
	xcodebuild -resolvePackageDependencies -scheme $(SCHEME) -destination $(DESTINATION)

clean:
	xcodebuild clean -scheme $(SCHEME) -destination $(DESTINATION) $(ARCH)
	rm -rf .build
	rm -rf $(BIN_DIR)
	rm -rf $(DERIVED_DATA)/SwiftDossier-*

acceptance:
	@echo "acceptance: not implemented yet; Sortie 10 fills this target."
