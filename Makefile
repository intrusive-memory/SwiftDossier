# SwiftDossier Makefile
#
# This file is an interface: exit criteria and CI jobs are phrased as `make`
# targets, so the strings below are defined once. All builds and tests go
# through xcodebuild; SwiftPM's own drivers are not used in this project.

# The pinned dossier-format revision. Defined ONLY here.
DOSSIER_FORMAT_REF = v2.0.0-rc.6
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
# xcodebuild instruments a package's CLI for coverage even in Release, which leaves a profile runtime
# in the shipped binary. `release` and `install` turn it off, and `smoke` fails if it comes back.
NO_COVERAGE = CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO ENABLE_CODE_COVERAGE=NO

DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData

# Optional: TEST_FILTER=<name> make test. A test target (DossierCoreTests), a
# Target/Suite path, or a bare suite name (SchemaEvaluatorTests), which is found
# by the file under Tests/ that declares it. xcodebuild's -only-testing needs
# the target, so a bare name that matches no suite is passed through unchanged.
ifdef TEST_FILTER
TEST_ONLY = -only-testing:$(shell scripts/test-filter.sh "$(TEST_FILTER)")
endif

# Optional: SPEC_DIR=<path> runs the tests against that dossier-format tree (a local clone on any
# commit) in place of the fetched $(DOSSIER_FORMAT_REF) tag. `make fixtures` then neither fetches
# nor touches anything, and the tree is read, never written. The pin above is unchanged. The
# path reaches the test process as DOSSIER_SPEC_DIR (xcodebuild forwards TEST_RUNNER_*).
ifneq ($(strip $(SPEC_DIR)),)
SPEC_ABS = $(abspath $(SPEC_DIR))
SPEC_ENV = TEST_RUNNER_DOSSIER_SPEC_DIR=$(SPEC_ABS)
endif

.PHONY: help build test test-ios fixtures release smoke install clean resolve acceptance

.DEFAULT_GOAL := help

help:
	@echo "SwiftDossier - available targets:"
	@echo "  help        - Show this help message (default)"
	@echo "  build       - Build every target for macOS (arm64)"
	@echo "  test        - Run the test suite on macOS (arm64); honours TEST_FILTER and SPEC_DIR; runs fixtures first"
	@echo "  test-ios    - Run the test suite on the iPhone 17 simulator; honours SPEC_DIR; runs fixtures first"
	@echo "  fixtures    - Fetch dossier-format $(DOSSIER_FORMAT_REF) into $(FIXTURES_DIR)/ (a no-op under SPEC_DIR)"
	@echo ""
	@echo "Options:"
	@echo "  SPEC_DIR=<path>     test against that dossier-format tree instead of the pinned tag, e.g."
	@echo "                      TEST_FILTER=ConformanceTests make test SPEC_DIR=../dossier-format"
	@echo "                      Read-only; the pin ($(DOSSIER_FORMAT_REF)) and $(FIXTURES_DIR)/ are untouched."
	@echo "                      The live PinnedResources comparison is skipped; PINNED.sha256 checks still run."
	@echo "  TEST_FILTER=<name>  limit to a test target, Target/Suite, or bare suite name"
	@echo "  release     - Release build of the dossier CLI and its resource bundles, copied to $(BIN_DIR)/"
	@echo "  install     - Debug build of the dossier CLI and its resource bundles, copied to $(BIN_DIR)/"
	@echo "  smoke       - Run bin/dossier from another directory on a conformance fixture (after release)"
	@echo "  clean       - Remove build artifacts, $(BIN_DIR)/, and DerivedData"
	@echo "  resolve     - Resolve package dependencies"
	@echo "  acceptance  - REQUIREMENTS 9 against a project, read-only: PROJECT=<path> [REF=<ref>] [REPARTO=<path>] [PAGES_OUT=<dir>]; not in CI."
	@echo "                The project as it is on disk, unless REF=<ref> asks for that commit; the output says which"
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
	$(SPEC_ENV) xcodebuild test -scheme $(SCHEME) \
	  -destination $(DESTINATION) \
	  $(TEST_ONLY) \
	  $(XCODE_FLAGS) \
	  CODE_SIGNING_ALLOWED=NO \
	  $(ARCH)

