//! The C API's unwinding invariant, checked: no Zig frame with a pending
//! `defer` or `errdefer` lies between a protected call into C and the
//! jump that ends it (docs/slop/c-api.md). `capi.throw` jumps over every
//! frame between it and the innermost protected call, running none of
//! their deferred code, so such a frame would leak or corrupt what its
//! defer was to clean up.
//!
//! The check reads the sources with Zig's tokenizer:
//!
//! - A function may throw if it calls `capi.throw`, calls a function that
//!   may throw, or calls C code directly (a function-typed value, or a
//!   field of a C callback type such as `lua_Writer`), since C code may
//!   call an API function that throws. A call through `protect` is not a
//!   call: the jump it catches stops there.
//! - In every function of `src/capi/`, no call that may throw comes after
//!   a `defer` or `errdefer` that is still pending, nor inside one.
//! - No code outside `src/capi/` calls a C-API function that may throw:
//!   Zig natives sit below no protected call of their own.
//!
//! The tests run it on the tree and on sources seeded with each kind of
//! violation.

const std = @import("std");
const Tokenizer = std.zig.Tokenizer;
const Tag = std.zig.Token.Tag;

pub const Source = struct {
    /// The path from the repository root, such as "src/capi/capi.zig".
    path: []const u8,
    text: [:0]const u8,
};

/// The C callback types of lua.h, whose calls run C code.
const callback_types = [_][]const u8{
    "lua_CFunction", "lua_KFunction", "lua_Reader", "lua_Writer", "lua_Alloc", "lua_WarnFunction", "lua_Hook",
};

/// Files of `src/capi/` the check leaves out: the jump itself, and this.
const skipped = [_][]const u8{ "jmp.zig", "unwind.zig" };

const Tok = struct { tag: Tag, text: []const u8, line: u32 };

const Call = struct {
    tok: usize,
    target: Target,
};

const Target = union(enum) {
    none,
    callback,
    func: usize,
};

const Func = struct {
    file: usize,
    name: []const u8,
    /// Declared inside a struct, so a field call (`x.name(...)`) can
    /// reach it.
    member: bool,
    /// The tokens between the body's braces.
    start: usize,
    end: usize,
    may_throw: bool = false,
};

const File = struct {
    path: []const u8,
    toks: []Tok,
    capi: bool,
    /// Import aliases of C-API files: name -> file index.
    imports: std.StringHashMapUnmanaged(usize) = .empty,
    /// `const name = alias.func;`: name -> (file, func name).
    aliases: std.StringHashMapUnmanaged(struct { usize, []const u8 }) = .empty,
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    violations: std.ArrayList([]const u8) = .empty,
    files: []File = &.{},
    funcs: std.ArrayList(Func) = .empty,

    pub fn deinit(r: *Report) void {
        r.arena.deinit();
        r.* = undefined;
    }

    /// Whether function `name` of the file at `path` may throw; null if
    /// there is no such function.
    pub fn mayThrow(r: *const Report, path: []const u8, name: []const u8) ?bool {
        for (r.funcs.items) |f| {
            if (std.mem.eql(u8, f.name, name) and std.mem.eql(u8, r.files[f.file].path, path)) return f.may_throw;
        }
        return null;
    }
};

