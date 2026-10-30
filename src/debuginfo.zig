//! Names for values and functions from a prototype's debug information
//! and bytecode, as PUC-Rio's ldebug.c finds them: the "(global 'x')" in
//! "attempt to index a nil value (global 'x')", and the function names a
//! traceback shows. Local variable names come from `Proto.locvars`;
//! everything else comes from symbolic execution of the bytecode up to the
//! instruction that failed.

const std = @import("std");
const Value = @import("Value.zig");
const Proto = @import("Proto.zig");
const Thread = @import("Thread.zig");
const State = @import("State.zig");
const opcodes = @import("opcodes.zig");

const Instruction = opcodes.Instruction;
const op = opcodes.op;

/// What a name names ("global", "local", "method", "field", "upvalue",
/// "constant", "metamethod", "for iterator") and the name itself. Both
/// point at memory the prototype or the state owns.
pub const Name = struct {
    kind: []const u8,
    name: []const u8,
};

/// Where a value an instruction failed on came from, for `varInfo`.
pub const Origin = union(enum) {
    none,
    /// A stack slot; only slots among the running Lua frame's registers
    /// get a name.
    slot: u32,
    /// An upvalue of the running Lua function.
    upval: u32,
};

/// The name of local variable `n` (1-based, in declaration order among
/// the ones alive) at instruction `pc`, `luaF_getlocalname`.
pub fn localName(p: *const Proto, n: u32, pc: usize) ?[]const u8 {
    var left = n;
    for (p.locvars) |lv| {
        if (lv.startpc > pc) break;
        if (pc < lv.endpc) {
            left -= 1;
            if (left == 0) return if (lv.name) |s| s.bytes() else null;
        }
    }
    return null;
}

pub fn upvalName(p: *const Proto, i: usize) []const u8 {
    if (i < p.upvalues.len) {
        if (p.upvalues[i].name) |s| return s.bytes();
    }
    return "?";
}

/// " (kind 'name')" for a value the running instruction failed on, or ""
/// when the running frame is not Lua or nothing names it, `varinfo`.
pub fn varInfo(th: *Thread, origin: Origin, buf: []u8) []const u8 {
    const f = th.frame();
    if (!f.flags.lua) return "";
    const p = th.stack[f.func].asLuaClosure().proto;
    const n: ?Name = switch (origin) {
        .none => null,
        .upval => |i| .{ .kind = "upvalue", .name = upvalName(p, i) },
        .slot => |s| if (s >= f.base() and s < f.top)
            objName(p, Thread.currentPc(p, f), s - f.base())
        else
            null,
    };
    return format(n, buf);
}

/// " (kind 'name')", or "" for no name, `formatvarinfo`.
pub fn format(n: ?Name, buf: []u8) []const u8 {
    const v = n orelse return "";
    return std.fmt.bufPrint(buf, " ({s} '{s}')", .{ v.kind, v.name }) catch blk: {
        // Names are bounded by what fits; cut a long one.
        const s = std.fmt.bufPrint(buf, " ({s} '", .{v.kind}) catch break :blk "";
        const room = buf.len - s.len - 2;
        @memcpy(buf[s.len..][0..room], v.name[0..room]);
        @memcpy(buf[s.len + room ..][0..2], "')");
        break :blk buf;
    };
}

/// The name of the function Lua frame number `level` (an index into
/// `th.frames`) is running, from the instruction that called it, or null
/// for a tail call or a call from native code, `getfuncname`.
pub fn funcName(th: *Thread, level: usize) ?Name {
    const f = &th.frames.items[level];
    if (f.flags.tail or level == 0) return null;
    return callerName(th, level - 1);
}

/// The name a call made by the frame at `level` gives its callee,
/// `funcnamefromcall`.
pub fn callerName(th: *Thread, level: usize) ?Name {
    const f = &th.frames.items[level];
    if (!f.flags.lua) return null;
    const p = th.stack[f.func].asLuaClosure().proto;
    return funcNameFromCode(th.state, p, Thread.currentPc(p, f));
}

