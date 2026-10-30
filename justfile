# lua: Lua 5.5 in Zig, with no C. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md bench/README.md docs/slop .github"

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

[doc("Time every bench/ program, or only PROGRAMS, on our zig-out/bin/lua (ReleaseFast) and the reference lua: interleaved rounds on one core, checksums checked, then benchstat. The numbers are not claims")]
[group("bench")]
bench-compare ROUNDS="10" *PROGRAMS:
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/bench-compare
    rm -rf "$out" && mkdir -p "$out/stdout"
    arms=(ref)
    declare -A bin=([ref]="$(command -v lua)")
    rm -f zig-out/bin/lua
    zig build -Doptimize=ReleaseFast
    if [ -x zig-out/bin/lua ]; then
        arms+=(ours)
        bin[ours]=$PWD/zig-out/bin/lua
    else
        echo "skipping our arm: build.zig does not install zig-out/bin/lua yet, so this times the reference alone"
    fi
    programs=({{ PROGRAMS }})
    if [ ${#programs[@]} -eq 0 ]; then
        programs=($(cd bench && ls -- *.lua | sed 's/\.lua$//'))
    fi
    for prog in "${programs[@]}"; do
        [ -f "bench/$prog.lua" ] || { echo "no bench/$prog.lua" >&2; exit 1; }
    done
    # The same config line heads every arm's file, so benchstat puts them in
    # one table.
    for arm in "${arms[@]}"; do
        grep -m1 '^model name' /proc/cpuinfo | sed 's/^model name[[:space:]]*:[[:space:]]*/cpu: /' > "$out/$arm.txt"
    done
    # The last core, and one run of each arm at a time in an order that
    # rotates each round, so drift on the machine lands on every arm alike.
    # A row is one whole process, start to exit, in wall time.
    core=$(( $(nproc) - 1 ))
    n=${#arms[@]}
    for round in $(seq 0 $(( {{ ROUNDS }} - 1 ))); do
        echo "round $(( round + 1 ))/{{ ROUNDS }}" >&2
        for prog in "${programs[@]}"; do
            for i in $(seq 0 $(( n - 1 ))); do
                arm=${arms[$(( (round + i) % n ))]}
                status=0
                start=${EPOCHREALTIME/[.,]/}
                taskset -c "$core" "${bin[$arm]}" "bench/$prog.lua" > "$out/stdout/$prog.$arm.$round" 2>&1 || status=$?
                end=${EPOCHREALTIME/[.,]/}
                [ $status -eq 0 ] || echo "exit status $status" >> "$out/stdout/$prog.$arm.$round"
                printf 'BenchmarkLua/%s\t1\t%d ns/op\n' "$prog" $(( (end - start) * 1000 )) >> "$out/raw-$arm.txt"
            done
        done
    done
    # Every run must print what the reference's first run printed, or its
    # timings mean nothing: a mismatched program's rows are dropped.
    bad=()
    for arm in "${arms[@]}"; do
        skip=()
        for prog in "${programs[@]}"; do
            for round in $(seq 0 $(( {{ ROUNDS }} - 1 ))); do
                if ! cmp -s "$out/stdout/$prog.ref.0" "$out/stdout/$prog.$arm.$round"; then
                    echo "checksum mismatch: $prog on $arm, round $(( round + 1 )):"
                    diff "$out/stdout/$prog.ref.0" "$out/stdout/$prog.$arm.$round" | head -n 20 || true
                    skip+=("$prog")
                    bad+=("$prog on $arm")
                    break
                fi
            done
        done
        awk -v skip=" ${skip[*]} " 'index(skip, " " substr($1, 14) " ") == 0' "$out/raw-$arm.txt" >> "$out/$arm.txt"
    done
    args=()
    for arm in "${arms[@]}"; do args+=("$arm=$out/$arm.txt"); done
    benchstat "${args[@]}" | tee "$out/benchstat.txt"
    if [ ${#bad[@]} -ne 0 ]; then
        printf 'checksums differ: %s\n' "${bad[@]}" >&2
        exit 1
    fi

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check {{ markdown }}
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src build.zig build.zig.zon
    nix fmt
    oxfmt {{ markdown }}
    just --fmt

[doc("Everything CI runs")]
[group("ci")]
ci: test lint
