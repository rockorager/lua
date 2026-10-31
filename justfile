# lua: Lua 5.5 in Zig, with no C. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

markdown := "README.md AGENTS.md CHANGELOG.md THIRD_PARTY.md bench/README.md docs/embedding.md docs/slop .github test/fuzz"

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

[doc("The C API (built with -Dc-api=true): C modules built against zig-out/include run on our lua and on the reference, and must print the same: the suite's libs/ under attrib.lua with _port off, test/capi/capitest.c's errors and continuations, io handles shared with C (stream.c, luaposix's posix.stdio), libraries closed with the state (unload.c), the own tests of lpeg, lua-cjson, and luafilesystem, and the C-API build's io and os on files.lua and test/diff; test/capi/host.c, a C host, on our liblua.so and liblua.a against the reference's liblua.so; then capi-coverage. With TARGET (aarch64-linux-gnu), the same cross-built and run under qemu-user against the reference built for TARGET")]
[group("test")]
capi-test TARGET="":
    #!/usr/bin/env bash
    set -euo pipefail
    target="{{ TARGET }}"
    out=$PWD/zig-out/capi${target:+-$target}
    rm -rf "$out" && mkdir -p "$out"
    if [ -z "$target" ]; then
        zig build -Dc-api=true -Doptimize=ReleaseSafe
        ours=$PWD/zig-out/bin/lua
        ref=$(command -v lua)
        inc=$PWD/zig-out/include
        cc=(cc)
    else
        # Another Linux target: our lua and the modules cross-built, and both
        # interpreters run under qemu-user, the reference as nixpkgs builds
        # it for that machine, fetched from the flake's nixpkgs.
        zig build -Dc-api=true -Doptimize=ReleaseSafe -Dtarget="$target" --prefix "$out/zig"
        arch=${target%%-*}
        pkg() { nix build --no-link --print-out-paths --inputs-from . "nixpkgs#$1"; }
        qemu=$(pkg qemu-user)/bin/qemu-$arch
        mkdir -p "$out/root" && ln -s "$(pkg "legacyPackages.$arch-linux.glibc^out")/lib" "$out/root/lib"
        reflua=$(pkg "legacyPackages.$arch-linux.lua5_5")/bin/lua
        # argv[0] is the wrapper's path, which `run` masks.
        printf '#!/bin/sh\nexec %s -L %s -0 "$0" %s "$@"\n' "$qemu" "$out/root" "$out/zig/bin/lua" > "$out/ours"
        printf '#!/bin/sh\nexec %s -0 "$0" %s "$@"\n' "$qemu" "$reflua" > "$out/ref"
        chmod +x "$out/ours" "$out/ref"
        ours=$out/ours
        ref=$out/ref
        inc=$out/zig/include
        cc=(zig cc -target "$target")
    fi
    cflags=(-Wall -O2 "-I$inc" -fPIC -shared)
    failed=()
    # run NAME DIR FILTER CMD...: CMD on both interpreters ($LUA in it),
    # output and exit status compared after FILTER, addresses masked.
    run() {
        local name=$1 dir=$2 filter=$3
        shift 3
        for arm in ref ours; do
            local bin=$ref
            [ $arm = ours ] && bin=$ours
            local status=0
            (cd "$dir" && LUA=$bin "$@") > "$out/$name.$arm" 2>&1 || status=$?
            echo "exit status $status" >> "$out/$name.$arm"
            sed -i -E 's/0x[0-9a-f]+/ADDR/g; s#^'"$bin"':#lua:#' "$out/$name.$arm"
        done
        if cmp -s <($filter < "$out/$name.ref") <($filter < "$out/$name.ours"); then
            echo "same     $name"
        else
            echo "DIFFERS  $name"
            diff <($filter < "$out/$name.ref") <($filter < "$out/$name.ours") | head -n 20 || true
            failed+=("$name")
        fi
    }
    # The suite's C modules, built as its makefile builds them.
    s=$out/suite
    mkdir -p "$s/libs/P1"
    cp test/lua-5.5.1-tests/attrib.lua "$s/"
    for lib in lib1 lib11 lib2 lib21; do "${cc[@]}" "${cflags[@]}" -o "$s/libs/$lib.so" "test/lua-5.5.1-tests/libs/$lib.c"; done
    "${cc[@]}" "${cflags[@]}" -o "$s/libs/lib2-v2.so" test/lua-5.5.1-tests/libs/lib22.c
    run attrib "$s" cat sh -c '"$LUA" -e"_U=true _soft=true _nomsg=true" attrib.lua'
    # Errors, continuations, and lauxlib.
    "${cc[@]}" "${cflags[@]}" -o "$out/capitest.so" test/capi/capitest.c
    run capitest test/capi cat sh -c 'LUA_CPATH="'"$out"'/?.so" "$LUA" -W errors.lua'
    # lpeg.
    mkdir -p "$out/lpeg" && tar xzf "$LPEG_SRC" -C "$out/lpeg" --strip-components=1
    (cd "$out/lpeg" && "${cc[@]}" "${cflags[@]}" -std=c99 -o lpeg.so lpvm.c lpcap.c lptree.c lpcode.c lpprint.c lpcset.c)
    run lpeg "$out/lpeg" cat sh -c '"$LUA" test.lua'
    # lua-cjson: its table output follows hash order, which differs, so
    # only the verdicts compare.
    cp -r "$LUA_CJSON_SRC" "$out/cjson" && chmod -R u+w "$out/cjson"
    (cd "$out/cjson" && "${cc[@]}" "${cflags[@]}" -o cjson.so lua_cjson.c strbuf.c fpconv.c && cd tests && perl genutf8.pl > utf8.dat 2> /dev/null)
    run cjson "$out/cjson/tests" "grep -E ^(==>|exit)" sh -c 'LUA_PATH="../lua/?.lua;;" LUA_CPATH="../?.so" "$LUA" test.lua'
    # luafilesystem, whose setmode and lock read io's files as luaL_Stream.
    cp -r "$LFS_SRC" "$out/lfs" && chmod -R u+w "$out/lfs"
    (cd "$out/lfs" && "${cc[@]}" "${cflags[@]}" -o lfs.so src/lfs.c)
    run lfs "$out/lfs/tests" cat sh -c 'LUA_CPATH="../?.so" "$LUA" test.lua'
    run lfs-lock test/capi cat sh -c 'LUA_CPATH="'"$out"'/lfs/?.so" "$LUA" lock.lua'
    # io handles shared with C modules: stream.c, and luaposix's posix.stdio
    # (fileno, fdopen) with the modules its cases use.
    "${cc[@]}" "${cflags[@]}" -o "$out/stream.so" test/capi/stream.c
    run handles test/capi cat sh -c 'LUA_CPATH="'"$out"'/?.so" "$LUA" handles.lua'
    p=$out/posix && mkdir -p "$p/posix/sys"
    for m in stdio unistd fcntl sys/stat; do
        "${cc[@]}" "${cflags[@]}" -w -I"$LUAPOSIX_SRC/ext/include" -DPACKAGE='"luaposix"' -DVERSION='"test"' -D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L -o "$p/posix/$m.so" "$LUAPOSIX_SRC/ext/posix/$m.c"
    done
    run posix test/capi cat sh -c 'LUA_CPATH="'"$p"'/?.so" "$LUA" posix.lua'
    # Libraries close with the state, after every finalizer, the last
    # loaded first.
    for n in 1 2; do "${cc[@]}" "${cflags[@]}" -DN=$n -o "$out/unload$n.so" test/capi/unload.c; done
    run unload test/capi cat sh -c 'LUA_CPATH="'"$out"'/?.so" "$LUA" unload.lua'
    # The C-API build's io is C's stdio, not the default build's: the
    # suite's files.lua (but its clock line) and every differential test.
    run files test/lua-5.5.1-tests "grep -v ^test.done.on" sh -c '"$LUA" -e"_U=true _soft=true _port=true _nomsg=true" files.lua'
    for f in test/diff/*.lua; do
        # Under qemu-user glibc's system() leaves errno ENOSYS from a clone3
        # that qemu refuses, so the foreign reference's os.execute of a
        # failing command reports that error; io_os takes the native
        # reference instead.
        saved=$ref
        if [ -n "$target" ] && [ "$f" = test/diff/io_os.lua ]; then ref=$(command -v lua); fi
        run "diff-$(basename "$f" .lua)" test/diff cat sh -c '"$LUA" '"$(basename "$f")"
        ref=$saved
    done
    # A C host embedding liblua (test/capi/host.c): built against the
    # reference's liblua.so, ours, and our liblua.a (exporting its lua_*
    # for the unload modules, as lua.c's -Wl,-E), and run alone.
    if [ -z "$target" ]; then
        refdir=$(dirname "$(dirname "$(readlink -f "$ref")")")
        runner=()
    else
        refdir=$(dirname "$(dirname "$reflua")")
        runner=("$qemu" -L "$out/root")
    fi
    lib=$(dirname "$inc")/lib
    "${cc[@]}" -Wall -O2 "-I$refdir/include" -o "$out/host-ref" test/capi/host.c "$refdir/lib/liblua.so" "-Wl,-rpath,$refdir/lib"
    "${cc[@]}" -Wall -O2 "-I$inc" -o "$out/host-so" test/capi/host.c "$lib/liblua.so" "-Wl,-rpath,$lib"
    "${cc[@]}" -Wall -O2 "-I$inc" -Wl,-z,noexecstack -Wl,-E -o "$out/host-a" test/capi/host.c "$lib/liblua.a"
    for kind in so a; do
        hostrun() { if [ "$LUA" = "$ref" ]; then "${runner[@]}" "$out/host-ref"; else "${runner[@]}" "$out/host-$kind"; fi; }
        run "host-$kind" "$out" cat hostrun
    done
    just capi-coverage "$lib/liblua.so" "$(dirname "$inc")/bin/lua"
    [ ${#failed[@]} -eq 0 ] || { printf 'differs: %s\n' "${failed[@]}"; exit 1; }

[doc("Coverage of the C API: every function lua.h, lauxlib.h, and lualib.h declare must be a defined dynamic symbol of each BINARY (built with -Dc-api=true), and nothing else named lua_*, luaL_*, or luaopen_* may be")]
[group("test")]
capi-coverage +BINARIES:
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/capi-coverage
    mkdir -p "$out"
    # Every declaration names its function in parentheses, as in
    # `LUA_API int (lua_gettop) (lua_State *L);`.
    grep -hoE '^(LUA_API|LUALIB_API|LUAMOD_API)\b[^;]*' include/lua.h include/lauxlib.h include/lualib.h |
        grep -oE '\((lua[L]?_[a-z_]+|luaopen_[a-z0-9]+)\)' | tr -d '()' | sort -u > "$out/declared"
    status=0
    for bin in {{ BINARIES }}; do
        nm -D --defined-only "$bin" | awk '$2 == "T" { print $3 }' | grep -E '^(lua[L]?_|luaopen_)' | sort -u > "$out/exported"
        missing=$(comm -23 "$out/declared" "$out/exported")
        extra=$(comm -13 "$out/declared" "$out/exported")
        echo "$bin: $(comm -12 "$out/declared" "$out/exported" | wc -l) of $(wc -l < "$out/declared") declared functions exported"
        if [ -n "$missing" ]; then echo "missing:" $missing; status=1; fi
        if [ -n "$extra" ]; then echo "not in the headers:" $extra; status=1; fi
    done
    exit $status

[doc("The C API's costs (bench/capi): CPU ns per call of a C function in a tight loop (nop, add, callback, and the empty loop), our C-API lua against the reference, and startup (`lua -e ''`) wall time and peak RSS on the reference, our default build, and our C-API build, in interleaved rounds on one core, then benchstat; and the native stack bytes per level of C -> lua_call -> Lua nesting")]
[group("bench")]
bench-capi ROUNDS="10" N="10000000":
    #!/usr/bin/env bash
    set -euo pipefail
    out=$PWD/zig-out/bench-capi
    rm -rf "$out" && mkdir -p "$out"
    zig build -Doptimize=ReleaseFast --prefix "$out/default"
    zig build -Doptimize=ReleaseFast -Dc-api=true --prefix "$out/capi"
    cc -Wall -O2 "-I$out/capi/include" -fPIC -shared -o "$out/capibench.so" bench/capi/capibench.c
    declare -A bin=([ref]="$(command -v lua)" [default]="$out/default/bin/lua" [capi]="$out/capi/bin/lua")
    cpu=$(grep -m1 '^model name' /proc/cpuinfo | sed 's/^model name[[:space:]]*:[[:space:]]*/cpu: /')
    for f in calls-ref calls-capi start-ref start-default start-capi; do echo "$cpu" > "$out/$f.txt"; done
    gnutime=$(type -P time)
    core=$(( $(nproc) - 1 ))
    export LUA_CPATH="$out/?.so"
    for round in $(seq 0 $(( {{ ROUNDS }} - 1 ))); do
        echo "round $(( round + 1 ))/{{ ROUNDS }}" >&2
        calls=(ref capi)
        for s in loop nop add callback; do
            for i in 0 1; do
                arm=${calls[$(( (round + i) % 2 ))]}
                (cd bench/capi && taskset -c "$core" "${bin[$arm]}" calls.lua $s {{ N }} 2> "$out/sum.$arm.$s") >> "$out/calls-$arm.txt"
            done
            cmp -s "$out/sum.ref.$s" "$out/sum.capi.$s" || { echo "the arms computed different sums on $s" >&2; exit 1; }
        done
        # Startup: 20 runs of `lua -e ''` per row. GNU time runs under
        # taskset, not over it: ru_maxrss keeps the high-water mark across
        # exec, so taskset's own 2.3 MiB would floor every arm.
        starts=(ref default capi)
        for i in 0 1 2; do
            arm=${starts[$(( (round + i) % 3 ))]}
            start=${EPOCHREALTIME/[.,]/}
            for _ in $(seq 20); do taskset -c "$core" "$gnutime" -f %M -o "$out/rss" "${bin[$arm]}" -e ''; done
            end=${EPOCHREALTIME/[.,]/}
            printf 'BenchmarkStartup\t20\t%d ns/op\t%d peak-RSS-KiB\n' $(( (end - start) * 50 )) "$(tail -n 1 "$out/rss")" >> "$out/start-$arm.txt"
        done
    done
    benchstat ref="$out/calls-ref.txt" capi="$out/calls-capi.txt" | tee "$out/benchstat.txt"
    benchstat ref="$out/start-ref.txt" default="$out/start-default.txt" capi="$out/start-capi.txt" | tee -a "$out/benchstat.txt"
    for arm in ref capi; do
        echo "native stack per C -> Lua level, $arm: $(cd bench/capi && "${bin[$arm]}" calls.lua stack 100) bytes" | tee -a "$out/benchstat.txt"
    done

