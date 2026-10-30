# lua: Lua 5.5 in Zig, with no C. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md bench/README.md docs/slop .github"

# The files all.lua runs, in its order, for `just suite BIN each`.
suite_files := "main gc db calls strings literals tpack attrib gengc locals constructs code big cstack nextvar pm utf8 api memerr events vararg closure coroutine goto errors math sort bitwise verybig files"

[private]
default:
    @just --list

[doc("Unit tests")]
[group("test")]
test:
    zig build test --summary all

[doc("The official suite on BIN: ours (zig-out/bin/lua, built ReleaseSafe), ref (the dev shell's lua), or a path. With no FILES it runs all.lua with _U=true; FILES (or `each` for all of them) runs each file alone and prints one line per file")]
[group("test")]
suite BIN="ours" *FILES:
    #!/usr/bin/env bash
    set -euo pipefail
    case "{{ BIN }}" in
        ours)
            rm -f zig-out/bin/lua
            zig build -Doptimize=ReleaseSafe
            if [ ! -x zig-out/bin/lua ]; then
                echo "no zig-out/bin/lua: build.zig does not install a lua executable yet. Run 'just suite ref' for the reference" >&2
                exit 1
            fi
            bin=$PWD/zig-out/bin/lua
            ;;
        ref) bin=$(command -v lua) ;;
        *) bin=$(realpath "{{ BIN }}") ;;
    esac
    files=({{ FILES }})
    [ "${files[*]}" = each ] && files=({{ suite_files }})
    log=$PWD/zig-out/suite
    # lua.org's instructions: run from the suite's directory. main.lua starts
    # the interpreter again by name, so the path is absolute.
    cd test/lua-5.5.1-tests
    if [ ${#files[@]} -eq 0 ]; then
        exec "$bin" -e"_U=true" all.lua
    fi
    # Alone, a file gets the globals all.lua sets under _U. It skips all.lua's
    # string.dump round trip.
    rm -rf "$log" && mkdir -p "$log"
    failed=0
    for f in "${files[@]}"; do
        f=${f%.lua}
        if "$bin" -e"_U=true _soft=true _port=true _nomsg=true" "$f.lua" > "$log/$f.txt" 2>&1; then
            echo "ok    $f"
        else
            echo "FAIL  $f    zig-out/suite/$f.txt: $(tail -n 1 "$log/$f.txt")"
            failed=1
        fi
    done
    exit $failed

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
