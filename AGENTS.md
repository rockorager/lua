# AGENTS.md

Working notes for AI coding agents in baskingspot/lua.

## What this is

Lua 5.5 in Zig, with no C. The language is the Lua 5.5 reference manual's, https://www.lua.org/manual/5.5/, and the official Lua 5.5.1 test suite is the bar. It is incubating: unstable, with no promises about its API.

The repository is hosted on Amp at https://ampcode.com/@rockorager/lua, so project orbs can work on it in parallel. It moves to `baskingspot/lua` on GitHub later; the workflows under `.github/` are ready for that and do not run on Amp.

## Environment

Zig 0.17 only. The flake is the tool contract, from `baskingspot/nix`: `nix develop` provides Zig, `ziglint`, and the base tools, and nothing comes from the system PATH. The justfile is the command interface: `just test`, `just lint`, `just ci`. Run `just fmt` before you commit. The dev shell also provides reference C Lua 5.5.1 as `lua`, the oracle for differential tests and the baseline for benchmarks. `.agents/setup` installs Nix when an orb lacks it and warms the dev shell.

## Performance

Performance is a requirement from the first commit, not a later pass, and memory counts as much as speed. Reference C Lua 5.5.1 is the baseline, and the target is to match or beat it on both wall time and peak memory.

- Decide the hot paths with measurements: value representation, instruction dispatch, table access, string interning, calls and returns, and the collector. Record each decision, the alternatives measured, and the numbers in `docs/slop/`.
- A speed change that costs memory, or a memory change that costs speed, is measured both ways and the trade written up; neither wins by default.
- A change to a hot path comes with an interleaved A/B benchmark, pinned to one core (`taskset`), compared with benchstat, and written up in `docs/slop/results/<topic>-<yyyymmdd>.md` with the raw output.
- Allocate on an instruction's path only where the language allocates: tables, closures, strings, and coroutines.
- Correctness is not traded for speed: a fast path must pass the same tests as the slow one.

## Tests

`test/lua-5.5.1-tests/` is the official suite from https://www.lua.org/tests/, vendored unmodified; `THIRD_PARTY.md` records its checksum. Do not edit it to make a test pass. `ltests/` and `libs/` hold C for PUC-Rio's internal tests and C modules, and the internal tests (`_U` unset) need that C test library, so they do not apply; run `all.lua` with `_U=true`. A file or case that cannot pass for a documented reason goes in a list in the test driver, with the reason, the way html keeps its known divergences.

## Agent notes

Docs split by reader. `README.md`, `CHANGELOG.md`, and `THIRD_PARTY.md` are for a person deciding whether and how to use the package. Agent material goes in `docs/slop/`: design notes, plans, and measurements in `docs/slop/results/`. `docs/slop/plan.md` is the architecture, the decisions still to measure, and who owns which files; read it before starting work, and update it when a decision lands. `AGENTS.md` and code comments may link `docs/slop/`; no human document links or names it.

## Rules

- Commit messages are one line, `area: summary`, and every commit is signed. Do not rewrite pushed history. A change made for a measurement adds a short body that names its `docs/slop/results/` file and gives the headline number.
- Gate commands on their exit codes, and claim only what you ran.
- `just fmt` formats Zig, Nix, Markdown, and the justfile; `just lint` checks them and lints the workflows with actionlint and zizmor.
- This repo's GitHub settings come from `baskingspot/.github`, with `just settings`. Do not change them by hand.
- To graduate the project, follow the `baskingspot-new-repo` skill: logos, a real README, and the audit passing.

## Changelog

`CHANGELOG.md` is one file, Keep a Changelog format, newest first. Add a bullet
under `## [Unreleased]` in the same change that alters something a user can
notice: the public API, expected behavior, performance a benchmark row would
show, a supported backend, or the build requirements. Docs, CI, and internal
refactors do not need one unless they change how someone uses the package.

Write from the user's side: what changed, and what they must do about it. Name
the symbol, flag, or error. One line, under Added, Changed, Fixed, or Removed.

To release, dispatch the repo's `release.yml` with the version. The workflow
moves the Unreleased section into a dated heading, sets `.version` in
`build.zig.zon`, commits, tags, and opens the GitHub release. Do not tag by hand.
