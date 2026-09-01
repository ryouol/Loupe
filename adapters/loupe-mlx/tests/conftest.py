import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return REPO_ROOT


@pytest.fixture(scope="session")
def valid_lines() -> list[bytes]:
    return (REPO_ROOT / "protocol/examples/v3-events.ndjson").read_bytes().splitlines()


@pytest.fixture(scope="session")
def malformed_lines() -> list[bytes]:
    return (REPO_ROOT / "protocol/examples/v1-malformed.ndjson").read_bytes().splitlines()


@pytest.fixture(scope="session")
def schema() -> dict:
    return json.loads((REPO_ROOT / "protocol/events.schema.json").read_text())
