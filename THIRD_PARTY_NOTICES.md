# Third-party notices

Loupe directly uses the following open-source packages. Their copyright and
license terms remain with their authors.

| Component | Use | License | Source |
|---|---|---|---|
| GRDB.swift | SQLite persistence | MIT | https://github.com/groue/GRDB.swift |
| Yams | Benchmark YAML parsing | MIT | https://github.com/jpsim/Yams |
| mlx-lm (optional adapter extra) | MLX model loading/generation | MIT | https://github.com/ml-explore/mlx-lm |
| Hatchling (build only) | Python package build backend | MIT | https://github.com/pypa/hatch |
| pytest (development only) | Python tests | MIT | https://github.com/pytest-dev/pytest |
| jsonschema (development only) | Protocol schema tests | MIT | https://github.com/python-jsonschema/jsonschema |
| Ruff (development only) | Python lint/format checks | MIT | https://github.com/astral-sh/ruff |

Transitive Swift revisions are pinned in `Package.resolved`. Python package
versions and artifact hashes are pinned in `adapters/loupe-mlx/uv.lock`.
Before a commercial release, the release owner must generate and archive the
complete resolved-license inventory and have counsel approve this notice.
