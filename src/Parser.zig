//! The parser: Lua 5.5 source to a `Proto` in one pass, after reference Lua
//! 5.5.1's lparser.c. There is no syntax tree; each rule calls the code
//! generator (`Code.zig`) as it recognizes its parts, so registers,
//! constants, and jumps are decided on the fly, exactly as PUC-Rio decides
//! them. `luac -l -l` on the same source is the specification for the
//! output; `just bytecode` compares the two over the suite and benchmarks.
//!
//! Syntax errors carry the reference's messages, "chunk:line: msg near
//! 'tok'", and reach Lua as an error string on the thread (`compile`).
//!
//! `global` is a name to the lexer (`Lexer.global_is_reserved`), and a
//! statement starting with it is a declaration only when the next token is
//! a name, `<`, `*`, or `function`, as lparser.c does under
//! `LUA_COMPAT_GLOBAL`.

const Parser = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("Value.zig");
const String = @import("String.zig");
const Proto = @import("Proto.zig");
const State = @import("State.zig");
const Thread = @import("Thread.zig");
const Lexer = @import("Lexer.zig");
const opcodes = @import("opcodes.zig");
const Code = @import("Code.zig");

const Kind = Lexer.Kind;
const FuncState = Code.FuncState;
const ExpDesc = Code.ExpDesc;
const BlockCnt = Code.BlockCnt;
const VarKind = Code.VarKind;
const BinOpr = Code.BinOpr;
const UnOpr = Code.UnOpr;
const no_jump = Code.no_jump;
const multret = Code.multret;

pub const Error = error{ SyntaxError, OutOfMemory };

/// Variable declarations per function, `MAXVARS`.
const max_vars = 200;
/// Upvalues per function, `MAXUPVAL`.
const max_upvalues = 255;
/// Items in a table constructor, `MAX_CNST`.
const max_constructor_items = std.math.maxInt(i32) / 2;
/// Nesting depth of rules (counted with native calls), `LUAI_MAXCCALLS`.
const max_levels = Thread.max_native_calls;

th: *Thread,
state: *State,
gpa: Allocator,
lx: Lexer,
/// The current token.
t: Token = undefined,
/// The lookahead token, if one was read.
ahead: ?Token = null,
/// The line of the last token consumed (`lastline`); instructions get it.
lastline: u32 = 1,
/// The function being compiled.
fs: ?*FuncState = null,
/// Active variable declarations of every function being compiled
/// (lparser.h's `Dyndata`), pending gotos, and active labels.
actvar: std.ArrayList(Vardesc) = .empty,
gt: std.ArrayList(Labeldesc) = .empty,
label: std.ArrayList(Labeldesc) = .empty,
chunkname: []const u8,
source: *String = undefined,
/// "_ENV", "break", and "global".
envn: *String = undefined,
brkn: *String = undefined,
glbn: *String = undefined,
/// Long strings by contents, so every equal name or literal in a chunk is
/// one object and names compare by identity, as with the scanner table
/// of llex.c.
long_strings: std.StringHashMapUnmanaged(*String) = .empty,
/// The error message after `error.SyntaxError`.
msg: std.ArrayList(u8) = .empty,
/// Rule nesting depth.
level: u32,

const Token = struct {
    kind: Kind,
    raw: Lexer.Token,
    /// The name or string, for `.name` and `.string`.
    ts: *String = undefined,
};

/// An active variable declaration; lparser.h's `Vardesc`.
pub const Vardesc = struct {
    /// The value of a compile-time constant.
    k: Value = .nil,
    kind: u8,
    /// The register holding the variable.
    ridx: u8 = 0,
    /// Index of the variable in the prototype's `locvars`.
    pidx: i16 = 0,
    /// Null for a collective `global *` declaration.
    name: ?*String,
};

/// A pending goto or an active label.
const Labeldesc = struct {
    name: *String,
    pc: i32,
    line: u32,
    /// Active variables at that position.
    nactvar: i32,
    /// A goto that escapes upvalues and may need a `CLOSE`.
    close: bool = false,
};

/// Compiles a main chunk. `chunkname` is the chunk's name as `load`
/// receives it ("=stdin", "@file.lua", or the source itself). On a syntax
/// error the message is the error object on `th` and the result is
/// `error.LuaError`.
pub fn compile(th: *Thread, source: [:0]const u8, chunkname: []const u8) Value.Error!*Proto {
    const state = th.state;
    const gpa = state.heap.allocator();
    if (th.native_calls == 0) state.markStack();
    var ls: Parser = .{
        .th = th,
        .state = state,
        .gpa = gpa,
        .lx = .init(gpa, source),
        .chunkname = chunkname,
        .level = th.native_calls,
    };
    defer ls.deinit();
    return ls.mainFunc() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return th.throwRaw(.string(try state.newString(ls.msg.items))),
    };
}

fn deinit(ls: *Parser) void {
    const gpa = ls.gpa;
    ls.lx.deinit();
    ls.actvar.deinit(gpa);
    ls.gt.deinit(gpa);
    ls.label.deinit(gpa);
    ls.long_strings.deinit(gpa);
    ls.msg.deinit(gpa);
    ls.* = undefined;
}

// Strings and errors.

/// A string for a name or literal: short strings are interned by the
/// state, long ones by this parser.
fn newString(ls: *Parser, b: []const u8) Error!*String {
    if (b.len <= String.max_short_len) return ls.state.newString(b);
    const gop = try ls.long_strings.getOrPut(ls.gpa, b);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer _ = ls.long_strings.remove(b);
    const s = try ls.state.newString(b);
    gop.key_ptr.* = s.bytes();
    gop.value_ptr.* = s;
    return s;
}

/// Sets the error message, "chunk:line: msg near 'tok'", and fails.
noinline fn fail(ls: *Parser, line: u32, near: ?Token, comptime fmt: []const u8, args: anytype) Error {
    @branchHint(.cold);
    return ls.failArgs(line, near, fmt, &Thread.FormatArg.list(fmt, args));
}

noinline fn failArgs(ls: *Parser, line: u32, near: ?Token, fmt: []const u8, args: []const Thread.FormatArg) Error {
    @branchHint(.cold);
    var aw: std.Io.Writer.Allocating = .fromArrayList(ls.gpa, &ls.msg);
    defer ls.msg = aw.toArrayList();
    aw.clearRetainingCapacity();
    const w = &aw.writer;
    Thread.writeChunkId(w, ls.chunkname) catch return error.OutOfMemory;
    w.print(":{d}: ", .{line}) catch return error.OutOfMemory;
    Thread.FormatArg.write(w, fmt, args) catch return error.OutOfMemory;
    if (near) |tok| {
        if (@intFromEnum(tok.kind) != 0) {
            w.writeAll(" near ") catch return error.OutOfMemory;
            ls.lx.writeNear(w, tok.raw) catch return error.OutOfMemory;
        }
    }
    return error.SyntaxError;
}

/// A syntax error at the current token, `luaX_syntaxerror`.
pub noinline fn syntaxError(ls: *Parser, msg: []const u8) Error {
    @branchHint(.cold);
    return ls.fail(ls.lx.line, ls.t, "{s}", .{msg});
}

/// A semantic error: no "near" part, at the line of the last token,
/// `luaK_semerror`.
noinline fn semError(ls: *Parser, comptime fmt: []const u8, args: anytype) Error {
    @branchHint(.cold);
    return ls.fail(ls.lastline, null, fmt, args);
}

noinline fn errorExpected(ls: *Parser, kind: Kind) Error {
    @branchHint(.cold);
    var buf: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    Lexer.writeKind(&w, kind) catch unreachable;
    return ls.fail(ls.lx.line, ls.t, "{s} expected", .{w.buffered()});
}

pub noinline fn errorLimit(ls: *Parser, fs: *FuncState, limit: i32, what: []const u8) Error {
    @branchHint(.cold);
    const line = fs.f.linedefined;
    if (line == 0) return ls.fail(ls.lx.line, ls.t, "too many {s} (limit is {d}) in main function", .{ what, limit });
    return ls.fail(ls.lx.line, ls.t, "too many {s} (limit is {d}) in function at line {d}", .{ what, limit, line });
}

fn checkLimit(ls: *Parser, fs: *FuncState, v: i32, l: i32, what: []const u8) Error!void {
    if (v > l) return ls.errorLimit(fs, l, what);
}