[doc("Regenerate src/order.ld, the order of lua's code: trace the functions it calls first in `lua -e ''` and test/order/sample.lua, in the default and C-API ReleaseFast builds and the ReleaseSafe build")]
[group("bench")]
order:
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/order
    rm -rf "$out" && mkdir -p "$out"
    zig build order -Doptimize=ReleaseFast
    zig build -Doptimize=ReleaseFast --prefix "$out/default"
    zig build -Doptimize=ReleaseFast -Dc-api=true --prefix "$out/capi"
    zig build -Doptimize=ReleaseSafe --prefix "$out/safe"
    # Startup in every build first, then the sample script in every build.
    runs=()
    for args in "-e ''" test/order/sample.lua; do
        for arm in default capi safe; do
            eval "runs+=(-- $out/$arm/bin/lua $args)"
        done
    done
    # In the dev shell's environment: dozens of variables, as a login
    # has, and LUA_PATH and LUA_CPATH ";;", so startup expands the default
    # paths as many installs do.
    zig-out/bin/order src/order.ld "${runs[@]}" > /dev/null
    echo "src/order.ld: $(grep -c '^    \*' src/order.ld) functions"

# The build modes `just bench-compare` times our lua in, one arm each:
# `just optimize=ReleaseSafe bench-compare`, or "ReleaseFast ReleaseSafe".
# A mode with a `-capi` suffix builds with -Dc-api=true.
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
        capi=false
        [ "${mode%-capi}" != "$mode" ] && capi=true
        zig build -Doptimize="${mode%-capi}" -Dc-api=$capi
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
    # benchstat unit. GNU time runs under taskset, not over it: ru_maxrss
    # keeps the high-water mark across exec, so taskset's own 2.3 MiB would
    # floor every arm.
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
                taskset -c "$core" "$gnutime" -f %M -o "$out/rss" "${bin[$arm]}" "bench/$prog.lua" > "$out/stdout/$prog.$arm.$round" 2>&1 || status=$?
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
        scenarios=(lua_calls_zig zig_calls_lua zig_calls_lua_notb callback globals userdata_method decode_struct lua_calls_bound call_values zig_resumes)
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
                line=$(taskset -c "$core" "$gnutime" -f %M -o "$out/rss" "$bin" "$arm" "$s" 2> "$out/check.$arm.$s")
                printf '%s\t%d peak-RSS-KiB\n' "$line" "$(tail -n 1 "$out/rss")" >> "$out/$arm.txt"
            done
            if ! cmp -s "$out/check.internal.$s" "$out/check.api.$s"; then
                echo "the arms did different work on $s" >&2
                exit 1
            fi
        done
    done
    benchstat internal="$out/internal.txt" api="$out/api.txt" | tee "$out/benchstat.txt"

