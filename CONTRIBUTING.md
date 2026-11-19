# Contributing

## Branches
- `main` is protected: no direct pushes, no force-pushes, no deletion.
- Work happens on feature branches named `feature/<short-name>`. Other allowed prefixes: `fix/`, `docs/`, `test/`, `refactor/`, `chore/`.
- Every change reaches `main` through a pull request. A required CI check rejects pull requests whose source branch does not use one of these prefixes.

## Commits
- Conventional Commits: `type(scope): summary`, for example `feat(refresh): add per-bank refresh scheduler (JESD212C.01 §7.15)`.
- Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `ci`.
- One logical change per commit. Each commit should build and pass the tests that exist at that point.
- Cite the JEDEC section in the message or body when a change implements a spec rule.

## Pull requests
- Link the issue the PR addresses.
- Describe what changed and how it was verified.
- CI must pass before merging.

## Coding standard
- RTL and testbenches: Verilog-2005 only (`iverilog -g2005`). No SystemVerilog in `rtl/` or `tb/`.
- `wire`/`reg`, `localparam` state encodings, shared constants in `.vh` includes, ANSI-style ports, `generate` for replication.
- SystemVerilog is allowed only in `sva/`.
- Timing values are parameters; never hard-code values from a datasheet.