fn enterLevel(ls: *Parser) Error!void {
    ls.level += 1;
    if (ls.level >= max_levels or ls.state.nearStackLimit(0)) return ls.levelError();
}

/// "C stack overflow": too many levels of nesting, counted with the
/// native calls under the compiler, or its native stack past the budget
/// (`Thread.max_native_stack`).
noinline fn levelError(ls: *Parser) Error {
    @branchHint(.cold);
    ls.msg.clearRetainingCapacity();
    try ls.msg.appendSlice(ls.gpa, "C stack overflow");
    return error.SyntaxError;
}

fn leaveLevel(ls: *Parser) void {
    ls.level -= 1;
}

// Tokens.

/// Scans the next token into `tok`. It writes in place: a token returned
/// by value through the error union was written field by field and read
/// back whole by the caller, a store forwarding stall on every token.
fn scan(ls: *Parser, tok: *Token) Error!void {
    const raw = ls.lx.next() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return ls.fail(ls.lx.err_line, null, "{s}", .{ls.lx.errorMessage()}),
    };
    tok.kind = raw.kind;
    tok.raw = raw;
    if (raw.kind == .name or raw.kind == .string) {
        tok.ts = try ls.newString(raw.data.string);
        tok.raw.data = .{ .string = tok.ts.bytes() };
    }
}

/// Reads the next token, `luaX_next`.
fn next(ls: *Parser) Error!void {
    ls.lastline = ls.lx.line;
    if (ls.ahead) |a| {
        ls.t = a;
        ls.ahead = null;
    } else {
        try ls.scan(&ls.t);
    }
}

fn lookahead(ls: *Parser) Error!Kind {
    std.debug.assert(ls.ahead == null);
    ls.ahead = @as(Token, undefined);
    try ls.scan(&ls.ahead.?);
    return ls.ahead.?.kind;
}

fn testNext(ls: *Parser, kind: Kind) Error!bool {
    if (ls.t.kind != kind) return false;
    try ls.next();
    return true;
}

fn check(ls: *Parser, kind: Kind) Error!void {
    if (ls.t.kind != kind) return ls.errorExpected(kind);
}

fn checkNext(ls: *Parser, kind: Kind) Error!void {
    try ls.check(kind);
    try ls.next();
}

fn checkCondition(ls: *Parser, c: bool, msg: []const u8) Error!void {
    if (!c) return ls.syntaxError(msg);
}

/// Skips `what`, which must close `who` opened at line `where`.
fn checkMatch(ls: *Parser, what: Kind, who: Kind, where: u32) Error!void {
    if (try ls.testNext(what)) return;
    return ls.matchError(what, who, where);
}

noinline fn matchError(ls: *Parser, what: Kind, who: Kind, where: u32) Error {
    @branchHint(.cold);
    if (where == ls.lx.line) return ls.errorExpected(what);
    var bw: [32]u8 = undefined;
    var w1: std.Io.Writer = .fixed(&bw);
    Lexer.writeKind(&w1, what) catch unreachable;
    var bo: [32]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&bo);
    Lexer.writeKind(&w2, who) catch unreachable;
    const fmt = "{s} expected (to close {s} at line {d})";
    return ls.fail(ls.lx.line, ls.t, fmt, .{ w1.buffered(), w2.buffered(), where });
}

fn strCheckName(ls: *Parser) Error!*String {
    try ls.check(.name);
    const ts = ls.t.ts;
    try ls.next();
    return ts;
}

fn codeString(s: *String) ExpDesc {
    return .{ .k = .kstr, .u = .{ .strval = s } };
}

fn codeName(ls: *Parser) Error!ExpDesc {
    return codeString(try ls.strCheckName());
}

// Variables.

fn registerLocalVar(ls: *Parser, fs: *FuncState, name: ?*String) Error!i16 {
    try fs.locvars.append(ls.gpa, .{ .name = name, .startpc = @intCast(fs.pc()), .endpc = 0 });
    return @intCast(fs.locvars.items.len - 1);
}

/// Declares a variable; returns its index in the function.
fn newVarKind(ls: *Parser, name: ?*String, kind: u8) Error!i32 {
    const fs = ls.fs.?;
    if (ls.actvar.items.len >= std.math.maxInt(i16))
        return ls.errorLimit(fs, std.math.maxInt(i16), "variable declarations");
    try ls.actvar.append(ls.gpa, .{ .kind = kind, .name = name });
    return @as(i32, @intCast(ls.actvar.items.len)) - 1 - @as(i32, @intCast(fs.firstlocal));
}

fn newLocalVar(ls: *Parser, name: *String) Error!i32 {
    return ls.newVarKind(name, VarKind.reg);
}

fn newLocalVarLiteral(ls: *Parser, comptime name: []const u8) Error!i32 {
    return ls.newLocalVar(try ls.newString(name));
}

/// The declaration of variable `vidx`. Like lparser.c, this may read a
/// declaration just dropped from the list (goto resolution asks for the
/// register level of variables whose scope has ended), which the list's
/// capacity still holds.
fn getLocalVarDesc(ls: *Parser, fs: *const FuncState, vidx: i32) *Vardesc {
    const i = fs.firstlocal + @as(u32, @intCast(vidx));
    std.debug.assert(i < ls.actvar.capacity);
    return &ls.actvar.items.ptr[i];
}

/// The register level for variable level `nvar`: one past the highest
/// register variable below it.
fn regLevel(ls: *Parser, fs: *const FuncState, nvar_: i32) i32 {
    var nvar = nvar_;
    while (nvar > 0) {
        nvar -= 1;
        const vd = ls.getLocalVarDesc(fs, nvar);
        if (VarKind.inReg(vd.kind)) return @as(i32, vd.ridx) + 1;
    }
    return 0;
}

/// Registers the function's variables use, `luaY_nvarstack`.
pub fn nvarstack(ls: *Parser, fs: *const FuncState) i32 {
    return ls.regLevel(fs, fs.nactvar);
}

fn localDebugInfo(ls: *Parser, fs: *FuncState, vidx: i32) ?*Proto.LocVar {
    const vd = ls.getLocalVarDesc(fs, vidx);
    if (!VarKind.inReg(vd.kind)) return null;
    return &fs.locvars.items[@intCast(vd.pidx)];
}

fn initVar(ls: *Parser, fs: *const FuncState, vidx: i32) ExpDesc {
    return .{ .k = .local, .vidx = vidx, .ridx = ls.getLocalVarDesc(fs, vidx).ridx };
}

/// Raises an error if `e` is read-only; an assignment to an index of the
/// vararg parameter makes the function use a real vararg table.
fn checkReadonly(ls: *Parser, e: *ExpDesc) Error!void {
    const fs = ls.fs.?;
    var varname: ?*String = null;
    switch (e.k) {
        .@"const" => varname = ls.actvar.items[@intCast(e.info)].name,
        .local, .vargvar => {
            const vd = ls.getLocalVarDesc(fs, e.vidx);
            if (vd.kind != VarKind.reg) varname = vd.name;
        },
        .upval => {
            const up = fs.upvals.items[@intCast(e.info)];
            if (up.kind != VarKind.reg) varname = up.name;
        },
        .vargind, .indexup, .indexstr, .indexed => {
            if (e.k == .vargind) {
                fs.f.flags.vararg_table = true;
                e.k = .indexed;
            }
            if (e.ind.ro) varname = fs.ks.items[@intCast(e.ind.keystr)].asString();
        },
        else => {
            std.debug.assert(e.k == .indexi);
            return;
        },
    }
    if (varname) |n| return ls.semError("attempt to assign to const variable '{s}'", .{n.bytes()});
}

/// Starts the scope of the last `nvars` declared variables.
fn adjustLocalVars(ls: *Parser, nvars: i32) Error!void {
    const fs = ls.fs.?;
    var reglevel = ls.nvarstack(fs);
    for (0..@intCast(nvars)) |_| {
        const vidx = fs.nactvar;
        fs.nactvar += 1;
        const name = ls.getLocalVarDesc(fs, vidx).name;
        const pidx = try ls.registerLocalVar(fs, name);
        const v = ls.getLocalVarDesc(fs, vidx);
        v.ridx = @intCast(reglevel);
        v.pidx = pidx;
        reglevel += 1;
        try ls.checkLimit(fs, reglevel, max_vars, "local variables");
    }
}

