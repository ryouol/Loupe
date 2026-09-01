from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


def _executable(path: Path, body: str) -> None:
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body)
    path.chmod(0o755)


def _packaging_fixture(tmp_path: Path, repo_root: Path) -> tuple[Path, dict[str, str]]:
    root = tmp_path / "repo"
    (root / "scripts").mkdir(parents=True)
    (root / "Sources/LoupeCore").mkdir(parents=True)
    (root / "dist").mkdir()
    shutil.copy2(repo_root / "scripts/make-dist.sh", root / "scripts/make-dist.sh")
    (root / "scripts/verify-release.sh").write_text("#!/bin/sh\nexit 0\n")
    (root / "scripts/verify-release.sh").chmod(0o755)
    (root / "project.yml").write_text('  MARKETING_VERSION: "1.2.3"\n')
    (root / "Sources/LoupeCore/Loupe.swift").write_text(
        'public enum Loupe { public static let version = "1.2.3" }\n'
    )

    commands = tmp_path / "commands"
    commands.mkdir()
    _executable(commands / "xcodegen", "exit 0\n")
    _executable(
        commands / "xcodebuild",
        """
mkdir -p DerivedData/Build/Products/Release/Loupe.app/Contents/MacOS
mkdir -p DerivedData/Build/Products/Release/Loupe.app/Contents/Resources
: > DerivedData/Build/Products/Release/Loupe.app/Contents/MacOS/Loupe
: > DerivedData/Build/Products/Release/Loupe.app/Contents/MacOS/loupedaemon
for resource in demo-session.ndjson demo-session.system.ndjson Privacy.txt Terms.txt ThirdPartyNotices.txt; do
    : > "DerivedData/Build/Products/Release/Loupe.app/Contents/Resources/$resource"
done
""",
    )
    _executable(commands / "file", 'printf "%s: Mach-O 64-bit executable arm64\\n" "$1"\n')
    _executable(
        commands / "hdiutil",
        """
case "$1" in
    create)
        target="${!#}"
        printf 'candidate-image' > "$target"
        ;;
    verify)
        if [[ "${FAKE_HDIUTIL_FAIL_VERIFY:-0}" == "1" ]]; then exit 44; fi
        test -f "$2"
        ;;
esac
""",
    )
    _executable(
        commands / "shasum",
        """
if [[ "${FAKE_SHASUM_FAIL:-0}" == "1" ]]; then exit 45; fi
printf 'fixture-sha  %s\\n' "$3"
""",
    )
    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{commands}:/usr/bin:/bin:/usr/sbin:/sbin",
            "LOUPE_RELEASE_TESTS_PASSED": "1",
            "LOUPE_SIGN_IDENTITY": "",
            "LOUPE_NOTARY_PROFILE": "",
        }
    )
    return root, environment


def test_failed_candidate_or_checksum_preserves_previous_distribution(
    tmp_path: Path, repo_root: Path
) -> None:
    root, environment = _packaging_fixture(tmp_path, repo_root)
    final = root / "dist/Loupe-1.2.3-unsigned.dmg"
    checksum = root / "dist/Loupe-1.2.3-unsigned.dmg.sha256"
    final.write_text("known-good-image")
    checksum.write_text("known-good-checksum")

    for failure_variable in ["FAKE_HDIUTIL_FAIL_VERIFY", "FAKE_SHASUM_FAIL"]:
        failed_environment = environment | {failure_variable: "1"}
        result = subprocess.run(
            ["bash", "scripts/make-dist.sh"], cwd=root, env=failed_environment, check=False
        )
        assert result.returncode != 0
        assert final.read_text() == "known-good-image"
        assert checksum.read_text() == "known-good-checksum"
        assert list((root / "dist").glob(".Loupe-*.candidate.*")) == []


def test_verified_candidate_is_published_then_checksummed(tmp_path: Path, repo_root: Path) -> None:
    root, environment = _packaging_fixture(tmp_path, repo_root)
    result = subprocess.run(
        ["bash", "scripts/make-dist.sh"], cwd=root, env=environment, check=False
    )
    assert result.returncode == 0
    final = root / "dist/Loupe-1.2.3-unsigned.dmg"
    checksum = root / "dist/Loupe-1.2.3-unsigned.dmg.sha256"
    assert final.read_text() == "candidate-image"
    assert checksum.read_text() == f"fixture-sha  {final.relative_to(root)}\n"
    assert ".candidate." not in checksum.read_text()
    assert list((root / "dist").glob(".Loupe-*.candidate.*")) == []


def test_publication_occurs_after_every_release_candidate_gate(repo_root: Path) -> None:
    script = (repo_root / "scripts/make-dist.sh").read_text()
    publication = script.index('mv -f "$CANDIDATE_DMG" "$DMG"')
    required_before_publication = [
        'codesign --verify --deep --strict --verbose=2 "$APP"',
        'xcrun stapler validate "$APP"',
        'spctl --assess --type execute --verbose=2 "$APP"',
        'codesign --force --timestamp --sign "$IDENTITY" "$CANDIDATE_DMG"',
        'xcrun stapler validate "$CANDIDATE_DMG"',
        'spctl --assess --type open --context context:primary-signature --verbose=2 "$CANDIDATE_DMG"',
    ]
    assert all(script.index(gate) < publication for gate in required_before_publication)
    assert script.index('shasum -a 256 "$DMG"') > publication
    assert 'rm -f "$DMG" "$DMG.sha256"' not in script
