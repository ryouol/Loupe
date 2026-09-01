SHELL := /bin/bash

VENV := .venv
PYTHON := $(VENV)/bin/python
UV := uv
PYTHON_VERSION := 3.12
SCHEME := Loupe
DESTINATION := platform=macOS
ADAPTER := adapters/loupe-mlx
SWIFT_PATHS := Sources Tests adapters/loupe-llamacpp Package.swift
PYTHON_PATHS := adapters scripts/*.py
RUFF_CONFIG := adapters/loupe-mlx/pyproject.toml
SWIFT_FORMAT := $(if $(shell command -v swift-format 2>/dev/null),swift-format,swift format)

.DEFAULT_GOAL := help

.PHONY: help bootstrap bootstrap-mlx generate build build-spm build-app test test-swift test-python lint format replay record-fixture verify dist bench clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

Local.xcconfig:
	@cp Local.xcconfig.template Local.xcconfig
	@echo "Created Local.xcconfig. Leave DEVELOPMENT_TEAM empty for unsigned local builds."

generate: Local.xcconfig ## Generate Loupe.xcodeproj (xcodegen owns the pbxproj)
	xcodegen generate

bootstrap: generate ## Generate project, resolve SPM deps, set up the Python venv
	swift package resolve
	test -d $(VENV) || $(UV) venv --python $(PYTHON_VERSION) $(VENV)
	UV_PROJECT_ENVIRONMENT=$(CURDIR)/$(VENV) $(UV) sync \
		--project $(ADAPTER) --locked --extra dev

bootstrap-mlx: bootstrap ## bootstrap + mlx-lm, needed only to record fixtures
	UV_PROJECT_ENVIRONMENT=$(CURDIR)/$(VENV) $(UV) sync \
		--project $(ADAPTER) --locked --extra dev --extra mlx

build: build-spm build-app ## Build the SPM targets and the app

build-spm: ## swift build
	swift build
	$(PYTHON) scripts/check-helper-boundary.py

build-app: generate ## Build the app with xcodebuild (unsigned local build)
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO

test: test-swift test-python ## Run all tests

test-swift: ## swift test
	swift test

test-python: ## pytest the Python adapters
	@if [ ! -x "$(PYTHON)" ]; then echo "No venv found. Run 'make bootstrap' first."; exit 1; fi
	$(PYTHON) -m pytest adapters/

lint: ## Run strict Swift, Python, workflow, and shell lint
	$(SWIFT_FORMAT) lint --strict --recursive $(SWIFT_PATHS)
	$(PYTHON) -m ruff check --config $(RUFF_CONFIG) $(PYTHON_PATHS)
	$(PYTHON) -m ruff format --check --config $(RUFF_CONFIG) $(PYTHON_PATHS)
	actionlint .github/workflows/ci.yml
	shellcheck scripts/*.sh

format: ## swift-format format in place
	$(SWIFT_FORMAT) format --in-place --recursive $(SWIFT_PATHS)
	$(PYTHON) -m ruff check --fix --config $(RUFF_CONFIG) $(PYTHON_PATHS)
	$(PYTHON) -m ruff format --config $(RUFF_CONFIG) $(PYTHON_PATHS)

replay: generate ## Render the sanitized shipping sample in the app, no root needed
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath DerivedData -quiet CODE_SIGNING_ALLOWED=NO
	LOUPE_REPLAY_FIXTURE=$(CURDIR)/Resources/Samples/demo-session \
		./DerivedData/Build/Products/Debug/Loupe.app/Contents/MacOS/Loupe

NAME ?= baseline-session
DURATION ?= 60
record-fixture: ## Record fixtures/$(NAME) from a real MLX run (needs bootstrap-mlx)
	bash scripts/record-fixture.sh $(NAME) $(DURATION)

dist: ## Build a distributable DMG (see docs/distribution.md for signing)
	bash scripts/make-dist.sh

verify: ## Run release gates that do not require signing credentials
	bash scripts/verify-release.sh

SPEC ?= Support/benchmark-example.yaml
OUT ?= benchmark-report.json
bench: ## Run a benchmark spec (needs bootstrap-mlx)
	@test -n "$(RUNTIME_VERSION)" -a -n "$(MODEL_REVISION)" -a -n "$(MODEL_SHA256)" || \
		{ echo "Set RUNTIME_VERSION, MODEL_REVISION, and MODEL_SHA256."; exit 1; }
	swift run loupe-bench --spec $(SPEC) --out $(OUT) \
		--runtime-version "$(RUNTIME_VERSION)" --model-revision "$(MODEL_REVISION)" \
		--model-sha256 "$(MODEL_SHA256)" --dependency-lock $(ADAPTER)/uv.lock

clean: ## Remove build artifacts
	rm -rf .build DerivedData Loupe.xcodeproj $(VENV) dist
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