/// Ends the scope of variables down to level `tolevel`.
fn removeVars(ls: *Parser, fs: *FuncState, tolevel: i32) void {
    ls.actvar.items.len -= @intCast(fs.nactvar - tolevel);
    while (fs.nactvar > tolevel) {
        fs.nactvar -= 1;
        if (ls.localDebugInfo(fs, fs.nactvar)) |v| v.endpc = @intCast(fs.pc());
    }
}

fn searchUpvalue(fs: *FuncState, name: *String) i32 {
    for (fs.upvals.items, 0..) |u, i| if (u.name == name) return @intCast(i);
    return -1;
}

fn allocUpvalue(ls: *Parser, fs: *FuncState) Error!*Proto.UpvalDesc {
    try ls.checkLimit(fs, @as(i32, @intCast(fs.upvals.items.len)) + 1, max_upvalues, "upvalues");
    try fs.upvals.append(ls.gpa, .{ .instack = false, .idx = 0 });
    return &fs.upvals.items[fs.upvals.items.len - 1];
}

fn newUpvalue(ls: *Parser, fs: *FuncState, name: *String, v: *const ExpDesc) Error!i32 {
    const up = try ls.allocUpvalue(fs);
    const prev = fs.prev.?;
    if (v.k == .local) {
        up.instack = true;
        up.idx = v.ridx;
        up.kind = ls.getLocalVarDesc(prev, v.vidx).kind;
    } else {
        up.instack = false;
        up.idx = @intCast(v.info);
        up.kind = prev.upvals.items[@intCast(v.info)].kind;
    }
    up.name = name;
    return @as(i32, @intCast(fs.upvals.items.len)) - 1;
}

/// Looks for an active variable `n` in `fs`. While searching, `var.info`
/// tracks global declarations: -1 while the default "every name is
/// global" holds, -2 once some named global declaration is in scope but
/// no collective one, and otherwise the index of the innermost collective
/// (`global *`) declaration. Returns the variable's kind, or null.
fn searchVar(ls: *Parser, fs: *FuncState, n: *String, v: *ExpDesc) ?Code.ExpKind {
    var i = fs.nactvar - 1;
    while (i >= 0) : (i -= 1) {
        const vd = ls.getLocalVarDesc(fs, i);
        if (VarKind.isGlobal(vd.kind)) {
            if (vd.name) |name| {
                if (name == n) {
                    v.* = .init(.global, @as(i32, @intCast(fs.firstlocal)) + i);
                    return .global;
                } else if (v.info == -1) {
                    v.info = -2;
                }
            } else if (v.info < 0) {
                v.info = @as(i32, @intCast(fs.firstlocal)) + i;
            }
        } else if (vd.name == n) {
            if (vd.kind == VarKind.ctc) {
                v.* = .init(.@"const", @as(i32, @intCast(fs.firstlocal)) + i);
            } else {
                v.* = ls.initVar(fs, i);
                if (vd.kind == VarKind.vararg_param) v.k = .vargvar;
            }
            return v.k;
        }
    }
    return null;
}

/// Marks the block where the variable at `level` lives as having an
/// upvalue, so it closes on exit.
fn markUpval(fs: *FuncState, level: i32) void {
    var bl = fs.bl.?;
    while (bl.nactvar > level) bl = bl.previous.?;
    bl.upval = true;
    fs.needclose = true;
}

fn markToBeClosed(fs: *FuncState) void {
    const bl = fs.bl.?;
    bl.upval = true;
    bl.insidetbc = true;
    fs.needclose = true;
}

/// Finds variable `n`, adding upvalues through enclosing functions; a
/// global leaves `v` as `.global`.
fn singleVarAux(ls: *Parser, fs: *FuncState, n: *String, v: *ExpDesc, base: bool) Error!void {
    if (ls.searchVar(fs, n, v) != null) {
        if (!base) {
            if (v.k == .vargvar) fs.vapar2local(v);
            if (v.k == .local) markUpval(fs, v.vidx);
        }
        return;
    }
    var idx = searchUpvalue(fs, n);
    if (idx < 0) {
        if (fs.prev) |prev| try ls.singleVarAux(prev, n, v, false);
        if (v.k == .local or v.k == .upval) {
            idx = try ls.newUpvalue(fs, n, v);
        } else {
            return;
        }
    }
    v.* = .init(.upval, idx);
}

/// `_ENV[varname]`.
fn buildGlobal(ls: *Parser, varname: *String, v: *ExpDesc) Error!void {
    const fs = ls.fs.?;
    v.* = .init(.global, -1);
    try ls.singleVarAux(fs, ls.envn, v, true);
    if (v.k == .global)
        return ls.semError("_ENV is global when accessing variable '{s}'", .{varname.bytes()});
    try fs.exp2anyregup(v);
    var key = codeString(varname);
    try fs.indexed(v, &key);
}

fn buildVar(ls: *Parser, varname: *String, v: *ExpDesc) Error!void {
    const fs = ls.fs.?;
    v.* = .init(.global, -1);
    try ls.singleVarAux(fs, varname, v, true);
    if (v.k == .global) {
        const info = v.info;
        if (info == -2) return ls.semError("variable '{s}' not declared", .{varname.bytes()});
        try ls.buildGlobal(varname, v);
        if (info != -1 and ls.actvar.items[@intCast(info)].kind == VarKind.global_const) v.ind.ro = true;
    }
}

fn singleVar(ls: *Parser, v: *ExpDesc) Error!void {
    try ls.buildVar(try ls.strCheckName(), v);
}

/// Adjusts `nexps` values (the last one `e`) to `nvars`.
fn adjustAssign(ls: *Parser, nvars: i32, nexps: i32, e: *ExpDesc) Error!void {
    const fs = ls.fs.?;
    const needed = nvars - nexps;
    try fs.checkStack(needed);
    if (e.k.hasMultRet()) {
        try fs.setReturns(e, @max(needed + 1, 0));
    } else {
        if (e.k != .void) try fs.exp2nextreg(e);
        if (needed > 0) try fs.nil(fs.freereg, needed);
    }
    if (needed > 0) {
        try fs.reserveRegs(needed);
    } else {
        fs.freereg += needed;
    }
}

// Gotos and labels.

fn jumpScopeError(ls: *Parser, gt: *const Labeldesc) Error {
    const vname = ls.getLocalVarDesc(ls.fs.?, gt.nactvar).name;
    const varname = if (vname) |n| n.bytes() else "*";
    return ls.semError("<goto {s}> at line {d} jumps into the scope of '{s}'", .{ gt.name.bytes(), gt.line, varname });
}

/// Resolves pending goto `g` to `lbl` and drops it from the list. It
/// needs a `CLOSE` when it escapes upvalues, or leaves the scope of some
/// variable of a block with upvalues (`bup`).
fn closeGoto(ls: *Parser, g: usize, lbl: *const Labeldesc, bup: bool) Error!void {
    const fs = ls.fs.?;
    const gt = &ls.gt.items[g];
    if (gt.nactvar < lbl.nactvar) return ls.jumpScopeError(gt);
    if (gt.close or (lbl.nactvar < gt.nactvar and bup)) {
        const stklevel = ls.regLevel(fs, lbl.nactvar);
        // Swap the jump and its CLOSE placeholder.
        fs.inst(gt.pc + 1).* = fs.inst(gt.pc).*;
        fs.inst(gt.pc).* = opcodes.abc(.close, @intCast(stklevel), 0, 0, false);
        gt.pc += 1;
    }
    try fs.patchList(gt.pc, lbl.pc);
    _ = ls.gt.orderedRemove(g);
}

fn findLabel(ls: *Parser, name: *String, ilb: u32) ?*Labeldesc {
    for (ls.label.items[ilb..]) |*lb| if (lb.name == name) return lb;
    return null;
}

fn newLabelEntry(ls: *Parser, l: *std.ArrayList(Labeldesc), name: *String, line: u32, at: i32) Error!usize {
    try l.append(ls.gpa, .{ .name = name, .line = line, .nactvar = ls.fs.?.nactvar, .pc = at });
    return l.items.len - 1;
}

/// A jump followed by a dead `CLOSE` placeholder; if the goto turns out to
/// need the close, the two swap.
fn newGotoEntry(ls: *Parser, name: *String, line: u32) Error!void {
    const fs = ls.fs.?;
    const at = try fs.jump();
    _ = try fs.codeAbc(.close, 0, 1, 0);
    _ = try ls.newLabelEntry(&ls.gt, name, line, at);
}