# The build mode of the fuzz recipes: ReleaseSafe, or Debug to keep the
# 0xAA fill that catches reads of freed or uninitialized objects.
fuzz_mode := "ReleaseSafe"

[doc("Fuzz each TARGET for SECONDS (60 by default): parse, grammar, binary, or oom in process, or diff, bytecode, messages, or binary-diff against the reference; `all` runs every one. ARGS go to the driver (--seed N, --gc-stress full). `just fuzz_mode=Debug fuzz ...` builds in Debug, which keeps the 0xAA fill of freed and new objects. Findings, minimized, go to zig-out/fuzz/ and fail the recipe; test/fuzz/README.md says what each checks")]
[group("fuzz")]
fuzz TARGET="all" SECONDS="60" *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build fuzz listing -Doptimize={{ fuzz_mode }}
    rm -f zig-out/bin/lua
    zig build -Doptimize={{ fuzz_mode }}
    targets=({{ TARGET }})
    [ "${targets[*]}" = all ] && targets=(parse grammar binary oom diff bytecode messages binary-diff)
    status=0
    for t in "${targets[@]}"; do
        case $t in
            parse | grammar | binary | oom) zig-out/bin/fuzz run "$t" --seconds {{ SECONDS }} {{ ARGS }} || status=1 ;;
            *) zig-out/bin/fuzz "$t" --seconds {{ SECONDS }} {{ ARGS }} || status=1 ;;
        esac
    done
    exit $status

