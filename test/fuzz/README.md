# Fuzzing

Fuzzers for the compiler, the binary chunk loader, the interpreter, and the embedding API's handling of allocation failure. Everything runs in ReleaseSafe, so safety checks fire.

```sh
just fuzz                     # every fuzzer, 60 seconds each
just fuzz diff 600            # one fuzzer, ten minutes
just fuzz "parse binary" 300 --seed 7
just fuzz-stress 120          # under collector stress
just fuzz-zig 1M              # Zig's coverage-guided fuzzer
just fuzz_mode=Debug fuzz binary 600
```

ReleaseSafe skips the 0xAA fill of new and freed objects; `fuzz_mode=Debug` keeps it, for runs meant to catch reads of uninitialized or freed memory.

A finding is written under `zig-out/fuzz/<fuzzer>/` with its input, a minimized input, and what went wrong, and the recipe fails. `zig-out/bin/fuzz repro TARGET FILE` runs one input again in-process, and `zig-out/bin/fuzz gen SEED` prints the program the generator makes from a seed.

## What each fuzzer checks

| Fuzzer        | Inputs                                                                                             | Must hold                                                                                                                                                                                                                                                |
| ------------- | -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `parse`       | mutated suite, bench, and `test/diff` files, generated programs, token soup, random bytes          | `State.load` returns a function or `error.Syntax`; no crash, safety panic, or hang (5 s); bounded memory; nothing held after `close`                                                                                                                     |
| `grammar`     | generated programs, run with the safe libraries                                                    | no crash, panic, hang, or leak; the state still runs code afterwards                                                                                                                                                                                     |
| `binary`      | `string.dump` output of the corpus, corrupted                                                      | `load(..., "b")` loads it or fails with "bad binary format", or with "not enough memory" when a count asks for more than the cap and nothing stays held; no crash, hang, or leak while loading; every line lookup on a chunk that loaded stays in bounds |
| `oom`         | 22 small programs, an API scenario, and every `test/diff` program, with the Nth allocation failing | for every N, failing once and failing from then on: `error.OutOfMemory` or "not enough memory", no leak, no crash, and the state still runs code (or closes cleanly)                                                                                     |
| `diff`        | generated deterministic programs                                                                   | the same stdout, stderr, and exit status as the reference `lua`                                                                                                                                                                                          |
| `bytecode`    | generated programs, with more syntax: deep nesting, many locals and constants, `global`, `goto`    | the same listing as `luac -l -l -p`                                                                                                                                                                                                                      |
| `messages`    | the `parse` inputs, in batches through `load`                                                      | the same result as the reference: the same syntax error message, or success                                                                                                                                                                              |
| `binary-diff` | the `binary` inputs, in batches through `load(..., "b")`                                           | the same result as the reference, except that the loader refuses an invalid opcode where the reference loads it                                                                                                                                          |

The generator (`gen.zig`) writes programs that print what they compute: arithmetic on integer and float edges, strings and the string library, tables, metatables and every metamethod, closures and varargs, coroutines, `goto`, to-be-closed variables, `load`, and errors raised inside `pcall`, whose messages carry variable names. Programs are deterministic: `pairs` goes through sorted keys, `math.randomseed(42)` comes first, and nothing reads the clock or prints an address.

The in-process fuzzers run inputs in a forked child that reports each input to the parent through shared memory before running it, so a crash or a hang is caught with the input that caused it. `--stack KIB` runs them on a thread with a small stack, as a host's worker thread.

`zig_fuzz.zig` holds the same compiler and loader properties as tests for Zig's own fuzzer, which is guided by coverage: `zig build fuzz-zig` runs each once, and `just fuzz-zig` fuzzes.

## What is not a finding

- Running a corrupted binary chunk that loaded: like the reference, the loader checks the format and the opcodes, not the code, so a well-formed malicious chunk can crash the interpreter. `binary` writes these to `known/` instead of `findings/`. Load binary chunks only from trusted sources.
- The standalone `lua` passes errors through a message handler that records the traceback beside the error instead of appending it to the error object. Where lua.c's handler is visible from Lua, the reference shows the traceback: a `__close` handler at the top level of a script receives the message with the traceback appended, and a "C stack overflow" raised while compiling has one. The generator prints only an error's first line in `__close` handlers, and `messages` drops the traceback.
- Metamethods run in the interpreter's own loop, not through a native call, so unbounded recursion through `__index`, `__eq`, or `__concat` functions ends in "stack overflow" where the reference says "C stack overflow".