/// A label at the current position. When it is the last statement of its
/// block, the block's variables are already out of scope.
fn createLabel(ls: *Parser, name: *String, line: u32, last: bool) Error!void {
    const fs = ls.fs.?;
    const l = try ls.newLabelEntry(&ls.label, name, line, fs.getLabel());
    if (last) ls.label.items[l].nactvar = fs.bl.?.nactvar;
}

/// Matches the finishing block's pending gotos to its labels; the others
/// move out to the enclosing block.
fn solveGotos(ls: *Parser, fs: *FuncState, bl: *BlockCnt) Error!void {
    const outlevel = ls.regLevel(fs, bl.nactvar);
    var igt: usize = bl.firstgoto;
    while (igt < ls.gt.items.len) {
        const gt = &ls.gt.items[igt];
        if (ls.findLabel(gt.name, bl.firstlabel)) |lb| {
            try ls.closeGoto(igt, lb, bl.upval);
        } else {
            if (bl.upval and ls.regLevel(fs, gt.nactvar) > outlevel) gt.close = true;
            gt.nactvar = bl.nactvar;
            igt += 1;
        }
    }
    ls.label.items.len = bl.firstlabel;
}

fn enterBlock(ls: *Parser, fs: *FuncState, bl: *BlockCnt, isloop: u8) void {
    bl.* = .{
        .isloop = isloop,
        .nactvar = fs.nactvar,
        .firstlabel = @intCast(ls.label.items.len),
        .firstgoto = @intCast(ls.gt.items.len),
        .insidetbc = if (fs.bl) |prev| prev.insidetbc else false,
        .previous = fs.bl,
    };
    fs.bl = bl;
    std.debug.assert(fs.freereg == ls.nvarstack(fs));
}

fn undefGoto(ls: *Parser, gt: *const Labeldesc) Error {
    return ls.semError("no visible label '{s}' for <goto> at line {d}", .{ gt.name.bytes(), gt.line });
}

fn leaveBlock(ls: *Parser, fs: *FuncState) Error!void {
    const bl = fs.bl.?;
    const stklevel = ls.regLevel(fs, bl.nactvar);
    if (bl.previous != null and bl.upval) _ = try fs.codeAbc(.close, stklevel, 0, 0);
    fs.freereg = stklevel;
    ls.removeVars(fs, bl.nactvar);
    std.debug.assert(bl.nactvar == fs.nactvar);
    if (bl.isloop == 2) try ls.createLabel(ls.brkn, 0, false);
    try ls.solveGotos(fs, bl);
    if (bl.previous == null) {
        if (bl.firstgoto < ls.gt.items.len) return ls.undefGoto(&ls.gt.items[bl.firstgoto]);
    }
    fs.bl = bl.previous;
}

// Functions.

fn addPrototype(ls: *Parser) Error!*Proto {
    const fs = ls.fs.?;
    if (fs.protos.items.len >= opcodes.max_bx) return ls.errorLimit(fs, opcodes.max_bx, "functions");
    const p = try Proto.create(&ls.state.heap);
    try fs.protos.append(ls.gpa, p);
    return p;
}

/// `CLOSURE` in the enclosing function, into its next register.
fn codeClosure(ls: *Parser, v: *ExpDesc) Error!void {
    const fs = ls.fs.?.prev.?;
    v.* = .init(.reloc, try fs.codeABx(.closure, 0, @as(i32, @intCast(fs.protos.items.len)) - 1));
    try fs.exp2nextreg(v);
}

fn openFunc(ls: *Parser, fs: *FuncState, bl: *BlockCnt) void {
    fs.prev = ls.fs;
    ls.fs = fs;
    fs.firstlocal = @intCast(ls.actvar.items.len);
    fs.firstlabel = @intCast(ls.label.items.len);
    fs.f.source = ls.source;
    fs.f.maxstacksize = 2;
    fs.previousline = @intCast(fs.f.linedefined);
    ls.enterBlock(fs, bl, 0);
}

/// Finishes the current function and moves its parts into its prototype.
fn closeFunc(ls: *Parser) Error!void {
    const fs = ls.fs.?;
    const f = fs.f;
    const gpa = ls.gpa;
    try fs.ret(ls.nvarstack(fs), 0);
    try ls.leaveBlock(fs);
    std.debug.assert(fs.bl == null);
    try fs.finish();
    f.code = try fs.insts.toOwnedSlice(gpa);
    f.lineinfo = try fs.lineinfo.toOwnedSlice(gpa);
    f.abslineinfo = try fs.abslineinfo.toOwnedSlice(gpa);
    f.k = try fs.ks.toOwnedSlice(gpa);
    try f.initSlots(gpa);
    f.p = try fs.protos.toOwnedSlice(gpa);
    f.locvars = try fs.locvars.toOwnedSlice(gpa);
    f.upvalues = try fs.upvals.toOwnedSlice(gpa);
    ls.fs = fs.prev;
    fs.deinit();
}

// Grammar.

/// Whether the current token ends a block. `until` ends a block's syntax
/// but not its scope, so the caller says whether it counts.
fn blockFollow(ls: *Parser, withuntil: bool) bool {
    return switch (ls.t.kind) {
        .@"else", .elseif, .end, .eos => true,
        .until => withuntil,
        else => false,
    };
}

fn statList(ls: *Parser) Error!void {
    while (!ls.blockFollow(true)) {
        if (ls.t.kind == .@"return") {
            try ls.statement();
            return;
        }
        try ls.statement();
    }
}

fn fieldSel(ls: *Parser, v: *ExpDesc) Error!void {
    const fs = ls.fs.?;
    try fs.exp2anyregup(v);
    try ls.next();
    var key = try ls.codeName();
    try fs.indexed(v, &key);
}

fn yIndex(ls: *Parser, v: *ExpDesc) Error!void {
    try ls.next();
    try ls.expr(v);
    try ls.fs.?.exp2val(v);
    try ls.checkNext(.rbracket);
}

const ConsControl = struct {
    /// The last list item read.
    v: ExpDesc = .{},
    /// The table.
    t: *ExpDesc,
    /// Record fields.
    nh: i32 = 0,
    /// List items already stored.
    na: i32 = 0,
    /// List items waiting to be stored.
    tostore: i32 = 0,
    maxtostore: i32,
};

/// Out of line, so its three expressions are not in `constructor`'s frame
/// on every level of nested list constructors.
noinline fn recField(ls: *Parser, cc: *ConsControl) Error!void {
    const fs = ls.fs.?;
    const reg = fs.freereg;
    var key: ExpDesc = undefined;
    if (ls.t.kind == .name) {
        key = try ls.codeName();
    } else {
        try ls.yIndex(&key);
    }
    cc.nh += 1;
    try ls.checkNext(.assign);
    var tab = cc.t.*;
    try fs.indexed(&tab, &key);
    var val: ExpDesc = undefined;
    try ls.expr(&val);
    try fs.storeVar(&tab, &val);
    fs.freereg = reg;
}

fn closeListField(fs: *FuncState, cc: *ConsControl) Error!void {
    std.debug.assert(cc.tostore > 0);
    try fs.exp2nextreg(&cc.v);
    cc.v.k = .void;
    if (cc.tostore >= cc.maxtostore) {
        try fs.setList(cc.t.info, cc.na, cc.tostore);
        cc.na += cc.tostore;
        cc.tostore = 0;
    }
}

fn lastListField(fs: *FuncState, cc: *ConsControl) Error!void {
    if (cc.tostore == 0) return;
    if (cc.v.k.hasMultRet()) {
        try fs.setMultRet(&cc.v);
        try fs.setList(cc.t.info, cc.na, multret);
        cc.na -= 1;
    } else {
        if (cc.v.k != .void) try fs.exp2nextreg(&cc.v);
        try fs.setList(cc.t.info, cc.na, cc.tostore);
    }
    cc.na += cc.tostore;
}

fn listField(ls: *Parser, cc: *ConsControl) Error!void {
    try ls.expr(&cc.v);
    cc.tostore += 1;
}

fn field(ls: *Parser, cc: *ConsControl) Error!void {
    switch (ls.t.kind) {
        .name => if (try ls.lookahead() != .assign) try ls.listField(cc) else try ls.recField(cc),
        .lbracket => try ls.recField(cc),
        else => try ls.listField(cc),
    }
}