[doc("The C-API fuzzers for SECONDS each, on a -Dc-api=true build in zig-out/fuzz-capi: `run capi`, allocation failure at every index through the calls of test/fuzz/capifuzz.c, a C module, and `capi-diff`, generated C-API workloads on our lua and the reference with the same capifuzz.so. ARGS go to the driver. Findings go to zig-out/fuzz/")]
[group("fuzz")]
fuzz-capi SECONDS="60" *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    out=zig-out/fuzz-capi
    zig build fuzz -Dc-api=true -Doptimize={{ fuzz_mode }} --prefix "$out"
    zig build -Dc-api=true -Doptimize={{ fuzz_mode }} --prefix "$out"
    cc -Wall -Wextra -O2 "-I$out/include" -fPIC -shared -o "$out/lib/capifuzz.so" test/fuzz/capifuzz.c
    status=0
    "$out/bin/fuzz" run capi --module "$out/lib" --seconds {{ SECONDS }} {{ ARGS }} || status=1
    "$out/bin/fuzz" capi-diff --ours "$out/bin/lua" --module "$out/lib" --seconds {{ SECONDS }} {{ ARGS }} || status=1
    exit $status

[doc("Fuzz under collector stress for SECONDS each: grammar and oom in process with --gc-stress full, and diff on a lua built with -Dgc-stress=full. Findings go to zig-out/fuzz/stress/")]
[group("fuzz")]
fuzz-stress SECONDS="60" *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build fuzz -Doptimize={{ fuzz_mode }}
    zig build -Doptimize={{ fuzz_mode }} -Dgc-stress=full --prefix zig-out/stress
    status=0
    for t in grammar oom; do
        zig-out/bin/fuzz run $t --gc-stress full --seconds {{ SECONDS }} --out zig-out/fuzz/stress {{ ARGS }} || status=1
    done
    zig-out/bin/fuzz diff --ours zig-out/stress/bin/lua --seconds {{ SECONDS }} --out zig-out/fuzz/stress {{ ARGS }} || status=1
    exit $status

[doc("Zig's coverage-guided fuzzer on test/fuzz/zig_fuzz.zig (the compiler, the loader, and generated programs) for ITERATIONS inputs, in `fuzz_mode`")]
[group("fuzz")]
fuzz-zig ITERATIONS="200K":
    zig build fuzz-zig -Doptimize={{ fuzz_mode }} --fuzz={{ ITERATIONS }}

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    zig fmt --check src test build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check {{ markdown }}
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src test build.zig build.zig.zon
    nix fmt
    oxfmt {{ markdown }}
    just --fmt

[doc("Everything CI runs")]
[group("ci")]
ci: test lint
