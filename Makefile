.PHONY: up down test check ci-portable ci mutation hooks clean format

PROJECT := BrainPanel.xcodeproj
SCHEME := BrainPanel
ARCH := $(shell uname -m)
DESTINATION := platform=macOS,arch=$(ARCH)
GITLEAKS_IMAGE := zricethezav/gitleaks:v8.30.1
DEV_DERIVED_DATA := local/tmp/dev-derived-data
DEV_APP := $(DEV_DERIVED_DATA)/Build/Products/Debug/Brain Panel.app
XCODE_BASE_ARGS := -project $(PROJECT) -scheme $(SCHEME) -destination '$(DESTINATION)'
XCODE_TEST_ARGS := -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 15 -maximum-test-execution-time-allowance 30

up:
	@mkdir -p $(DEV_DERIVED_DATA)
	xcodebuild build $(XCODE_BASE_ARGS) -configuration Debug -derivedDataPath $(DEV_DERIVED_DATA) SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
	open "$(DEV_APP)"

down:
	@pids=$$(pgrep -f "$(DEV_DERIVED_DATA)/Build/Products/Debug/Brain Panel.app/Contents/MacOS/Brain Panel" || [ $$? -eq 1 ]); \
	if [ -n "$$pids" ]; then kill $$pids; fi

hooks:
	git config core.hooksPath scripts/hooks
	chmod +x scripts/hooks/pre-push scripts/check-gates scripts/gates/test scripts/check-swift scripts/swift-gates/test scripts/check-docs scripts/run-gitleaks scripts/gitleaks-gates/test scripts/smoke-app scripts/run-mutation

format:
	xcrun swift-format format --in-place --configuration .swift-format --recursive BrainPanel BrainPanelTests