/// How many list items a constructor keeps in registers before a
/// `SETLIST`, by how many registers are free.
fn maxToStore(fs: *FuncState) i32 {
    const numfreeregs = opcodes.max_registers - fs.freereg;
    if (numfreeregs >= 160) return @divTrunc(numfreeregs, 5);
    if (numfreeregs >= 80) return 10;
    return 1;
}

fn constructor(ls: *Parser, t: *ExpDesc) Error!void {
    const fs = ls.fs.?;
    const line = ls.lx.line;
    const at = try fs.codevAbck(.newtable, 0, 0, 0, false);
    _ = try fs.code(0); // the EXTRAARG
    t.* = .init(.nonreloc, fs.freereg);
    try fs.reserveRegs(1);
    var cc: ConsControl = .{ .t = t, .maxtostore = 0 };
    try ls.checkNext(.lbrace);
    cc.maxtostore = maxToStore(fs);
    while (true) {
        if (ls.t.kind == .rbrace) break;
        if (cc.v.k != .void) try closeListField(fs, &cc);
        try ls.field(&cc);
        try ls.checkLimit(fs, cc.tostore + cc.na + cc.nh, max_constructor_items, "items in a constructor");
        if (!(try ls.testNext(.comma) or try ls.testNext(.semicolon))) break;
    }
    try ls.checkMatch(.rbrace, .lbrace, line);
    try lastListField(fs, &cc);
    fs.setTableSize(at, t.info, cc.na, cc.nh);
}

fn setVararg(fs: *FuncState) Error!void {
    fs.f.flags.vararg = true;
    _ = try fs.codeAbc(.varargprep, 0, 0, 0);
}

fn parList(ls: *Parser) Error!void {
    const fs = ls.fs.?;
    const f = fs.f;
    var nparams: i32 = 0;
    var varargk = false;
    if (ls.t.kind != .rparen) {
        while (true) {
            switch (ls.t.kind) {
                .name => {
                    _ = try ls.newLocalVar(try ls.strCheckName());
                    nparams += 1;
                },
                .dots => {
                    varargk = true;
                    try ls.next();
                    if (ls.t.kind == .name) {
                        _ = try ls.newVarKind(try ls.strCheckName(), VarKind.vararg_param);
                    } else {
                        _ = try ls.newLocalVarLiteral("(vararg table)");
                    }
                },
                else => return ls.syntaxError("<name> or '...' expected"),
            }
            if (varargk or !try ls.testNext(.comma)) break;
        }
    }
    try ls.adjustLocalVars(nparams);
    f.numparams = @intCast(fs.nactvar);
    if (varargk) {
        try setVararg(fs);
        try ls.adjustLocalVars(1);
    }
    try fs.reserveRegs(fs.nactvar);
}

fn body(ls: *Parser, e: *ExpDesc, ismethod: bool, line: u32) Error!void {
    // The function's state, with its seven growing lists, is on the heap:
    // on the stack it was 264 of the 416 bytes every level of nested
    // functions costs (`results/lean-20261031.md`).
    const new_fs = try ls.gpa.create(FuncState);
    defer ls.gpa.destroy(new_fs);
    new_fs.* = .{ .f = try ls.addPrototype(), .ls = ls };
    errdefer new_fs.deinit();
    new_fs.f.linedefined = line;
    var bl: BlockCnt = .{};
    ls.openFunc(new_fs, &bl);
    try ls.checkNext(.lparen);
    if (ismethod) {
        _ = try ls.newLocalVarLiteral("self");
        try ls.adjustLocalVars(1);
    }
    try ls.parList();
    try ls.checkNext(.rparen);
    try ls.statList();
    new_fs.f.lastlinedefined = ls.lx.line;
    try ls.checkMatch(.end, .function, line);
    try ls.codeClosure(e);
    try ls.closeFunc();
}

fn expList(ls: *Parser, v: *ExpDesc) Error!i32 {
    var n: i32 = 1;
    try ls.expr(v);
    while (try ls.testNext(.comma)) {
        try ls.fs.?.exp2nextreg(v);
        try ls.expr(v);
        n += 1;
    }
    return n;
}

fn funcArgs(ls: *Parser, f: *ExpDesc) Error!void {
    const fs = ls.fs.?;
    var args: ExpDesc = .{};
    const line = ls.lx.line;
    switch (ls.t.kind) {
        .lparen => {
            try ls.next();
            if (ls.t.kind == .rparen) {
                args.k = .void;
            } else {
                _ = try ls.expList(&args);
                if (args.k.hasMultRet()) try fs.setMultRet(&args);
            }
            try ls.checkMatch(.rparen, .lparen, line);
        },
        .lbrace => try ls.constructor(&args),
        .string => {
            args = codeString(ls.t.ts);
            try ls.next();
        },
        else => return ls.syntaxError("function arguments expected"),
    }
    std.debug.assert(f.k == .nonreloc);
    const base = f.info;
    var nparams: i32 = undefined;
    if (args.k.hasMultRet()) {
        nparams = multret;
    } else {
        if (args.k != .void) try fs.exp2nextreg(&args);
        nparams = fs.freereg - (base + 1);
    }
    f.* = .init(.call, try fs.codeAbc(.call, base, nparams + 1, 2));
    try fs.fixLine(line);
    fs.freereg = base + 1;
}

fn primaryExp(ls: *Parser, v: *ExpDesc) Error!void {
    switch (ls.t.kind) {
        .lparen => {
            const line = ls.lx.line;
            try ls.next();
            try ls.expr(v);
            try ls.checkMatch(.rparen, .lparen, line);
            try ls.fs.?.dischargeVars(v);
        },
        .name => try ls.singleVar(v),
        else => return ls.syntaxError("unexpected symbol"),
    }
}

fn suffixedExp(ls: *Parser, v: *ExpDesc) Error!void {
    try ls.primaryExp(v);
    try ls.suffixes(v);
}

/// The `{ '.' NAME | '[' exp ']' | ':' NAME funcargs | funcargs }` part of
/// `suffixedexp`, out of line so a parenthesized expression's nesting
/// does not carry its locals.
noinline fn suffixes(ls: *Parser, v: *ExpDesc) Error!void {
    const fs = ls.fs.?;
    while (true) {
        switch (ls.t.kind) {
            .dot => try ls.fieldSel(v),
            .lbracket => {
                var key: ExpDesc = undefined;
                try fs.exp2anyregup(v);
                try ls.yIndex(&key);
                try fs.indexed(v, &key);
            },
            .colon => {
                try ls.next();
                var key = try ls.codeName();
                try fs.self(v, &key);
                try ls.funcArgs(v);
            },
            .lparen, .string, .lbrace => {
                try fs.exp2nextreg(v);
                try ls.funcArgs(v);
            },
            else => return,
        }
    }
}

fn simpleExp(ls: *Parser, v: *ExpDesc) Error!void {
    switch (ls.t.kind) {
        .float => v.* = .{ .k = .kflt, .u = .{ .nval = ls.t.raw.data.float } },
        .int => v.* = .{ .k = .kint, .u = .{ .ival = ls.t.raw.data.int } },
        .string => v.* = codeString(ls.t.ts),
        .nil => v.* = .init(.nil, 0),
        .true => v.* = .init(.true, 0),
        .false => v.* = .init(.false, 0),
        .dots => {
            const fs = ls.fs.?;
            const vararg = fs.f.flags.vararg or fs.f.flags.vararg_table;
            try ls.checkCondition(vararg, "cannot use '...' outside a vararg function");
            v.* = .init(.vararg, try fs.codeAbc(.vararg, 0, fs.f.numparams, 1));
        },
        .lbrace => return ls.constructor(v),
        .function => {
            try ls.next();
            return ls.body(v, false, ls.lx.line);
        },
        else => return ls.suffixedExp(v),
    }
    try ls.next();
}

fn getUnOpr(kind: Kind) UnOpr {
    return switch (kind) {
        .not => .not,
        .minus => .minus,
        .tilde => .bnot,
        .hash => .len,
        else => .none,
    };
}