pub fn analyze(gpa: std.mem.Allocator, sources: []const Source) !Report {
    var r: Report = .{ .arena = .init(gpa) };
    errdefer r.deinit();
    const a = r.arena.allocator();
    var callback_fields: std.StringHashMapUnmanaged(void) = .empty;
    r.files = try a.alloc(File, sources.len);
    for (sources, r.files) |src, *file| {
        file.* = .{ .path = src.path, .toks = try tokenize(a, src.text), .capi = isCapi(src.path) };
    }
    // Imports, then aliases through them.
    for (r.files) |*file| try findImports(a, r.files, file);
    // Functions, and the fields of C callback types.
    for (r.files, 0..) |*file, fi| {
        if (!file.capi) continue;
        try scanContainer(a, &r, fi, 0, file.toks.len, true, &callback_fields);
    }
    // Calls, resolved.
    var calls: std.ArrayList(std.ArrayList(Call)) = .empty;
    for (r.funcs.items) |f| {
        var list: std.ArrayList(Call) = .empty;
        try collectCalls(a, &r, f.file, f.start, f.end, &callback_fields, &list);
        try calls.append(a, list);
    }
    // May throw: `capi.throw`, and whatever reaches it or C code.
    for (r.funcs.items) |*f| {
        if (std.mem.eql(u8, f.name, "throw") and std.mem.endsWith(u8, r.files[f.file].path, "capi/capi.zig"))
            f.may_throw = true;
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (r.funcs.items, calls.items) |*f, list| {
            if (f.may_throw) continue;
            for (list.items) |c| if (throws(&r, c.target)) {
                f.may_throw = true;
                changed = true;
                break;
            };
        }
    }
    // Pending defers at calls that may throw.
    for (r.funcs.items) |f| try checkDefers(a, &r, f, &callback_fields);
    // Zig code outside the C API calling into it.
    for (r.files, 0..) |file, fi| {
        if (file.capi) continue;
        var list: std.ArrayList(Call) = .empty;
        try collectCalls(a, &r, fi, 0, file.toks.len, &callback_fields, &list);
        for (list.items) |c| if (c.target == .func and r.funcs.items[c.target.func].may_throw) {
            const t = file.toks[c.tok];
            const fmt = "{s}:{d}: Zig code outside src/capi calls {s}, which may throw";
            try r.violations.append(a, try std.fmt.allocPrint(a, fmt, .{ file.path, t.line, t.text }));
        };
    }
    return r;
}

fn isCapi(path: []const u8) bool {
    if (std.mem.find(u8, path, "capi/") == null) return false;
    for (skipped) |s| if (std.mem.endsWith(u8, path, s)) return false;
    return true;
}

fn throws(r: *const Report, t: Target) bool {
    return switch (t) {
        .none => false,
        .callback => true,
        .func => |i| r.funcs.items[i].may_throw,
    };
}

fn tokenize(a: std.mem.Allocator, text: [:0]const u8) ![]Tok {
    var list: std.ArrayList(Tok) = .empty;
    var tz = Tokenizer.init(text);
    var line: u32 = 1;
    var pos: usize = 0;
    while (true) {
        const t = tz.next();
        line += @intCast(std.mem.count(u8, text[pos..t.loc.start], "\n"));
        pos = t.loc.start;
        if (t.tag == .eof) break;
        try list.append(a, .{ .tag = t.tag, .text = text[t.loc.start..t.loc.end], .line = line });
    }
    return list.items;
}

/// The index of the token that closes the bracket opened at `i`.
fn matching(toks: []const Tok, i: usize) usize {
    const open = toks[i].tag;
    const close: Tag = switch (open) {
        .l_paren => .r_paren,
        .l_brace => .r_brace,
        .l_bracket => .r_bracket,
        else => unreachable,
    };
    var depth: usize = 0;
    var j = i;
    while (j < toks.len) : (j += 1) {
        if (toks[j].tag == open) depth += 1;
        if (toks[j].tag == close) {
            depth -= 1;
            if (depth == 0) return j;
        }
    }
    return toks.len - 1;
}

fn findImports(a: std.mem.Allocator, files: []File, file: *File) !void {
    const toks = file.toks;
    var i: usize = 0;
    while (i + 6 < toks.len) : (i += 1) {
        if (toks[i].tag != .keyword_const or toks[i + 1].tag != .identifier or toks[i + 2].tag != .equal) continue;
        const is_import = toks[i + 3].tag == .builtin and std.mem.eql(u8, toks[i + 3].text, "@import");
        if (is_import and toks[i + 5].tag == .string_literal) {
            const lit = toks[i + 5].text;
            const path = lit[1 .. lit.len - 1];
            for (files, 0..) |other, oi| {
                if (!other.capi) continue;
                const base = std.Io.Dir.path.basename(other.path);
                if (!std.mem.eql(u8, std.Io.Dir.path.basename(path), base)) continue;
                // From inside src/capi a bare name; from outside, through capi/.
                if (file.capi or std.mem.find(u8, path, "capi/") != null)
                    try file.imports.put(a, toks[i + 1].text, oi);
            }
        }
    }
    i = 0;
    while (i + 6 < toks.len) : (i += 1) {
        if (toks[i].tag != .keyword_const or toks[i + 1].tag != .identifier or toks[i + 2].tag != .equal) continue;
        const is_alias = toks[i + 3].tag == .identifier and toks[i + 4].tag == .period and
            toks[i + 5].tag == .identifier and toks[i + 6].tag == .semicolon;
        if (is_alias) {
            if (file.imports.get(toks[i + 3].text)) |target|
                try file.aliases.put(a, toks[i + 1].text, .{ target, toks[i + 5].text });
        }
    }
}

