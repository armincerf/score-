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
SIM_OS       ?= latest
DEST_SIM     := platform=iOS Simulator,name=$(SIM_NAME),OS=$(SIM_OS)
DEST_GENERIC := generic/platform=iOS Simulator
DEST_WATCH   := generic/platform=watchOS Simulator
BUILD_DIR    := .build
LOG_DIR      := $(BUILD_DIR)/logs
RESULT       := $(BUILD_DIR)/results/test.xcresult
XCB          := scripts/xcb.sh
# Optional: `make test T=scoreTests/ServingLogicTests` runs one suite/test.
T ?=
ONLY := $(if $(T),-only-testing:$(T),)

.PHONY: help setup build build-watch test test-summary lint format check skills clean sim-list deploy install

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

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

test: ## Run unit tests on the simulator (T=Suite/testName to filter)
	@mkdir -p $(LOG_DIR) $(dir $(RESULT)); rm -rf $(RESULT)
	set -o pipefail; xcodebuild test -project $(PROJECT) -scheme "$(SCHEME)" -destination '$(DEST_SIM)' \
	  -resultBundlePath $(RESULT) CODE_SIGNING_ALLOWED=NO $(ONLY) 2>&1 | tee $(LOG_DIR)/test.log | $(XCB)

test-summary: ## Print pass/fail summary from the last test run
	@xcrun xcresulttool get test-results summary --path $(RESULT) --compact 2>/dev/null \
	  | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(f"{d.get(\"result\")}: {d.get(\"passedTests\")} passed, {d.get(\"failedTests\")} failed, {d.get(\"skippedTests\")} skipped")'

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

sim-list: ## List available iOS simulators
	@xcrun simctl list devices available | grep -E "iPhone|iPad|Watch"

clean: ## Remove local build output
	rm -rf $(BUILD_DIR)