fn getBinOpr(kind: Kind) BinOpr {
    return switch (kind) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .percent => .mod,
        .caret => .pow,
        .slash => .div,
        .idiv => .idiv,
        .amp => .band,
        .pipe => .bor,
        .tilde => .bxor,
        .shl => .shl,
        .shr => .shr,
        .concat => .concat,
        .ne => .ne,
        .eq => .eq,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .@"and" => .@"and",
        .@"or" => .@"or",
        else => .none,
    };
}

/// Left and right priorities of the binary operators, in `BinOpr` order.
const priority = [_][2]u8{
    .{ 10, 10 }, .{ 10, 10 }, // + -
    .{ 11, 11 }, .{ 11, 11 }, // * %
    .{ 14, 13 }, // ^ (right associative)
    .{ 11, 11 }, .{ 11, 11 }, // / //
    .{ 6, 6 }, .{ 4, 4 }, .{ 5, 5 }, // & | ~
    .{ 7, 7 }, .{ 7, 7 }, // << >>
    .{ 9, 8 }, // .. (right associative)
    .{ 3, 3 }, .{ 3, 3 }, .{ 3, 3 }, // == < <=
    .{ 3, 3 }, .{ 3, 3 }, .{ 3, 3 }, // ~= > >=
    .{ 2, 2 }, .{ 1, 1 }, // and or
};

const unary_priority = 12;

/// subexpr -> (simpleexp | unop subexpr) { binop subexpr }, for binary
/// operators with priority above `limit`. Returns the first operator it
/// did not handle. The code generator's calls stay out of line: their
/// locals would sit in this frame, which every level of nesting repeats
/// on the native stack (`results/stack-20261031.md`).
fn subExpr(ls: *Parser, v: *ExpDesc, limit: u8) Error!BinOpr {
    try ls.enterLevel();
    const uop = getUnOpr(ls.t.kind);
    if (uop != .none) {
        const line = ls.lx.line;
        try ls.next();
        _ = try ls.subExpr(v, unary_priority);
        try @call(.never_inline, FuncState.prefix, .{ ls.fs.?, uop, v, line });
    } else {
        try ls.simpleExp(v);
    }
    var op = getBinOpr(ls.t.kind);
    while (op != .none and priority[@intFromEnum(op)][0] > limit) {
        var v2: ExpDesc = .{};
        const line = ls.lx.line;
        try ls.next();
        try @call(.never_inline, FuncState.infix, .{ ls.fs.?, op, v });
        const nextop = try ls.subExpr(&v2, priority[@intFromEnum(op)][1]);
        try @call(.never_inline, FuncState.posfix, .{ ls.fs.?, op, v, &v2, line });
        op = nextop;
    }
    ls.leaveLevel();
    return op;
}

fn expr(ls: *Parser, v: *ExpDesc) Error!void {
    _ = try ls.subExpr(v, 0);
}

// Statements.

fn block(ls: *Parser) Error!void {
    const fs = ls.fs.?;
    var bl: BlockCnt = .{};
    ls.enterBlock(fs, &bl, 0);
    try ls.statList();
    try ls.leaveBlock(fs);
}

/// The variables on the left of an assignment, chained.
const LhsAssign = struct {
    prev: ?*LhsAssign,
    v: ExpDesc,
};

/// In a multiple assignment, a local or upvalue assigned here that an
/// earlier target uses as its table or key gets copied to a temporary,
/// and the earlier target uses the copy.
fn checkConflict(ls: *Parser, lh_: ?*LhsAssign, v: *const ExpDesc) Error!void {
    const fs = ls.fs.?;
    const extra: u8 = @intCast(fs.freereg);
    var conflict = false;
    var lh = lh_;
    while (lh) |l| : (lh = l.prev) {
        if (!l.v.k.isIndexed()) continue;
        if (l.v.k == .indexup) {
            if (v.k == .upval and l.v.ind.t == v.info) {
                conflict = true;
                l.v.k = .indexstr;
                l.v.ind.t = extra;
            }
        } else {
            if (v.k == .local and l.v.ind.t == v.ridx) {
                conflict = true;
                l.v.ind.t = extra;
            }
            if (l.v.k == .indexed and v.k == .local and l.v.ind.idx == v.ridx) {
                conflict = true;
                l.v.ind.idx = extra;
            }
        }
    }
    if (conflict) {
        if (v.k == .local) {
            _ = try fs.codeAbc(.move, extra, v.ridx, 0);
        } else {
            _ = try fs.codeAbc(.getupval, extra, v.info, 0);
        }
        try fs.reserveRegs(1);
    }
}

/// Stores the top register into `v`.
fn storeVarTop(fs: *FuncState, v: *ExpDesc) Error!void {
    var e: ExpDesc = .init(.nonreloc, fs.freereg - 1);
    try fs.storeVar(v, &e);
}

fn restAssign(ls: *Parser, lh: *LhsAssign, nvars: i32) Error!void {
    var e: ExpDesc = .{};
    try ls.checkCondition(lh.v.k.isVar(), "syntax error");
    try ls.checkReadonly(&lh.v);
    if (try ls.testNext(.comma)) {
        var nv: LhsAssign = .{ .prev = lh, .v = .{} };
        try ls.suffixedExp(&nv.v);
        if (!nv.v.k.isIndexed()) try ls.checkConflict(lh, &nv.v);
        try ls.enterLevel();
        try ls.restAssign(&nv, nvars + 1);
        ls.leaveLevel();
    } else {
        try ls.checkNext(.assign);
        const nexps = try ls.expList(&e);
        if (nexps != nvars) {
            try ls.adjustAssign(nvars, nexps, &e);
        } else {
            ls.fs.?.setOneRet(&e);
            try ls.fs.?.storeVar(&lh.v, &e);
            return;
        }
    }
    try storeVarTop(ls.fs.?, &lh.v);
}

/// Reads a condition; returns its false list.
fn cond(ls: *Parser) Error!i32 {
    var v: ExpDesc = .{};
    try ls.expr(&v);
    if (v.k == .nil) v.k = .false;
    try ls.fs.?.goIfTrue(&v);
    return v.f;
}

fn gotoStat(ls: *Parser, line: u32) Error!void {
    const name = try ls.strCheckName();
    try ls.newGotoEntry(name, line);
}

/// `break`, which is `goto break`.
fn breakStat(ls: *Parser, line: u32) Error!void {
    var it = ls.fs.?.bl;
    while (it) |bl| : (it = bl.previous) {
        if (bl.isloop != 0) {
            bl.isloop = 2;
            try ls.next();
            return ls.newGotoEntry(ls.brkn, line);
        }
    }
    return ls.syntaxError("break outside loop");
}

fn checkRepeated(ls: *Parser, name: *String) Error!void {
    if (ls.findLabel(name, ls.fs.?.firstlabel)) |lb|
        return ls.semError("label '{s}' already defined on line {d}", .{ name.bytes(), lb.line });
}

fn labelStat(ls: *Parser, name: *String, line: u32) Error!void {
    try ls.checkNext(.dbcolon);
    while (ls.t.kind == .semicolon or ls.t.kind == .dbcolon) try ls.statement();
    try ls.checkRepeated(name);
    try ls.createLabel(name, line, ls.blockFollow(false));
}

fn whileStat(ls: *Parser, line: u32) Error!void {
    const fs = ls.fs.?;
    try ls.next();
    const whileinit = fs.getLabel();
    const condexit = try ls.cond();
    var bl: BlockCnt = .{};
    ls.enterBlock(fs, &bl, 1);
    try ls.checkNext(.do);
    try ls.block();
    try fs.jumpTo(whileinit);
    try ls.checkMatch(.end, .@"while", line);
    try ls.leaveBlock(fs);
    try fs.patchToHere(condexit);
}

fn repeatStat(ls: *Parser, line: u32) Error!void {
    const fs = ls.fs.?;
    const repeat_init = fs.getLabel();
    var bl1: BlockCnt = .{};
    var bl2: BlockCnt = .{};
    ls.enterBlock(fs, &bl1, 1);
    ls.enterBlock(fs, &bl2, 0);
    try ls.next();
    try ls.statList();
    try ls.checkMatch(.until, .repeat, line);
    var condexit = try ls.cond();
    if (bl2.upval) {
        const exit = try fs.jump();
        try fs.patchToHere(condexit);
        _ = try fs.codeAbc(.close, ls.regLevel(fs, bl2.nactvar), 0, 0);
        condexit = try fs.jump();
        try fs.patchToHere(exit);
    }
    try fs.patchList(condexit, repeat_init);
    try ls.leaveBlock(fs);
    try ls.leaveBlock(fs);
}

