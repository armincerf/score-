# score — single entry point for humans, CI and coding agents.
# `make help` lists targets. Output is filtered to warnings/errors/test results
# so agent context stays small; raw logs land in .build/logs/.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

PROJECT      := score.xcodeproj
SCHEME       := score
WATCH_SCHEME := scorewatch Watch App
SIM_NAME     ?= iPhone 17 Pro
# PARALLEL=NO runs the tests one at a time (CI: a dozen video exports at once thrashed the 3-core runner and
# tripped time limits; serial timings are each test's own work)
PARALLEL     ?= YES
# scripts/simulator-udid.sh picks (or creates) $(SIM_NAME) on the newest installed iOS runtime.
DEST_GENERIC := generic/platform=iOS Simulator
DEST_WATCH   := generic/platform=watchOS Simulator
BUILD_DIR    := .build
LOG_DIR      := $(BUILD_DIR)/logs
RESULT       := $(BUILD_DIR)/results/test.xcresult
XCB          := scripts/xcb.sh
# Optional: `make test T=scoreTests/ServingLogicTests` runs one suite/test.
T ?=
ONLY := $(if $(T),-only-testing:'$(T)',)

.PHONY: help setup build build-watch test test-summary lint format check skills clean sim-list sim-reset deploy install \
        testflight testflight-export testflight-status testers screenshot

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

setup: ## Install dev tools (brew), git hooks and Xcode agent skills
	@command -v brew >/dev/null || { echo "Homebrew required: https://brew.sh"; exit 1; }
	brew bundle --no-upgrade --file=Brewfile
	git config core.hooksPath .githooks
	@$(MAKE) --no-print-directory skills
	@echo "✅ setup complete"

build: ## Build iOS app (+ embedded watch app) for the simulator, warnings-as-errors
	@mkdir -p $(LOG_DIR)
	set -o pipefail; xcodebuild build -project $(PROJECT) -scheme "$(SCHEME)" -destination '$(DEST_GENERIC)' \
	  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES 2>&1 | tee $(LOG_DIR)/build.log | $(XCB)

build-watch: ## Build the watch app on its own
	@mkdir -p $(LOG_DIR)
	set -o pipefail; xcodebuild build -project $(PROJECT) -scheme "$(WATCH_SCHEME)" -destination '$(DEST_WATCH)' \
	  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES 2>&1 | tee $(LOG_DIR)/build-watch.log | $(XCB)

# -collect-test-diagnostics never: on a failure xcodebuild otherwise spends ~10 min in `simctl diagnose`
# before it prints anything; the result bundle still holds every result.
test: ## Run unit tests on the simulator (T=scoreTests/Suite or T=scoreTests/Suite/testName to filter)
	@mkdir -p $(LOG_DIR) $(dir $(RESULT)); rm -rf $(RESULT)
	set -o pipefail; udid=$$(scripts/simulator-udid.sh "$(SIM_NAME)"); mkdir -p $(BUILD_DIR)/shots/reel; \
	xcodebuild test -project $(PROJECT) -scheme "$(SCHEME)" -destination "platform=iOS Simulator,id=$$udid" \
	  -resultBundlePath $(RESULT) -collect-test-diagnostics never -parallel-testing-enabled $(PARALLEL) \
	  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES $(ONLY) \
	  TEST_RUNNER_REEL_FRAMES_DIR="$(abspath $(BUILD_DIR))/shots/reel" 2>&1 | tee $(LOG_DIR)/test.log | $(XCB)
	@scripts/test-summary.sh $(RESULT)

test-summary: ## Print pass/fail summary from the last test run
	@scripts/test-summary.sh $(RESULT)

lint: ## SwiftLint (strict) + swift-format lint
	swiftlint lint --strict --quiet
	swift format lint --strict --recursive --configuration .swift-format score "scorewatch Watch App" scoreTests
	@echo "✅ lint clean"

format: ## Auto-format and auto-fix lint violations
	swift format --in-place --recursive --configuration .swift-format score "scorewatch Watch App" scoreTests
	swiftlint lint --fix --quiet >/dev/null || true
	@echo "✅ formatted"

check: lint build build-watch test ## Full gate: lint + build + build-watch + test (what CI runs)
	@echo "✅ all gates passed"

skills: ## Export Apple's Xcode agent skills into .claude/skills (gitignored)
	@scripts/sync-xcode-skills.sh

deploy: ## Build Release for a connected iPhone and install + launch it (devicectl)
	@scripts/deploy-device.sh

install: ## Install the last device build without rebuilding
	@scripts/deploy-device.sh --no-build

# TestFlight (see AGENTS.md, "TestFlight"). VERSION=X.Y.Z overrides the marketing version;
# NOTES="..." sets the build's What to Test text.
testflight: ## Archive + upload to TestFlight, wait for processing, send to "Score testers"
	@python3 scripts/asc.py preflight
	@build=$$(date -u +%Y%m%d.%H%M%S); \
	BUILD_NUMBER=$$build scripts/testflight.sh $(if $(VERSION),--version '$(VERSION)',); \
	python3 scripts/asc.py wait-build "$$build"; \
	python3 scripts/asc.py distribute "$$build" $${NOTES:+--notes "$$NOTES"}

testflight-export: ## Archive + export an App Store .ipa without uploading (checks signing)
	@scripts/testflight.sh --no-upload $(if $(VERSION),--version '$(VERSION)',)

testflight-status: ## App Store Connect app record, latest builds and beta groups
	@python3 scripts/asc.py status

testers: ## Ensure the internal all-builds "Score testers" group has its testers; list them
	@python3 scripts/asc.py ensure-testers

# Screenshots (see AGENTS.md, "Screenshots"). ARGS are launch arguments understood by DebugSeed.swift.
screenshot: ## Build + launch on the simulator and save a PNG: make screenshot OUT=x.png [ARGS="-seedSampleMatches"] [DARK=1] [NO_BUILD=1]
	@scripts/screenshot.sh --sim "$(SIM_NAME)" $(if $(DARK),--dark,) $(if $(NO_BUILD),--no-build,) \
	  $(if $(ARGS),--args '$(ARGS)',) "$(or $(OUT),.build/shots/home.png)"

sim-reset: ## Erase the test simulator (fixes "Failed to install or launch the test runner")
	@udid=$$(scripts/simulator-udid.sh "$(SIM_NAME)"); xcrun simctl shutdown "$$udid" >/dev/null 2>&1 || true; \
	xcrun simctl erase "$$udid" && echo "erased $(SIM_NAME) ($$udid)"

sim-list: ## List available iOS simulators
	@xcrun simctl list devices available | grep -E "iPhone|iPad|Watch"

clean: ## Remove local build output
	rm -rf $(BUILD_DIR)