/// Registers the functions declared between `start` and `end`, a file or
/// a container's body, and the container fields of C callback types.
fn scanContainer(
    a: std.mem.Allocator,
    r: *Report,
    fi: usize,
    start: usize,
    end: usize,
    top: bool,
    callback_fields: *std.StringHashMapUnmanaged(void),
) !void {
    const toks = r.files[fi].toks;
    var i = start;
    while (i < end) {
        const t = toks[i];
        if (t.tag == .keyword_fn and i + 2 < end and toks[i + 1].tag == .identifier and toks[i + 2].tag == .l_paren) {
            i = try declare(a, r, fi, i, !top, callback_fields);
            continue;
        }
        if (t.tag == .l_brace) {
            const e = matching(toks, i);
            try scanContainer(a, r, fi, i + 1, e, false, callback_fields);
            i = e + 1;
            continue;
        }
        // `name: ?lua_Writer`, a field of a C callback type.
        if (t.tag == .identifier and i + 2 < end and toks[i + 1].tag == .colon) {
            var j = i + 2;
            while (j < end and toks[j].tag == .question_mark) j += 1;
            if (j < end and toks[j].tag == .identifier) {
                for (callback_types) |ct| if (std.mem.eql(u8, toks[j].text, ct)) try callback_fields.put(a, t.text, {});
            }
        }
        i += 1;
    }
}

/// Registers the function declared at token `i` (`fn`) and the ones
/// nested in its body; returns the token after it.
const Fields = std.StringHashMapUnmanaged(void);

fn declare(a: std.mem.Allocator, r: *Report, fi: usize, i: usize, member: bool, callback_fields: *Fields) !usize {
    const toks = r.files[fi].toks;
    var k = matching(toks, i + 2) + 1;
    // The body's brace, past the return type's: `error{...}`,
    // `struct {...}`, and parenthesized parts.
    while (k < toks.len) : (k += 1) {
        switch (toks[k].tag) {
            .semicolon => {
                // An extern function: libc's, which raises nothing, or
                // the C API by its C name (`liolib.zig`), which may: left
                // out, a call to it counts as C code.
                const name = toks[i + 1].text;
                if (!std.mem.startsWith(u8, name, "lua"))
                    try r.funcs.append(a, .{ .file = fi, .name = name, .member = member, .start = k, .end = k });
                return k + 1;
            },
            .l_paren => k = matching(toks, k),
            .l_brace => switch (toks[k - 1].tag) {
                .keyword_error,
                .keyword_struct,
                .keyword_union,
                .keyword_enum,
                .keyword_opaque,
                => k = matching(toks, k),
                else => break,
            },
            else => {},
        }
    }
    const end = matching(toks, k);
    try r.funcs.append(a, .{ .file = fi, .name = toks[i + 1].text, .member = member, .start = k + 1, .end = end });
    // Functions nested in the body, inside a returned struct.
    var j = k + 1;
    while (j < end) : (j += 1) {
        if (toks[j].tag == .keyword_fn and toks[j + 1].tag == .identifier and toks[j + 2].tag == .l_paren) {
            j = try declare(a, r, fi, j, true, callback_fields) - 1;
        }
    }
    return end + 1;
}

/// What the call whose name is token `i` reaches.
fn resolve(r: *const Report, fi: usize, i: usize, callback_fields: *const std.StringHashMapUnmanaged(void)) ?Target {
    const file = &r.files[fi];
    const toks = file.toks;
    const name = toks[i].text;
    if (i > 0 and toks[i - 1].tag == .keyword_fn) return null;
    if (i > 0 and toks[i - 1].tag == .period) {
        if (i < 2) return null;
        const root = toks[i - 2];
        // `.name(...)`, a declaration literal, calls nothing of ours.
        switch (root.tag) {
            .identifier, .r_paren, .r_bracket, .period_asterisk, .question_mark => {},
            else => return null,
        }
        if (root.tag == .identifier) if (file.imports.get(root.text)) |target| {
            return if (find(r, target, name, false)) |f| .{ .func = f } else .none;
        };
        // Outside the C API only calls through an import of it count.
        if (!file.capi) return null;
        for (r.funcs.items, 0..) |f, fidx| if (f.member and std.mem.eql(u8, f.name, name)) return .{ .func = fidx };
        if (callback_fields.contains(name)) return .callback;
        return .none;
    }
    if (!file.capi) return null;
    if (find(r, fi, name, false)) |f| return .{ .func = f };
    // A sibling in the same struct (`Box.grow` calling `data`).
    if (find(r, fi, name, true)) |f| return .{ .func = f };
    if (file.aliases.get(name)) |al| return if (find(r, al[0], al[1], false)) |f| .{ .func = f } else .none;
    // A function-typed value: C code, or a Zig function pointer, called
    // directly.
    return .callback;
}