/// An expression into the next register.
fn exp1(ls: *Parser) Error!void {
    var e: ExpDesc = .{};
    try ls.expr(&e);
    try ls.fs.?.exp2nextreg(&e);
}

/// Points the loop instruction at `at` to `dest`, forward or back.
fn fixForJump(ls: *Parser, fs: *FuncState, at: i32, dest: i32, back: bool) Error!void {
    var offset = dest - (at + 1);
    if (back) offset = -offset;
    if (offset > opcodes.max_bx) return ls.syntaxError("control structure too long");
    Code.setBx(fs.inst(at), offset);
}

fn forBody(ls: *Parser, base: i32, line: u32, nvars: i32, isgen: bool) Error!void {
    const fs = ls.fs.?;
    try ls.checkNext(.do);
    const prep = try fs.codeABx(if (isgen) .tforprep else .forprep, base, 0);
    fs.freereg -= 1; // both preps remove one register
    var bl: BlockCnt = .{};
    ls.enterBlock(fs, &bl, 0);
    try ls.adjustLocalVars(nvars);
    try fs.reserveRegs(nvars);
    try ls.block();
    try ls.leaveBlock(fs);
    try ls.fixForJump(fs, prep, fs.getLabel(), false);
    if (isgen) {
        _ = try fs.codeAbc(.tforcall, base, 0, nvars);
        try fs.fixLine(line);
    }
    const endfor = try fs.codeABx(if (isgen) .tforloop else .forloop, base, 0);
    try ls.fixForJump(fs, endfor, prep + 1, true);
    try fs.fixLine(line);
}

fn forNum(ls: *Parser, varname: *String, line: u32) Error!void {
    const fs = ls.fs.?;
    const base = fs.freereg;
    _ = try ls.newLocalVarLiteral("(for state)");
    _ = try ls.newLocalVarLiteral("(for state)");
    _ = try ls.newVarKind(varname, VarKind.constant);
    try ls.checkNext(.assign);
    try ls.exp1();
    try ls.checkNext(.comma);
    try ls.exp1();
    if (try ls.testNext(.comma)) {
        try ls.exp1();
    } else {
        try fs.int(fs.freereg, 1);
        try fs.reserveRegs(1);
    }
    try ls.adjustLocalVars(2);
    try ls.forBody(base, line, 1, false);
}

fn forList(ls: *Parser, indexname: *String) Error!void {
    const fs = ls.fs.?;
    var e: ExpDesc = .{};
    var nvars: i32 = 4; // function, state, closing, control
    const base = fs.freereg;
    _ = try ls.newLocalVarLiteral("(for state)");
    _ = try ls.newLocalVarLiteral("(for state)");
    _ = try ls.newLocalVarLiteral("(for state)");
    _ = try ls.newVarKind(indexname, VarKind.constant);
    while (try ls.testNext(.comma)) {
        _ = try ls.newLocalVar(try ls.strCheckName());
        nvars += 1;
    }
    try ls.checkNext(.in);
    const line = ls.lx.line;
    try ls.adjustAssign(4, try ls.expList(&e), &e);
    try ls.adjustLocalVars(3);
    markToBeClosed(fs);
    try fs.checkStack(2);
    try ls.forBody(base, line, nvars - 3, true);
}

fn forStat(ls: *Parser, line: u32) Error!void {
    const fs = ls.fs.?;
    var bl: BlockCnt = .{};
    ls.enterBlock(fs, &bl, 1);
    try ls.next();
    const varname = try ls.strCheckName();
    switch (ls.t.kind) {
        .assign => try ls.forNum(varname, line),
        .comma, .in => try ls.forList(varname),
        else => return ls.syntaxError("'=' or 'in' expected"),
    }
    try ls.checkMatch(.end, .@"for", line);
    try ls.leaveBlock(fs);
}

fn testThenBlock(ls: *Parser, escapelist: *i32) Error!void {
    const fs = ls.fs.?;
    try ls.next();
    const condtrue = try ls.cond();
    try ls.checkNext(.then);
    try ls.block();
    if (ls.t.kind == .@"else" or ls.t.kind == .elseif) try fs.concat(escapelist, try fs.jump());
    try fs.patchToHere(condtrue);
}

fn ifStat(ls: *Parser, line: u32) Error!void {
    const fs = ls.fs.?;
    var escapelist: i32 = no_jump;
    try ls.testThenBlock(&escapelist);
    while (ls.t.kind == .elseif) try ls.testThenBlock(&escapelist);
    if (try ls.testNext(.@"else")) try ls.block();
    try ls.checkMatch(.end, .@"if", line);
    try fs.patchToHere(escapelist);
}

fn localFunc(ls: *Parser) Error!void {
    var b: ExpDesc = .{};
    const fs = ls.fs.?;
    const fvar = fs.nactvar;
    _ = try ls.newLocalVar(try ls.strCheckName());
    try ls.adjustLocalVars(1);
    try ls.body(&b, false, ls.lx.line);
    // Debug information sees the variable only from here.
    ls.localDebugInfo(fs, fvar).?.startpc = @intCast(fs.pc());
}

fn getVarAttribute(ls: *Parser, df: u8) Error!u8 {
    if (try ls.testNext(.lt)) {
        const ts = try ls.strCheckName();
        const attr = ts.bytes();
        try ls.checkNext(.gt);
        if (std.mem.eql(u8, attr, "const")) return @as(u8, VarKind.constant);
        if (std.mem.eql(u8, attr, "close")) return @as(u8, VarKind.to_close);
        return ls.semError("unknown attribute '{s}'", .{attr});
    }
    return df;
}

fn checkToClose(ls: *Parser, fs: *FuncState, level: i32) Error!void {
    if (level != -1) {
        markToBeClosed(fs);
        _ = try fs.codeAbc(.tbc, ls.regLevel(fs, level), 0, 0);
    }
}

fn localStat(ls: *Parser) Error!void {
    const fs = ls.fs.?;
    var toclose: i32 = -1;
    var vidx: i32 = undefined;
    var nvars: i32 = 0;
    var nexps: i32 = 0;
    var e: ExpDesc = .{};
    const defkind = try ls.getVarAttribute(VarKind.reg);
    while (true) {
        const vname = try ls.strCheckName();
        const kind = try ls.getVarAttribute(defkind);
        vidx = try ls.newVarKind(vname, kind);
        if (kind == VarKind.to_close) {
            if (toclose != -1) return ls.semError("multiple to-be-closed variables in local list", .{});
            toclose = fs.nactvar + nvars;
        }
        nvars += 1;
        if (!try ls.testNext(.comma)) break;
    }
    if (try ls.testNext(.assign)) {
        nexps = try ls.expList(&e);
    } else {
        e.k = .void;
        nexps = 0;
    }
    const v = ls.getLocalVarDesc(fs, vidx);
    if (nvars == nexps and v.kind == VarKind.constant and fs.exp2const(&e, &v.k)) {
        v.kind = VarKind.ctc;
        try ls.adjustLocalVars(nvars - 1);
        fs.nactvar += 1;
    } else {
        try ls.adjustAssign(nvars, nexps, &e);
        try ls.adjustLocalVars(nvars);
    }
    try ls.checkToClose(fs, toclose);
}

fn getGlobalAttribute(ls: *Parser, df: u8) Error!u8 {
    const kind = try ls.getVarAttribute(df);
    if (kind == VarKind.to_close) return ls.semError("global variables cannot be to-be-closed", .{});
    return if (kind == VarKind.constant) VarKind.global_const else kind;
}

fn checkGlobal(ls: *Parser, varname: *String, line: u32) Error!void {
    var v: ExpDesc = .{};
    try ls.buildGlobal(varname, &v);
    try ls.fs.?.codeCheckGlobal(&v, v.ind.keystr, line);
}

/// Builds the targets of `global` names with initializers on the way
/// down, reads the expressions at the bottom, and assigns on the way up,
/// checking that each global was nil.
fn initGlobal(ls: *Parser, nvars: i32, firstidx: i32, n: i32, line: u32) Error!void {
    if (n == nvars) {
        var e: ExpDesc = .{};
        const nexps = try ls.expList(&e);
        try ls.adjustAssign(nvars, nexps, &e);
        return;
    }
    const fs = ls.fs.?;
    var v: ExpDesc = .{};
    const varname = ls.getLocalVarDesc(fs, firstidx + n).name.?;
    try ls.buildGlobal(varname, &v);
    try ls.enterLevel();
    try ls.initGlobal(nvars, firstidx, n + 1, line);
    ls.leaveLevel();
    try ls.checkGlobal(varname, line);
    try storeVarTop(fs, &v);
}