test-ios: fixtures
	$(SPEC_ENV) xcodebuild test -scheme $(SCHEME) \
	  -destination $(IOS_DESTINATION) \
	  $(TEST_ONLY) \
	  $(XCODE_FLAGS) \
	  COMPILER_INDEX_STORE_ENABLE=NO \
	  $(ARCH)

# Shallow clone of the pinned tag. Skipped when the directory is already at the
# ref. Never reads or writes any other dossier-format checkout.
fixtures:
	@if [ -n "$(SPEC_ABS)" ]; then \
		test -f "$(SPEC_ABS)/examples/conformance.json" || { echo "SPEC_DIR $(SPEC_ABS) has no examples/conformance.json"; exit 1; }; \
		echo "SPEC_DIR=$(SPEC_ABS): using it in place of $(DOSSIER_FORMAT_REF); $(FIXTURES_DIR) untouched"; \
	elif [ -d $(FIXTURES_DIR)/.git ] && \
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
	  $(NO_COVERAGE) \
	  $(ARCH)
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(ls -td $(DERIVED_DATA)/SwiftDossier-*/Build/Products/Release 2>/dev/null | head -1); \
	if [ -n "$$PRODUCT_DIR" ] && [ -x "$$PRODUCT_DIR/$(BINARY)" ]; then \
		cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
		rm -rf $(BIN_DIR)/*.bundle; \
		cp -R "$$PRODUCT_DIR"/*.bundle $(BIN_DIR)/; \
		echo "Installed $(BINARY) and its resource bundles to $(BIN_DIR)/ (Release)"; \
	else \
		echo "Error: could not find $(BINARY) in $(DERIVED_DATA)/SwiftDossier-*/Build/Products/Release"; \
		exit 1; \
	fi

# Runs the released binary from a directory that is not this one, so a resource bundle it
# only finds through a build-tree path fails here. Needs `make release` and `make fixtures`.
smoke:
	@if xcrun otool -l $(BIN_DIR)/$(BINARY) | grep -q __llvm_prf; then \
		echo "smoke: $(BIN_DIR)/$(BINARY) is instrumented for coverage" >&2; exit 1; \
	fi
	@FIX="$$(cd $(FIXTURES_DIR)/examples/valid/complete-lead && pwd)"; BIN="$$(cd $(BIN_DIR) && pwd)/$(BINARY)"; \
	cd "$$(mktemp -d)" && \
	"$$BIN" validate "$$FIX/characters/WREN HALLOWAY.dossier" --cast "$$FIX/CAST.md" --json >/dev/null && \
	echo "smoke: $(BINARY) found its resources and validated the fixture"

install: resolve
	xcodebuild build -scheme $(CLI_SCHEME) \
	  -destination $(DESTINATION) \
	  $(XCODE_FLAGS) \
	  $(NO_COVERAGE) \
	  $(ARCH)
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(ls -td $(DERIVED_DATA)/SwiftDossier-*/Build/Products/Debug 2>/dev/null | head -1); \
	if [ -n "$$PRODUCT_DIR" ] && [ -x "$$PRODUCT_DIR/$(BINARY)" ]; then \
		cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
		rm -rf $(BIN_DIR)/*.bundle; \
		cp -R "$$PRODUCT_DIR"/*.bundle $(BIN_DIR)/; \
		echo "Installed $(BINARY) and its resource bundles to $(BIN_DIR)/ (Debug)"; \
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

# Reads PROJECT and never writes to it, and skips when it isn't there (SD-4). Not part of `test`.
acceptance:
	@REPARTO="$(REPARTO)" PAGES_OUT="$(PAGES_OUT)" scripts/acceptance.sh "$(PROJECT)" "$(REF)"
