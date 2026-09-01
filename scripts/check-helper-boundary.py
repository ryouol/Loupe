#!/usr/bin/env python3
"""Fail if privileged helper linkage grows beyond the reviewed allow-list."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWED_SOURCES = {
    "DaemonXPCService.swift",
    "IOReportChannels.swift",
    "IOReportPowerReader.swift",
    "LiveTelemetrySource.swift",
    "TelemetrySource.swift",
}
ALLOWED_DEPENDENCIES = {"LoupeCore", "LoupeTelemetry"}
FORBIDDEN_BINARY_MARKERS = (
    b"The adapter socket",
    b"Concurrent adapter limit",
    b"Replay input",
    b"inference_events",
)


def output(*arguments: str) -> bytes:
    return subprocess.check_output(arguments, cwd=ROOT)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


description = json.loads(output("swift", "package", "describe", "--type", "json"))
helper = next(target for target in description["targets"] if target["name"] == "loupedaemon")
dependencies = set(helper.get("target_dependencies", []))
require(
    dependencies == ALLOWED_DEPENDENCIES,
    f"loupedaemon dependencies changed: {sorted(dependencies)}",
)

source_directory = ROOT / "Sources" / "LoupeTelemetry"
sources = {path.name for path in source_directory.glob("*.swift")}
require(
    sources == ALLOWED_SOURCES,
    f"privileged source allow-list changed: {sorted(sources)}",
)

binary_directory = Path(output("swift", "build", "--show-bin-path").decode().strip())
binary = binary_directory / "loupedaemon"
require(binary.is_file(), "build loupedaemon before checking its linkage")
strings = output("strings", str(binary))
found = [marker.decode() for marker in FORBIDDEN_BINARY_MARKERS if marker in strings]
require(not found, f"root helper contains user-ingest/replay markers: {found}")

print("helper boundary: Core + telemetry-only allow-list")
