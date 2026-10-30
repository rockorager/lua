# Changelog

All notable changes to lua are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- The core runtime as an unstable Zig API: `Value`, `State`, `Thread`, `Table`, `String`, `Proto`, `opcodes`, and the `vm` interpreter, which runs Lua 5.5 bytecode; there is no compiler yet.
- The `string`, `table`, `math`, and `utf8` standard libraries, each opened with its module's `open(state)`; `math.random` with a seed gives the reference's sequence, and `math.exp` and `math.log` round as glibc does. `string.dump` raises "unable to dump given function".
