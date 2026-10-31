# Contributing

- Keep Windows-only logic in `scripts/`, pure logic in `scripts/lib/` so it stays unit-testable.
- Run `Invoke-Pester ./tests` and `actionlint` before opening a pull request (CI does the same).
- Update `THIRD-PARTY-NOTICES.md` whenever code or tools from another project are added.