fn globalNames(ls: *Parser, defkind: u8) Error!void {
    const fs = ls.fs.?;
    var nvars: i32 = 0;
    var lastidx: i32 = undefined;
    while (true) {
        const vname = try ls.strCheckName();
        const kind = try ls.getGlobalAttribute(defkind);
        lastidx = try ls.newVarKind(vname, kind);
        nvars += 1;
        if (!try ls.testNext(.comma)) break;
    }
    if (try ls.testNext(.assign)) try ls.initGlobal(nvars, lastidx - nvars + 1, 0, ls.lx.line);
    fs.nactvar += nvars;
}

fn globalStat(ls: *Parser) Error!void {
    const fs = ls.fs.?;
    const defkind = try ls.getGlobalAttribute(VarKind.global_reg);
    if (!try ls.testNext(.star)) {
        try ls.globalNames(defkind);
    } else {
        _ = try ls.newVarKind(null, defkind);
        fs.nactvar += 1;
    }
}

fn globalFunc(ls: *Parser, line: u32) Error!void {
    var v: ExpDesc = .{};
    var b: ExpDesc = .{};
    const fs = ls.fs.?;
    const fname = try ls.strCheckName();
    _ = try ls.newVarKind(fname, VarKind.global_reg);
    fs.nactvar += 1;
    try ls.buildGlobal(fname, &v);
    try ls.body(&b, false, ls.lx.line);
    try ls.checkGlobal(fname, line);
    try fs.storeVar(&v, &b);
    try fs.fixLine(line);
}

fn globalStatFunc(ls: *Parser, line: u32) Error!void {
    try ls.next();
    if (try ls.testNext(.function)) {
        try ls.globalFunc(line);
    } else {
        try ls.globalStat();
    }
}

fn funcName(ls: *Parser, v: *ExpDesc) Error!bool {
    try ls.singleVar(v);
    while (ls.t.kind == .dot) try ls.fieldSel(v);
    if (ls.t.kind == .colon) {
        try ls.fieldSel(v);
        return true;
    }
    return false;
}

fn funcStat(ls: *Parser, line: u32) Error!void {
    var v: ExpDesc = .{};
    var b: ExpDesc = .{};
    try ls.next();
    const ismethod = try ls.funcName(&v);
    try ls.checkReadonly(&v);
    try ls.body(&b, ismethod, line);
    try ls.fs.?.storeVar(&v, &b);
    try ls.fs.?.fixLine(line);
}

fn exprStat(ls: *Parser) Error!void {
    const fs = ls.fs.?;
    var v: LhsAssign = .{ .prev = null, .v = .{} };
    try ls.suffixedExp(&v.v);
    if (ls.t.kind == .assign or ls.t.kind == .comma) {
        try ls.restAssign(&v, 1);
    } else {
        try ls.checkCondition(v.v.k == .call, "syntax error");
        const i = fs.inst(v.v.info);
        i.* = (i.* & 0x00ff_ffff) | (1 << 24); // C = 1: no results
    }
}

fn retStat(ls: *Parser) Error!void {
    const fs = ls.fs.?;
    var e: ExpDesc = .{};
    var nret: i32 = undefined;
    var first = ls.nvarstack(fs);
    if (ls.blockFollow(true) or ls.t.kind == .semicolon) {
        nret = 0;
    } else {
        nret = try ls.expList(&e);
        if (e.k.hasMultRet()) {
            try fs.setMultRet(&e);
            if (e.k == .call and nret == 1 and !fs.bl.?.insidetbc) {
                const i = fs.inst(e.info);
                i.* = (i.* & ~@as(u32, 0x7f)) | @intFromEnum(opcodes.OpCode.tailcall);
                std.debug.assert(opcodes.a(i.*) == ls.nvarstack(fs));
            }
            nret = multret;
        } else if (nret == 1) {
            first = try fs.exp2anyreg(&e);
        } else {
            try fs.exp2nextreg(&e);
            std.debug.assert(nret == fs.freereg - first);
        }
    }
    try fs.ret(first, nret);
    _ = try ls.testNext(.semicolon);
}

fn statement(ls: *Parser) Error!void {
    const line = ls.lx.line;
    try ls.enterLevel();
    switch (ls.t.kind) {
        .semicolon => try ls.next(),
        .@"if" => try ls.ifStat(line),
        .@"while" => try ls.whileStat(line),
        .do => {
            try ls.next();
            try ls.block();
            try ls.checkMatch(.end, .do, line);
        },
        .@"for" => try ls.forStat(line),
        .repeat => try ls.repeatStat(line),
        .function => try ls.funcStat(line),
        .local => {
            try ls.next();
            if (try ls.testNext(.function)) {
                try ls.localFunc();
            } else {
                try ls.localStat();
            }
        },
        .global => try ls.globalStatFunc(line),
        .dbcolon => {
            try ls.next();
            try ls.labelStat(try ls.strCheckName(), line);
        },
        .@"return" => {
            try ls.next();
            try ls.retStat();
        },
        .@"break" => try ls.breakStat(line),
        .goto => {
            try ls.next();
            try ls.gotoStat(line);
        },
        .name => {
            // `global` is a name; it starts a declaration only before a
            // name, an attribute, `*`, or `function`.
            if (ls.t.ts == ls.glbn) {
                switch (try ls.lookahead()) {
                    .lt, .name, .star, .function => {
                        try ls.globalStatFunc(line);
                        return ls.endStatement();
                    },
                    else => {},
                }
            }
            try ls.exprStat();
        },
        else => try ls.exprStat(),
    }
    ls.endStatement();
}

fn endStatement(ls: *Parser) void {
    const fs = ls.fs.?;
    std.debug.assert(fs.f.maxstacksize >= fs.freereg);
    std.debug.assert(fs.freereg >= ls.nvarstack(fs));
    fs.freereg = ls.nvarstack(fs);
    ls.leaveLevel();
}

/// The main function: vararg, with one upvalue, `_ENV`.
fn mainFunc(ls: *Parser) Error!*Proto {
    ls.envn = try ls.newString("_ENV");
    ls.brkn = try ls.newString("break");
    ls.glbn = try ls.newString("global");
    const f = try Proto.create(&ls.state.heap);
    ls.source = try ls.state.newString(ls.chunkname);
    var fs: FuncState = .{ .f = f, .ls = ls };
    errdefer fs.deinit();
    var bl: BlockCnt = .{};
    ls.openFunc(&fs, &bl);
    try setVararg(&fs);
    const env = try ls.allocUpvalue(&fs);
    env.* = .{ .instack = true, .idx = 0, .kind = VarKind.reg, .name = ls.envn };
    try ls.next();
    try ls.statList();
    try ls.check(.eos);
    try ls.closeFunc();
    return f;
}

const testing = std.testing;

test "syntax errors raise the reference's messages as Lua errors" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const th = state.main;
    const cases = [_][2][:0]const u8{
        .{ "x = = 1", "[string \"x = = 1\"]:1: unexpected symbol near '='" },
        .{ "local x <const> = 1; x = 2", "c:1: attempt to assign to const variable 'x'" },
        .{ "\n\nx = \"abc", "c:3: unfinished string near <eof>" },
        .{ "global x; y = 1", "c:1: variable 'y' not declared" },
        .{ "goto nowhere", "c:1: no visible label 'nowhere' for <goto> at line 1" },
        .{ "for i = 1 do end", "c:1: ',' expected near 'do'" },
    };
    for (cases, 0..) |c, i| {
        const name = if (i == 0) c[0] else "=c";
        try testing.expectError(error.LuaError, compile(th, c[0], name));
        try testing.expectEqualStrings(c[1], th.err.asString().bytes());
        th.err = .nil;
    }
    // A chunk that compiles: `global` is still a name where a declaration
    // cannot start, as lparser.c's compat lookahead allows.
    const p = try compile(th, "local global = 1; global = global + 1; return global", "=c");
    try testing.expect(p.code.len > 0);
}