fn find(r: *const Report, fi: usize, name: []const u8, member: bool) ?usize {
    for (r.funcs.items, 0..) |f, i| {
        if (f.file == fi and f.member == member and std.mem.eql(u8, f.name, name)) return i;
    }
    return null;
}

/// The calls between tokens `start` and `end`, outside nested functions.
fn collectCalls(
    a: std.mem.Allocator,
    r: *const Report,
    fi: usize,
    start: usize,
    end: usize,
    callback_fields: *const std.StringHashMapUnmanaged(void),
    out: *std.ArrayList(Call),
) !void {
    const toks = r.files[fi].toks;
    var i = start;
    while (i < end) : (i += 1) {
        const is_fn = toks[i].tag == .keyword_fn and i + 2 < end and
            toks[i + 1].tag == .identifier and toks[i + 2].tag == .l_paren;
        if (r.files[fi].capi and is_fn) {
            i = skipFn(toks, i);
            continue;
        }
        if (toks[i].tag != .identifier or i + 1 >= end or toks[i + 1].tag != .l_paren) continue;
        if (isProtect(toks, i)) {
            // `protect(th, f, ...)` passes `f`; the call it makes is caught.
            i = matching(toks, i + 1);
            continue;
        }
        const t = resolve(r, fi, i, callback_fields) orelse continue;
        try out.append(a, .{ .tok = i, .target = t });
    }
}

fn isProtect(toks: []const Tok, i: usize) bool {
    return std.mem.eql(u8, toks[i].text, "protect") and (i == 0 or toks[i - 1].tag != .period);
}

/// The token after the function declared at `i`.
fn skipFn(toks: []const Tok, i: usize) usize {
    var k = matching(toks, i + 2) + 1;
    while (k < toks.len) : (k += 1) {
        switch (toks[k].tag) {
            .semicolon => return k,
            .l_paren => k = matching(toks, k),
            .l_brace => switch (toks[k - 1].tag) {
                .keyword_error,
                .keyword_struct,
                .keyword_union,
                .keyword_enum,
                .keyword_opaque,
                => k = matching(toks, k),
                else => return matching(toks, k),
            },
            else => {},
        }
    }
    return k;
}

fn checkDefers(a: std.mem.Allocator, r: *Report, f: Func, callback_fields: *const Fields) !void {
    const file = &r.files[f.file];
    const toks = file.toks;
    var pending: std.ArrayList(struct { depth: usize, line: u32 }) = .empty;
    var depth: usize = 0;
    var i = f.start;
    while (i < f.end) : (i += 1) {
        const t = toks[i];
        switch (t.tag) {
            .keyword_fn => if (i + 2 < f.end and toks[i + 1].tag == .identifier and toks[i + 2].tag == .l_paren) {
                i = skipFn(toks, i);
                continue;
            },
            .keyword_defer, .keyword_errdefer => {
                // The deferred statement: a block, or up to its semicolon.
                var e = i + 1;
                if (toks[e].tag == .pipe) e = matchingPipe(toks, e) + 1;
                if (toks[e].tag == .l_brace) {
                    e = matching(toks, e);
                } else {
                    while (e < f.end and toks[e].tag != .semicolon) : (e += 1) {
                        const open = toks[e].tag == .l_paren or toks[e].tag == .l_brace or toks[e].tag == .l_bracket;
                        if (open) e = matching(toks, e);
                    }
                }
                var inside: std.ArrayList(Call) = .empty;
                try collectCalls(a, r, f.file, i + 1, e, callback_fields, &inside);
                for (inside.items) |c| if (throws(r, c.target)) try r.violations.append(a, try std.fmt.allocPrint(
                    a,
                    "{s}:{d}: {s}: the {s} at this line calls {s}, which may throw",
                    .{ file.path, t.line, f.name, t.text, toks[c.tok].text },
                ));
                try pending.append(a, .{ .depth = depth, .line = t.line });
                i = e;
                continue;
            },
            .l_brace => depth += 1,
            .r_brace => {
                while (pending.items.len > 0 and pending.items[pending.items.len - 1].depth == depth) _ = pending.pop();
                depth -|= 1;
            },
            .identifier => if (pending.items.len > 0 and i + 1 < f.end and toks[i + 1].tag == .l_paren) {
                if (isProtect(toks, i)) {
                    i = matching(toks, i + 1);
                    continue;
                }
                const target = resolve(r, f.file, i, callback_fields) orelse continue;
                if (throws(r, target)) try r.violations.append(a, try std.fmt.allocPrint(
                    a,
                    "{s}:{d}: {s} calls {s}, which may throw, while the defer at line {d} is pending",
                    .{ file.path, t.line, f.name, t.text, pending.items[pending.items.len - 1].line },
                ));
            },
            else => {},
        }
    }
}