clean:
	@mkdir -p local/tmp
	rm -rf local/tmp/*

test:
	@set -eu; \
	run_dir="local/tmp/test-$$$$"; \
	cleanup() { \
		status=$$?; \
		trap - EXIT INT TERM; \
		if [ -d "$$run_dir" ]; then rm -rf "$$run_dir" || { s=$$?; [ "$$status" -ne 0 ] || status=$$s; }; fi; \
		exit "$$status"; \
	}; \
	trap cleanup EXIT; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	mkdir -p "$$run_dir/isolated/sessions" "$$run_dir/isolated/projects" "$$run_dir/isolated/claude-context" "$$run_dir/isolated/antigravity-cli" "$$run_dir/isolated/brain-state" "$$run_dir/isolated/brain-sessions" "$$run_dir/isolated/logs" "$$run_dir/isolated/launch-agents" "$$run_dir/isolated/pages" "$$run_dir/isolated/support" "$$run_dir/isolated/empty-bin"; \
	BRAIN_PANEL_MODE=testing \
	BRAIN_PANEL_CLAUDE_SESSIONS_DIR="$$(pwd)/$$run_dir/isolated/sessions" \
	BRAIN_PANEL_CLAUDE_PROJECTS_DIR="$$(pwd)/$$run_dir/isolated/projects" \
	BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR="$$(pwd)/$$run_dir/isolated/claude-context" \
	BRAIN_PANEL_ANTIGRAVITY_DIR="$$(pwd)/$$run_dir/isolated/antigravity-cli" \
	BRAIN_PANEL_BRAIN_STATE_DIR="$$(pwd)/$$run_dir/isolated/brain-state" \
	BRAIN_PANEL_BRAIN_SESSIONS_STATE_DIR="$$(pwd)/$$run_dir/isolated/brain-sessions" \
	BRAIN_PANEL_LOGS_DIR="$$(pwd)/$$run_dir/isolated/logs" \
	BRAIN_PANEL_LAUNCH_AGENTS_DIR="$$(pwd)/$$run_dir/isolated/launch-agents" \
	BRAIN_PANEL_BACKUP_PROGRESS_FILE="$$(pwd)/$$run_dir/isolated/pages/backup-drive.json" \
	BRAIN_PANEL_APP_SUPPORT_DIR="$$(pwd)/$$run_dir/isolated/support" \
	BRAIN_PANEL_CLI_SEARCH_PATHS="$$(pwd)/$$run_dir/isolated/empty-bin" \
	xcodebuild test $(XCODE_BASE_ARGS) -derivedDataPath "$$run_dir/DerivedData" -only-testing:BrainPanelUnitTests $(XCODE_TEST_ARGS) CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

ci-portable:
	@set -eu; \
	run_dir="local/tmp/ci-portable-$$$$"; \
	cleanup() { \
		status=$$?; \
		trap - EXIT INT TERM; \
		if [ -d "$$run_dir" ]; then rm -rf "$$run_dir" || { s=$$?; [ "$$status" -ne 0 ] || status=$$s; }; fi; \
		exit "$$status"; \
	}; \
	trap cleanup EXIT; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	mkdir -p "$$run_dir"; \
	sh scripts/check-gates; \
	sh scripts/gates/test; \
	python3 scripts/check-swift; \
	sh scripts/swift-gates/test; \
	python3 scripts/check-docs; \
	python3 scripts/gitleaks-gates/test; \
	python3 scripts/run-gitleaks --image $(GITLEAKS_IMAGE) "$$run_dir/gitleaks"

check: ci-portable
	@set -eu; \
	run_dir="local/tmp/check-$$$$"; \
	cleanup() { \
		status=$$?; \
		trap - EXIT INT TERM; \
		if [ -d "$$run_dir" ]; then rm -rf "$$run_dir" || { s=$$?; [ "$$status" -ne 0 ] || status=$$s; }; fi; \
		exit "$$status"; \
	}; \
	trap cleanup EXIT; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	mkdir -p "$$run_dir/formatted"; \
	xcrun swift-format lint --strict --configuration .swift-format --recursive BrainPanel BrainPanelTests; \
	cp -R BrainPanel "$$run_dir/formatted/BrainPanel"; \
	cp -R BrainPanelTests "$$run_dir/formatted/BrainPanelTests"; \
	xcrun swift-format format --in-place --configuration .swift-format --recursive "$$run_dir/formatted/BrainPanel" "$$run_dir/formatted/BrainPanelTests"; \
	diff -ru BrainPanel "$$run_dir/formatted/BrainPanel" || { echo "make check: código fora do padrão de formatação; rode 'make format'" >&2; exit 1; }; \
	diff -ru BrainPanelTests "$$run_dir/formatted/BrainPanelTests" || { echo "make check: testes fora do padrão de formatação; rode 'make format'" >&2; exit 1; }; \
	$(MAKE) test

ci: check
	@set -eu; \
	run_dir="local/tmp/ci-$$$$"; \
	cleanup() { \
		status=$$?; \
		trap - EXIT INT TERM; \
		if [ -d "$$run_dir" ]; then rm -rf "$$run_dir" || { s=$$?; [ "$$status" -ne 0 ] || status=$$s; }; fi; \
		exit "$$status"; \
	}; \
	trap cleanup EXIT; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	mkdir -p "$$run_dir/isolated/sessions" "$$run_dir/isolated/projects" "$$run_dir/isolated/claude-context" "$$run_dir/isolated/antigravity-cli" "$$run_dir/isolated/brain-state" "$$run_dir/isolated/brain-sessions" "$$run_dir/isolated/logs" "$$run_dir/isolated/launch-agents" "$$run_dir/isolated/pages" "$$run_dir/isolated/support" "$$run_dir/isolated/empty-bin" "$$run_dir/smoke"; \
	BRAIN_PANEL_MODE=testing \
	BRAIN_PANEL_CLAUDE_SESSIONS_DIR="$$(pwd)/$$run_dir/isolated/sessions" \
	BRAIN_PANEL_CLAUDE_PROJECTS_DIR="$$(pwd)/$$run_dir/isolated/projects" \
	BRAIN_PANEL_CLAUDE_CONTEXT_CACHE_DIR="$$(pwd)/$$run_dir/isolated/claude-context" \
	BRAIN_PANEL_ANTIGRAVITY_DIR="$$(pwd)/$$run_dir/isolated/antigravity-cli" \
	BRAIN_PANEL_BRAIN_STATE_DIR="$$(pwd)/$$run_dir/isolated/brain-state" \
	BRAIN_PANEL_BRAIN_SESSIONS_STATE_DIR="$$(pwd)/$$run_dir/isolated/brain-sessions" \
	BRAIN_PANEL_LOGS_DIR="$$(pwd)/$$run_dir/isolated/logs" \
	BRAIN_PANEL_LAUNCH_AGENTS_DIR="$$(pwd)/$$run_dir/isolated/launch-agents" \
	BRAIN_PANEL_BACKUP_PROGRESS_FILE="$$(pwd)/$$run_dir/isolated/pages/backup-drive.json" \
	BRAIN_PANEL_APP_SUPPORT_DIR="$$(pwd)/$$run_dir/isolated/support" \
	BRAIN_PANEL_CLI_SEARCH_PATHS="$$(pwd)/$$run_dir/isolated/empty-bin" \
	xcodebuild test $(XCODE_BASE_ARGS) -derivedDataPath "$$run_dir/DerivedData" -only-testing:BrainPanelIntegrationTests $(XCODE_TEST_ARGS) CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES; \
	xcodebuild build $(XCODE_BASE_ARGS) -configuration Release -derivedDataPath "$$run_dir/DerivedDataRelease" CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES; \
	python3 scripts/smoke-app "$$run_dir/DerivedDataRelease/Build/Products/Release/Brain Panel.app" "$$run_dir/smoke"

mutation:
	python3 scripts/run-mutation
