# lua: Lua 5.5 in Zig, with no C. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md bench/README.md docs/embedding.md docs/slop .github"

# The files all.lua runs, in its order, for `just suite BIN each`.
suite_files := "main gc db calls strings literals tpack attrib gengc locals constructs code big cstack nextvar pm utf8 api memerr events vararg closure coroutine goto errors math sort bitwise verybig files"

[private]
default:
    @just --list

[doc("Unit tests, in Debug and ReleaseSafe")]
[group("test")]
test:
    zig build test --summary all
    zig build test -Doptimize=ReleaseSafe --summary all

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

[doc("Compare our compiler's bytecode with the reference luac's: `luac -l -l -p` listings, addresses masked, for every suite and bench file, or only FILES")]
[group("test")]
bytecode *FILES:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build listing -Doptimize=ReleaseSafe
    files=({{ FILES }})
    if [ ${#files[@]} -eq 0 ]; then
        files=(test/lua-5.5.1-tests/*.lua bench/*.lua)
    fi
    out=zig-out/bytecode
    rm -rf "$out" && mkdir -p "$out"
    same=0
    differ=()
    for f in "${files[@]}"; do
        base=$out/$(echo "$f" | tr / _)
        luac -l -l -p "$f" 2>&1 | sed -E 's/ at 0x[0-9a-f]+\)$/ at 0x0)/; s/ for 0x[0-9a-f]+:$/ for 0x0:/; s/^(.*CLOSURE.*; )0x[0-9a-f]+$/\10x0/' > "$base.ref"
        zig-out/bin/listing "$f" > "$base.ours" 2>&1 || true
        if cmp -s "$base.ref" "$base.ours"; then
            same=$((same + 1))
        else
            differ+=("$f")
            diff "$base.ref" "$base.ours" | head -n 10 || true
        fi
    done
    echo "$same of ${#files[@]} files list the same bytecode as luac"
    if [ ${#differ[@]} -ne 0 ]; then
        printf 'differs: %s\n' "${differ[@]}"
        exit 1
    fi

[doc("Compare string.dump with the reference luac: for every suite and bench file, or only FILES, our dump of our compile must equal `luac -o` (and `luac -s -o` with strip), and luac's chunks must load on ours and dump back unchanged")]
[group("test")]
dump *FILES:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build -Doptimize=ReleaseSafe
    ours=$PWD/zig-out/bin/lua
    files=({{ FILES }})
    if [ ${#files[@]} -eq 0 ]; then
        files=(test/lua-5.5.1-tests/*.lua bench/*.lua)
    fi
    out=zig-out/dump
    rm -rf "$out" && mkdir -p "$out"
    # dump.lua FILE OUT STRIP MODE: dump loadfile(FILE, MODE) to OUT.
    script=$out/dump.lua
    echo 'local f = assert(loadfile(arg[1], arg[4])) local o = assert(io.open(arg[2], "wb")) o:write(string.dump(f, arg[3] == "s")) o:close()' > "$script"
    same=0
    differ=()
    for f in "${files[@]}"; do
        base=$out/$(echo "$f" | tr / _)
        for strip in n s; do
            flag=
            [ $strip = s ] && flag=-s
            luac $flag -o "$base.$strip.luac" "$f"
            "$ours" "$script" "$f" "$base.$strip.ours" $strip t
            "$ours" "$script" "$base.$strip.luac" "$base.$strip.back" $strip b
            if cmp "$base.$strip.luac" "$base.$strip.ours" && cmp "$base.$strip.luac" "$base.$strip.back"; then
                same=$((same + 1))
            else
                differ+=("$f ($strip)")
            fi
        done
    done
    echo "$same of $(( ${#files[@]} * 2 )) dumps are luac's, plain and stripped, both ways"
    if [ ${#differ[@]} -ne 0 ]; then
        printf 'differs: %s\n' "${differ[@]}"
        exit 1
    fi

[doc("Differential tests: every test/diff/*.lua, or only FILES, on our zig-out/bin/lua and the reference lua; stdout, stderr, and exit status must match, with addresses masked")]
[group("test")]
diff *FILES:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build -Doptimize=ReleaseSafe
    ref=$(command -v lua)
    ours=$PWD/zig-out/bin/lua
    files=({{ FILES }})
    if [ ${#files[@]} -eq 0 ]; then
        files=(test/diff/*.lua)
    fi
    out=$PWD/zig-out/diff
    rm -rf "$out" && mkdir -p "$out"
    failed=()
    for f in "${files[@]}"; do
        name=$(basename "$f" .lua)
        for arm in ref ours; do
            bin=$ref
            [ $arm = ours ] && bin=$ours
            status=0
            (cd "$(dirname "$f")" && "$bin" "$name.lua") > "$out/$name.$arm" 2>&1 || status=$?
            echo "exit status $status" >> "$out/$name.$arm"
            sed -i -E 's/: 0x[0-9a-f]+/: ADDR/g; s#^'"$bin"':#lua:#' "$out/$name.$arm"
        done
        if cmp -s "$out/$name.ref" "$out/$name.ours"; then
            echo "same     $f"
        else
            echo "DIFFERS  $f"
            diff "$out/$name.ref" "$out/$name.ours" | head -n 20 || true
            failed+=("$f")
        fi
    done
    [ ${#failed[@]} -eq 0 ]

# The build modes `just bench-compare` times our lua in, one arm each:
# `just optimize=ReleaseSafe bench-compare`, or "ReleaseFast ReleaseSafe".
optimize := "ReleaseFast"

[doc("Time every bench/ program, or only PROGRAMS, on our lua (built in each of `optimize`'s modes, ReleaseFast by default) and the reference lua: interleaved rounds on one core, wall time and peak RSS per run, checksums checked, then benchstat. The numbers are not claims")]
[group("bench")]
bench-compare ROUNDS="10" *PROGRAMS:
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/bench-compare
    rm -rf "$out" && mkdir -p "$out/stdout"
    arms=(ref)
    declare -A bin=([ref]="$(command -v lua)")
    # One mode is the arm `ours`; several are `ours-<mode>` each, built
    # into a copy so every arm keeps its binary.
    modes=({{ optimize }})
    for mode in "${modes[@]}"; do
        rm -f zig-out/bin/lua
        zig build -Doptimize="$mode"
        if [ ! -x zig-out/bin/lua ]; then
            echo "skipping our arm: build.zig does not install zig-out/bin/lua yet, so this times the reference alone"
            break
        fi
        arm=ours
        if [ ${#modes[@]} -gt 1 ]; then arm=ours-$mode; fi
        cp zig-out/bin/lua "$out/lua-$mode"
        arms+=("$arm")
        bin[$arm]=$PWD/$out/lua-$mode
    done
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
    # A row is one whole process, start to exit: its wall time, and its
    # peak RSS (getrusage's ru_maxrss, through GNU time's %M) as a second
    # benchstat unit.
    gnutime=$(type -P time)
    core=$(( $(nproc) - 1 ))
    n=${#arms[@]}
    for round in $(seq 0 $(( {{ ROUNDS }} - 1 ))); do
        echo "round $(( round + 1 ))/{{ ROUNDS }}" >&2
        for prog in "${programs[@]}"; do
            for i in $(seq 0 $(( n - 1 ))); do
                arm=${arms[$(( (round + i) % n ))]}
                status=0
                start=${EPOCHREALTIME/[.,]/}
                "$gnutime" -f %M -o "$out/rss" taskset -c "$core" "${bin[$arm]}" "bench/$prog.lua" > "$out/stdout/$prog.$arm.$round" 2>&1 || status=$?
                end=${EPOCHREALTIME/[.,]/}
                [ $status -eq 0 ] || echo "exit status $status" >> "$out/stdout/$prog.$arm.$round"
                printf 'BenchmarkLua/%s\t1\t%d ns/op\t%d peak-RSS-KiB\n' "$prog" $(( (end - start) * 1000 )) "$(tail -n 1 "$out/rss")" >> "$out/raw-$arm.txt"
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

[doc("The embedding API against the engine's own path (bench/api): each scenario, or only SCENARIOS, on both arms in interleaved rounds on one core, with time per operation and peak RSS, the work checked equal, then benchstat")]
[group("bench")]
bench-api ROUNDS="10" *SCENARIOS:
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/bench-api
    rm -rf "$out" && mkdir -p "$out"
    zig build bench-api -Doptimize=ReleaseFast
    bin=zig-out/bin/bench-api
    scenarios=({{ SCENARIOS }})
    if [ ${#scenarios[@]} -eq 0 ]; then
        scenarios=(lua_calls_zig zig_calls_lua zig_calls_lua_notb callback globals userdata_method decode_struct)
    fi
    arms=(internal api)
    for arm in "${arms[@]}"; do
        grep -m1 '^model name' /proc/cpuinfo | sed 's/^model name[[:space:]]*:[[:space:]]*/cpu: /' > "$out/$arm.txt"
    done
    gnutime=$(type -P time)
    core=$(( $(nproc) - 1 ))
    for round in $(seq 0 $(( {{ ROUNDS }} - 1 ))); do
        echo "round $(( round + 1 ))/{{ ROUNDS }}" >&2
        for s in "${scenarios[@]}"; do
            for i in 0 1; do
                arm=${arms[$(( (round + i) % 2 ))]}
                line=$("$gnutime" -f %M -o "$out/rss" taskset -c "$core" "$bin" "$arm" "$s" 2> "$out/check.$arm.$s")
                printf '%s\t%d peak-RSS-KiB\n' "$line" "$(tail -n 1 "$out/rss")" >> "$out/$arm.txt"
            done
            if ! cmp -s "$out/check.internal.$s" "$out/check.api.$s"; then
                echo "the arms did different work on $s" >&2
                exit 1
            fi
        done
    done
    benchstat internal="$out/internal.txt" api="$out/api.txt" | tee "$out/benchstat.txt"

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