/// The name a calling instruction gives the function it calls, including
/// metamethods the instruction calls, `funcnamefromcode`.
pub fn funcNameFromCode(state: *const State, p: *const Proto, pc: usize) ?Name {
    const i = p.code[pc];
    const tm: State.Tm = switch (op(i)) {
        .call, .tailcall => return objName(p, pc, opcodes.a(i)),
        .tforcall => return .{ .kind = "for iterator", .name = "for iterator" },
        .self, .gettabup, .gettable, .geti, .getfield => .index,
        .settabup, .settable, .seti, .setfield => .newindex,
        .mmbin, .mmbini, .mmbink => @enumFromInt(opcodes.c(i)),
        .unm => .unm,
        .bnot => .bnot,
        .len => .len,
        .concat => .concat,
        .eq => .eq,
        .lt, .lti, .gti => .lt,
        .le, .lei, .gei => .le,
        .close, .@"return" => .close,
        else => return null,
    };
    return .{ .kind = "metamethod", .name = state.tm_names[@intFromEnum(tm)].bytes()[2..] };
}

/// The last instruction before `lastpc` that changed register `reg`, or
/// null when none did or a jump makes it uncertain, `findsetreg`.
fn findSetReg(p: *const Proto, lastpc_in: usize, reg: u32) ?usize {
    var lastpc = lastpc_in;
    // The metamethod instruction after an arithmetic one did not run.
    if (opcodes.props[@intFromEnum(op(p.code[lastpc]))].is_mm) lastpc -= 1;
    var setreg: ?usize = null;
    var jmptarget: usize = 0;
    for (p.code[0..lastpc], 0..) |i, pc| {
        const a: u32 = opcodes.a(i);
        const change = switch (op(i)) {
            .loadnil => a <= reg and reg <= a + opcodes.b(i),
            .tforcall => reg >= a + 2,
            .call, .tailcall => reg >= a,
            .jmp => blk: {
                const dest: isize = @as(isize, @intCast(pc)) + 1 + opcodes.sj(i);
                if (dest <= lastpc and dest > jmptarget) jmptarget = @intCast(dest);
                break :blk false;
            },
            else => |o| opcodes.props[@intFromEnum(o)].sets_a and reg == a,
        };
        if (change) setreg = if (pc < jmptarget) null else pc;
    }
    return setreg;
}

fn constName(p: *const Proto, idx: usize) ?Name {
    const v = p.k[idx];
    if (v.isString()) return .{ .kind = "constant", .name = v.asString().bytes() };
    return null;
}

/// A local, upvalue, or constant name for register `reg` at `pc`;
/// `basicgetobjname`. Sets `pc` to the instruction that set the register.
fn basicObjName(p: *const Proto, pc: *?usize, reg: u32) ?Name {
    if (localName(p, reg + 1, pc.*.?)) |n| return .{ .kind = "local", .name = n };
    pc.* = findSetReg(p, pc.*.?, reg);
    const at = pc.* orelse return null;
    const i = p.code[at];
    switch (op(i)) {
        .move => {
            const b = opcodes.b(i);
            if (b < opcodes.a(i)) return basicObjName(p, pc, b);
        },
        .getupval => return .{ .kind = "upvalue", .name = upvalName(p, opcodes.b(i)) },
        .loadk => return constName(p, opcodes.bx(i)),
        .loadkx => return constName(p, opcodes.ax(p.code[at + 1])),
        else => {},
    }
    return null;
}

/// The constant name of the key in register `c`, or "?", `rname`.
fn regKeyName(p: *const Proto, pc: usize, c: u32) []const u8 {
    var at: ?usize = pc;
    const n = basicObjName(p, &at, c) orelse return "?";
    return if (std.mem.eql(u8, n.kind, "constant")) n.name else "?";
}