fn matchingPipe(toks: []const Tok, i: usize) usize {
    var j = i + 1;
    while (j < toks.len and toks[j].tag != .pipe) j += 1;
    return j;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Every Zig file of `src/`, read from the repository root.
fn readTree(a: std.mem.Allocator) ![]Source {
    var list: std.ArrayList(Source) = .empty;
    for ([_][]const u8{ "src", "src/lib", "src/capi" }) |dir_path| {
        var dir = try std.Io.Dir.cwd().openDir(testing.io, dir_path, .{ .iterate = true });
        defer dir.close(testing.io);
        var it = dir.iterate();
        while (try it.next(testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const path = try std.Io.Dir.path.join(a, &.{ dir_path, entry.name });
            const text = try std.Io.Dir.cwd().readFileAllocOptions(testing.io, path, a, .limited(1 << 22), .of(u8), 0);
            try list.append(a, .{ .path = path, .text = text });
        }
    }
    return list.items;
}

test "no Zig frame with a pending defer lies between a protected call and a jump" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var r = try analyze(testing.allocator, try readTree(arena.allocator()));
    defer r.deinit();
    for (r.violations.items) |v| std.debug.print("{s}\n", .{v});
    try testing.expectEqual(@as(usize, 0), r.violations.items.len);
    // Not vacuous: the analysis sees what throws and what does not.
    const throwing = [_][2][]const u8{
        .{ "src/capi/capi.zig", "check" },                 .{ "src/capi/capi.zig", "luaCallk" },
        .{ "src/capi/capi.zig", "luaSettop" },             .{ "src/capi/capi.zig", "readShim" },
        .{ "src/capi/lauxlib.zig", "lauxError" },          .{ "src/capi/lauxlib.zig", "argError" },
        .{ "src/capi/state.zig", "lauxOpenselectedlibs" }, .{ "src/capi/liolib.zig", "readAll" },
    };
    for (throwing) |t| try testing.expectEqual(@as(?bool, true), r.mayThrow(t[0], t[1]));
    const quiet = [_][2][]const u8{
        .{ "src/capi/capi.zig", "lightCFunction" }, .{ "src/capi/capi.zig", "luaGettop" },
        .{ "src/capi/capi.zig", "luaLoad" },        .{ "src/capi/capi.zig", "trampoline" },
        .{ "src/capi/capi.zig", "deinitThread" },   .{ "src/capi/capi.zig", "cWarn" },
        .{ "src/capi/loadlib.zig", "lookForFunc" }, .{ "src/capi/loadlib.zig", "loadFunc" },
        .{ "src/capi/capi.zig", "activeLines" },    .{ "src/capi/lauxlib.zig", "lauxLoadbufferx" },
    };
    for (quiet) |t| try testing.expectEqual(@as(?bool, false), r.mayThrow(t[0], t[1]));
}

const seeded_capi =
    \\pub fn throw(th: *Thread, e: Error) noreturn { jmp.jump(e); }
    \\pub inline fn check(th: *Thread, r: anytype) @typeInfo(@TypeOf(r)).error_union.payload {
    \\    return r catch |e| throw(th, e);
    \\}
    \\fn helper(th: *Thread) error{OutOfMemory}!u32 {
    \\    var b = Buffer.init();
    \\    defer b.deinit();
    \\    return b.len;
    \\}
    \\pub fn luaGood(L: *lua_State) callconv(.c) c_int {
    \\    const n = check(L, helper(L));
    \\    {
    \\        var tmp = alloc();
    \\        defer tmp.free();
    \\        tmp.use();
    \\    }
    \\    return check(L, L.grow(n));
    \\}
    \\pub fn luaPushthing(L: *lua_State) callconv(.c) void {
    \\    _ = check(L, L.grow(1));
    \\}
    \\pub fn quiet(L: *lua_State) void {
    \\    L.top = 0;
    \\}
    \\const Sink = struct {
    \\    f: lua_Writer,
    \\    fn send(s: *Sink, L: *lua_State) c_int {
    \\        return s.f(L, null, 0, null);
    \\    }
    \\};
    \\fn shim(L: *lua_State, f: lua_Reader) c_int {
    \\    return protect(L, f, 0, 0) + 1;
    \\}
;

const seeded_bad =
    \\const capi = @import("capi.zig");
    \\const throw = capi.throw;
    \\fn badDefer(L: *lua_State) callconv(.c) c_int {
    \\    var aw = Allocating.init(gpa);
    \\    defer aw.deinit();
    \\    return capi.check(L, aw.toString());
    \\}
    \\fn badErrdefer(L: *lua_State, reader: lua_Reader) callconv(.c) void {
    \\    const p = try gpa.alloc(u8, 10);
    \\    errdefer gpa.free(p);
    \\    _ = reader(L, null, null);
    \\}
    \\fn badNested(L: *lua_State, s: *Sink) callconv(.c) void {
    \\    var x = alloc();
    \\    defer x.free();
    \\    if (x.ok) {
    \\        _ = s.send(L);
    \\    }
    \\}
    \\fn badInside(L: *lua_State) callconv(.c) void {
    \\    defer throw(L, error.LuaError);
    \\}
    \\fn badAlias(L: *lua_State) callconv(.c) void {
    \\    errdefer |e| std.log.err("{}", .{e});
    \\    throw(L, error.LuaError);
    \\}
    \\extern fn lua_pushstring(L: *lua_State, s: [*:0]const u8) ?[*:0]const u8;
    \\fn badExtern(L: *lua_State) callconv(.c) void {
    \\    var x = alloc();
    \\    defer x.free();
    \\    _ = lua_pushstring(L, "x");
    \\}
;

const seeded_lib =
    \\const capi = @import("../capi/capi.zig");
    \\fn native(th: *Thread, base: u32) Error!u32 {
    \\    capi.quiet(th);
    \\    capi.luaPushthing(th);
    \\    return 1;
    \\}
;

test "the check finds each kind of violation" {
    var r = try analyze(testing.allocator, &.{
        .{ .path = "src/capi/capi.zig", .text = seeded_capi },
        .{ .path = "src/capi/bad.zig", .text = seeded_bad },
        .{ .path = "src/lib/native.zig", .text = seeded_lib },
    });
    defer r.deinit();
    const expected = [_][]const u8{
        "src/capi/bad.zig:6: badDefer calls check, which may throw, while the defer at line 5 is pending",
        "src/capi/bad.zig:11: badErrdefer calls reader, which may throw, while the defer at line 10 is pending",
        "src/capi/bad.zig:17: badNested calls send, which may throw, while the defer at line 15 is pending",
        "src/capi/bad.zig:21: badInside: the defer at this line calls throw, which may throw",
        "src/capi/bad.zig:25: badAlias calls throw, which may throw, while the defer at line 24 is pending",
        "src/capi/bad.zig:31: badExtern calls lua_pushstring, which may throw, while the defer at line 30 is pending",
        "src/lib/native.zig:4: Zig code outside src/capi calls luaPushthing, which may throw",
    };
    try testing.expectEqual(expected.len, r.violations.items.len);
    for (expected, r.violations.items) |e, v| try testing.expectEqualStrings(e, v);
    // A defer in a callee that returns, or in a block closed before the
    // throwing call, is fine; a protected call is not a call.
    try testing.expectEqual(@as(?bool, false), r.mayThrow("src/capi/capi.zig", "helper"));
    try testing.expectEqual(@as(?bool, true), r.mayThrow("src/capi/capi.zig", "luaGood"));
    try testing.expectEqual(@as(?bool, false), r.mayThrow("src/capi/capi.zig", "shim"));
    try testing.expectEqual(@as(?bool, true), r.mayThrow("src/capi/capi.zig", "send"));
}
