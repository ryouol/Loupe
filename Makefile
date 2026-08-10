SHELL := /bin/bash

VENV := .venv
PYTHON := $(VENV)/bin/python
UV := uv
SCHEME := Loupe
DESTINATION := platform=macOS
ADAPTER := adapters/loupe-mlx
SWIFT_PATHS := Sources Tests Package.swift

.DEFAULT_GOAL := help

.PHONY: help bootstrap bootstrap-mlx generate build build-spm build-app test test-swift test-python lint format replay record-fixture dist bench clean

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

Local.xcconfig:
	@cp Local.xcconfig.template Local.xcconfig
	@echo "Created Local.xcconfig from template. Set DEVELOPMENT_TEAM before M0.6."

generate: Local.xcconfig ## Generate Loupe.xcodeproj (xcodegen owns the pbxproj)
	xcodegen generate

bootstrap: generate ## Generate project, resolve SPM deps, set up the Python venv
	swift package resolve
	test -d $(VENV) || $(UV) venv --python 3.12 $(VENV)
	$(UV) pip install --python $(PYTHON) -e "$(ADAPTER)[dev]"

bootstrap-mlx: bootstrap ## bootstrap + mlx-lm, needed only to record fixtures
	$(UV) pip install --python $(PYTHON) -e "$(ADAPTER)[dev,mlx]"

build: build-spm build-app ## Build the SPM targets and the app

build-spm: ## swift build
	swift build

build-app: generate ## Build the app with xcodebuild (unsigned local build)
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO

test: test-swift test-python ## Run all tests

test-swift: ## swift test
	swift test

test-python: ## pytest the Python adapters
	@if [ ! -x "$(PYTHON)" ]; then echo "No venv found. Run 'make bootstrap' first."; exit 1; fi
	$(PYTHON) -m pytest adapters/

lint: ## swift-format lint --strict
	swift-format lint --strict --recursive $(SWIFT_PATHS)

format: ## swift-format format in place
	swift-format format --in-place --recursive $(SWIFT_PATHS)

replay: generate ## Render fixtures/baseline-session in the app, no root needed
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' \
		-derivedDataPath DerivedData -quiet CODE_SIGNING_ALLOWED=NO
	LOUPE_REPLAY_FIXTURE=$(CURDIR)/fixtures/baseline-session \
		./DerivedData/Build/Products/Debug/Loupe.app/Contents/MacOS/Loupe

NAME ?= baseline-session
DURATION ?= 60
record-fixture: ## Record fixtures/$(NAME) from a real MLX run (needs bootstrap-mlx)
	bash scripts/record-fixture.sh $(NAME) $(DURATION)

dist: ## Build a distributable DMG (see docs/distribution.md for signing)
	bash scripts/make-dist.sh

SPEC ?= Support/benchmark-example.yaml
OUT ?= benchmark-report.json
bench: ## Run a benchmark spec (needs bootstrap-mlx)
	swift run loupe-bench --spec $(SPEC) --out $(OUT)

clean: ## Remove build artifacts
	rm -rf .build DerivedData Loupe.xcodeproj $(VENV) dist
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
