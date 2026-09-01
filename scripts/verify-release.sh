#!/usr/bin/env bash
# Credential-free release verification. A Command Line Tools-only host can
# exercise every non-XCTest path with LOUPE_ALLOW_TOOLCHAIN_LIMITED_VERIFY=1,
# but that mode is never sufficient for a signed release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build

if command -v swift-format >/dev/null 2>&1; then
    swift-format lint --strict --recursive Sources Tests adapters/loupe-llamacpp Package.swift
else
    swift format lint --strict --recursive Sources Tests adapters/loupe-llamacpp Package.swift
fi

# Check both the committed tree under review and any uncommitted remediation.
# A bare `git diff --check` alone silently ignores defects already committed.
git show --check --format= HEAD
git diff --check

PYTHON=".venv/bin/python"
[[ -x "$PYTHON" ]] || {
    echo "No project venv. Run make bootstrap first." >&2
    exit 1
}
"$PYTHON" -m pytest adapters/
"$PYTHON" -m ruff check --config adapters/loupe-mlx/pyproject.toml \
    adapters scripts/*.py
"$PYTHON" -m ruff format --check --config adapters/loupe-mlx/pyproject.toml \
    adapters scripts/*.py
"$PYTHON" scripts/check-helper-boundary.py

ACTIONLINT_BIN="$(command -v actionlint || true)"
[[ -n "$ACTIONLINT_BIN" ]] || { echo "actionlint is required to validate CI" >&2; exit 1; }
"$ACTIONLINT_BIN" .github/workflows/ci.yml

SHELLCHECK_BIN="$(command -v shellcheck || true)"
[[ -n "$SHELLCHECK_BIN" ]] || { echo "shellcheck is required to validate scripts" >&2; exit 1; }
"$SHELLCHECK_BIN" scripts/*.sh

UV_BIN="$(command -v uv || true)"
if [[ -z "$UV_BIN" && -x .venv/bin/uv ]]; then
    UV_BIN=.venv/bin/uv
fi
[[ -n "$UV_BIN" ]] || { echo "uv is required to validate uv.lock" >&2; exit 1; }
UV_VERSION="$("$UV_BIN" --version | awk '{print $2}')"
"$PYTHON" - "$UV_VERSION" <<'PY'
import sys

version = tuple(int(component) for component in sys.argv[1].split(".")[:3])
if version < (0, 11, 15):
    raise SystemExit("uv 0.11.15 or newer is required by the security gate")
PY
"$UV_BIN" lock --project adapters/loupe-mlx --check
"$UV_BIN" export --project adapters/loupe-mlx --locked --extra dev --extra mlx \
    --no-hashes --no-emit-project \
    | "$UV_BIN" tool run --from pip-audit==2.10.1 pip-audit \
        -r /dev/stdin --progress-spinner off

OSV_BIN="$(command -v osv-scanner || true)"
[[ -n "$OSV_BIN" ]] || {
    echo "osv-scanner is required to audit Swift and Python lockfiles" >&2
    exit 1
}
"$OSV_BIN" scan source -L Package.resolved -L adapters/loupe-mlx/uv.lock \
    --verbosity warn

"$PYTHON" scripts/validate-sample.py

plutil -lint Support/ai.squint.loupe.daemon.plist

if [[ "$(xcode-select -p 2>/dev/null || true)" == *"CommandLineTools"* ]]; then
    if [[ "${LOUPE_ALLOW_TOOLCHAIN_LIMITED_VERIFY:-0}" != "1" ]]; then
        echo "Full Xcode is required for XCTest and app-target verification." >&2
        exit 1
    fi
    echo "TOOLCHAIN-LIMITED: XCTest/app-target gates were not run." >&2
else
    swift test
    xcodegen generate
    xcodebuild build -scheme Loupe -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
fi

echo "Credential-free release checks completed."