/// "global" when the table instruction `i` indexes is the variable
/// `_ENV`, else "field", `isEnv`.
fn envKind(p: *const Proto, pc: usize, i: Instruction, is_up: bool) []const u8 {
    const t = opcodes.b(i);
    const name: ?[]const u8 = if (is_up) upvalName(p, t) else blk: {
        var at: ?usize = pc;
        const n = basicObjName(p, &at, t) orelse break :blk null;
        if (!std.mem.eql(u8, n.kind, "local") and !std.mem.eql(u8, n.kind, "upvalue")) break :blk null;
        break :blk n.name;
    };
    return if (name != null and std.mem.eql(u8, name.?, "_ENV")) "global" else "field";
}

/// A name for the value in register `reg` at instruction `lastpc`,
/// `getobjname`.
pub fn objName(p: *const Proto, lastpc: usize, reg: u32) ?Name {
    var pc: ?usize = lastpc;
    if (basicObjName(p, &pc, reg)) |n| return n;
    const at = pc orelse return null;
    const i = p.code[at];
    switch (op(i)) {
        .gettabup => return .{
            .kind = envKind(p, at, i, true),
            .name = if (constName(p, opcodes.c(i))) |n| n.name else "?",
        },
        .gettable, .getvarg => return .{
            .kind = envKind(p, at, i, false),
            .name = regKeyName(p, at, opcodes.c(i)),
        },
        .geti => return .{ .kind = "field", .name = "integer index" },
        .getfield => return .{
            .kind = envKind(p, at, i, false),
            .name = if (constName(p, opcodes.c(i))) |n| n.name else "?",
        },
        .self => return .{
            .kind = "method",
            .name = if (constName(p, opcodes.c(i))) |n| n.name else "?",
        },
        else => {},
    }
    return null;
}

/// "chunk:line: " for the function `level` calls below the running one
/// (0 is the running function itself) when it is a Lua function with line
/// information, and nothing otherwise, as `luaL_where` writes it.
pub fn where(th: *Thread, level: usize, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const n = th.frames.items.len;
    if (level + 1 >= n) return;
    const f = &th.frames.items[n - 1 - level];
    if (!f.flags.lua) return;
    const p = th.stack[f.func].asLuaClosure().proto;
    const line = p.lineAt(Thread.currentPc(p, f)) orelse return;
    if (line == 0) return;
    try Thread.writeChunkId(w, if (p.source) |s| s.bytes() else "=?");
    try w.print(":{d}: ", .{line});
}

/// The name of function `f` among the loaded modules, as
/// `pushglobalfuncname` finds it: "module.field" from
/// `registry._LOADED`, or the bare field for `_G`. Written to `buf`.
pub fn globalFuncName(state: *State, f: Value, buf: []u8) ?[]const u8 {
    const key = state.newString("_LOADED") catch return null;
    const loaded = state.registry.getStr(key);
    if (!loaded.isTable()) return null;
    var it = loaded.asTable().next(.nil) catch return null;
    while (it) |mod| : (it = loaded.asTable().next(mod.key) catch return null) {
        if (!mod.key.isString()) continue;
        if (Value.rawEquals(mod.value, f)) return std.fmt.bufPrint(buf, "{s}", .{mod.key.asString().bytes()}) catch null;
        if (!mod.value.isTable()) continue;
        var jt = mod.value.asTable().next(.nil) catch continue;
        while (jt) |field| : (jt = mod.value.asTable().next(field.key) catch null) {
            if (!field.key.isString() or !Value.rawEquals(field.value, f)) continue;
            const m = mod.key.asString().bytes();
            const n = field.key.asString().bytes();
            if (std.mem.eql(u8, m, "_G")) return std.fmt.bufPrint(buf, "{s}", .{n}) catch null;
            return std.fmt.bufPrint(buf, "{s}.{s}", .{ m, n }) catch null;
        }
    }
    return null;
}
