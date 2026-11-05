//! A function prototype: the bytecode, constants, nested prototypes, and
//! debug information the compiler produces for one Lua function. Closures
//! (a prototype or native function plus upvalues) and upvalues live here
//! too.
//!
//! The parser fills a prototype's slices with memory from
//! `heap.allocator()`; `destroy` frees them with the same allocator.

const Proto = @This();

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("Value.zig");
const String = @import("String.zig");
const opcodes = @import("opcodes.zig");
const lua_options = @import("lua_options");

header: gc.Header,
gclist: ?*gc.Header = null,
/// The instructions; see opcodes.zig.
code: []u32 = &.{},
/// The constants: nil, booleans, numbers, and strings.
k: []Value = &.{},
/// For each constant, the hash node where `GETTABUP` or `SETTABUP` last
/// found it: the inline cache for global access. Empty when the code has
/// neither.
kslot: []u32 = &.{},
/// Prototypes of the functions defined inside this one, for `CLOSURE`.
p: []*Proto = &.{},
upvalues: []UpvalDesc = &.{},
/// The source lines, in lcode.c's encoding, which `string.dump` writes as
/// is: for each instruction, its line minus the previous instruction's
/// (the first's minus `linedefined`), or `abs_line_info` where
/// `abslineinfo` holds the line. Empty without debug information;
/// `lineAt` decodes it.
lineinfo: []i8 = &.{},
/// The absolute lines: an entry for each instruction whose change does
/// not fit in a byte, and at least one every `max_iwthabs` instructions,
/// so `lineAt` adds at most that many bytes.
abslineinfo: []AbsLineInfo = &.{},
locvars: []LocVar = &.{},
/// The chunk name, as `load` received it.
source: ?*String = null,
linedefined: u32 = 0,
lastlinedefined: u32 = 0,
/// Number of fixed parameters.
numparams: u8 = 0,
flags: Flags = .{},
/// Registers the function needs, parameters included.
maxstacksize: u8 = 2,

/// lobject.h's `AbsLineInfo`, in the layout binary chunks hold.
pub const AbsLineInfo = extern struct {
    pc: i32,
    line: i32,
};

/// ldebug.h's `ABSLINEINFO`: a `lineinfo` byte that defers to an
/// `abslineinfo` entry.
pub const abs_line_info: i8 = -0x80;
/// ldebug.h's `MAXIWTHABS`: the most relative entries in a row.
pub const max_iwthabs = 128;

pub const Flags = packed struct(u8) {
    /// Declared with `...`. Its first instruction is `VARARGPREP`, which
    /// moves the fixed parameters above the extra arguments.
    vararg: bool = false,
    /// Lua 5.5's named vararg table (`function f(...t)`): `VARARGPREP`
    /// packs the extra arguments into a table in register `numparams`.
    vararg_table: bool = false,
    _: u6 = 0,
};

/// How a closure finds an upvalue when `CLOSURE` creates it: a register of
/// the enclosing function (`instack`) or one of the enclosing closure's
/// upvalues.
pub const UpvalDesc = struct {
    name: ?*String = null,
    instack: bool,
    /// The register or the enclosing upvalue's index.
    idx: u8,
    /// The variable's kind (regular, `<const>`, `<close>`, ...), for the
    /// compiler's own use.
    kind: u8 = 0,
};

pub const LocVar = struct {
    name: ?*String,
    /// The first instruction where the variable is active.
    startpc: u32,
    /// The first instruction where it is dead.
    endpc: u32,
};

/// A new empty prototype, linked into the heap.
pub fn create(heap: *gc.Heap) error{OutOfMemory}!*Proto {
    const p = try heap.raw().create(Proto);
    p.* = .{ .header = undefined };
    heap.link(&p.header, .proto);
    return p;
}

pub fn destroy(heap: *gc.Heap, p: *Proto) void {
    const a = heap.raw();
    a.free(p.code);
    a.free(p.k);
    a.free(p.kslot);
    a.free(p.p);
    a.free(p.upvalues);
    a.free(p.lineinfo);
    a.free(p.abslineinfo);
    a.free(p.locvars);
    a.destroy(p);
}

/// The bytes the prototype holds, for the collector's pacing.
pub fn byteSize(p: *const Proto) usize {
    return @sizeOf(Proto) + p.code.len * @sizeOf(u32) + p.k.len * @sizeOf(Value) + p.kslot.len * @sizeOf(u32) +
        p.p.len * @sizeOf(*Proto) + p.upvalues.len * @sizeOf(UpvalDesc) + p.lineinfo.len +
        p.abslineinfo.len * @sizeOf(AbsLineInfo) + p.locvars.len * @sizeOf(LocVar);
}

/// Allocates `kslot` when the code reads or writes a global (`GETTABUP`,
/// `SETTABUP`); call once `code` and `k` are final.
pub fn initSlots(p: *Proto, gpa: std.mem.Allocator) error{OutOfMemory}!void {
    for (p.code) |i| {
        const o: u7 = @truncate(i);
        if (o == @backingInt(opcodes.OpCode.gettabup) or o == @backingInt(opcodes.OpCode.settabup)) {
            p.kslot = try gpa.alloc(u32, p.k.len);
            @memset(p.kslot, 0);
            return;
        }
    }
}

/// The source line of the instruction at `pc`, or null without line info,
/// `luaG_getfuncline`: from the last absolute entry at or before `pc` (or
/// `linedefined`), plus the changes after it. A loaded chunk's entries are
/// not checked, so out-of-order ones give some line, never a read out of
/// bounds.
pub fn lineAt(p: *const Proto, pc: usize) ?i32 {
    if (pc >= p.lineinfo.len) return null;
    const abs = p.abslineinfo;
    var line: i32 = @bitCast(p.linedefined);
    var from: usize = 0;
    if (abs.len > 0 and pc >= abs[0].pc) {
        // An entry comes at least every `max_iwthabs` instructions, so
        // this estimate is at or below the one wanted.
        var i = @min(pc / max_iwthabs, abs.len) -| 1;
        while (i + 1 < abs.len and pc >= abs[i + 1].pc) i += 1;
        line = abs[i].line;
        from = @intCast(@as(i64, @max(abs[i].pc, -1)) + 1);
    }
    if (from <= pc) {
        for (p.lineinfo[from .. pc + 1]) |d| line +%= d;
    }
    return line;
}

/// Whether the instruction at `newpc` is on another line than the one at
/// `oldpc`, which comes before it: ldebug.c's `changedline`, which adds
/// the changes between them when they are close.
pub fn changedLine(p: *const Proto, oldpc: usize, newpc: usize) bool {
    if (p.lineinfo.len == 0) return false;
    if (newpc < p.lineinfo.len and newpc - oldpc < max_iwthabs / 2) {
        var delta: i32 = 0;
        for (p.lineinfo[oldpc + 1 .. newpc + 1]) |d| {
            if (d == abs_line_info) break;
            delta += d;
        } else return delta != 0;
    }
    return p.lineAt(oldpc) != p.lineAt(newpc);
}

/// The line of the instruction at `pc` given `line`, the previous one's:
/// ldebug.c's `nextline`, for walking every instruction in order.
pub fn nextLine(p: *const Proto, line: i32, pc: usize) i32 {
    const d = p.lineinfo[pc];
    return if (d != abs_line_info) line +% d else p.lineAt(pc).?;
}

/// A Lua function: a prototype and its upvalues, which trail the struct.
pub const LuaClosure = struct {
    header: gc.Header,
    nupvalues: u8,
    gclist: ?*gc.Header = null,
    proto: *Proto,

    pub fn allocSize(n: usize) usize {
        return @sizeOf(LuaClosure) + n * @sizeOf(*Upval);
    }

    /// A new closure with `n` upvalue slots, which the caller fills before
    /// the collector can run.
    pub fn create(heap: *gc.Heap, proto: *Proto, n: u8) error{OutOfMemory}!*LuaClosure {
        const mem = try heap.raw().alignedAlloc(u8, .of(LuaClosure), allocSize(n));
        const c: *LuaClosure = @ptrCast(mem.ptr);
        c.* = .{ .header = undefined, .nupvalues = n, .proto = proto };
        heap.link(&c.header, .lua_closure);
        return c;
    }

    pub fn destroy(heap: *gc.Heap, c: *LuaClosure) void {
        const p: [*]align(@alignOf(LuaClosure)) u8 = @ptrCast(c);
        heap.raw().free(p[0..allocSize(c.nupvalues)]);
    }

    pub inline fn upvals(c: *LuaClosure) []*Upval {
        const p: [*]u8 = @ptrCast(c);
        const u: [*]*Upval = @ptrCast(@alignCast(p + @sizeOf(LuaClosure)));
        return u[0..c.nupvalues];
    }

    /// Stores upvalue `i`, with the write barrier.
    pub inline fn setUpval(c: *LuaClosure, heap: *gc.Heap, i: usize, uv: *Upval) void {
        c.upvals()[i] = uv;
        gc.barrier(heap, &c.header, .object(&uv.header));
    }
};

/// A native function with upvalues, which trail the struct as values.
pub const NativeClosure = struct {
    header: gc.Header,
    nupvalues: u8,
    gclist: ?*gc.Header = null,
    f: Value.NativeFn,
    /// C-API builds: the `lua_CFunction` of a C function, which `f`, the
    /// C API's trampoline, calls; null for Zig natives. Absent otherwise.
    cfn: if (lua_options.c_api) ?*const anyopaque else void = if (lua_options.c_api) null else {},

    pub fn allocSize(n: usize) usize {
        return @sizeOf(NativeClosure) + n * @sizeOf(Value);
    }

    /// A new native closure whose `n` upvalues are nil.
    pub fn create(heap: *gc.Heap, f: Value.NativeFn, n: u8) error{OutOfMemory}!*NativeClosure {
        const mem = try heap.raw().alignedAlloc(u8, .of(NativeClosure), allocSize(n));
        const c: *NativeClosure = @ptrCast(mem.ptr);
        c.* = .{ .header = undefined, .nupvalues = n, .f = f };
        @memset(c.upvalues(), Value.nil);
        heap.link(&c.header, .native_closure);
        return c;
    }

    pub fn destroy(heap: *gc.Heap, c: *NativeClosure) void {
        const p: [*]align(@alignOf(NativeClosure)) u8 = @ptrCast(c);
        heap.raw().free(p[0..allocSize(c.nupvalues)]);
    }

    pub inline fn upvalues(c: *NativeClosure) []Value {
        const p: [*]u8 = @ptrCast(c);
        const u: [*]Value = @ptrCast(@alignCast(p + @sizeOf(NativeClosure)));
        return u[0..c.nupvalues];
    }

    /// Stores upvalue `i`, with the write barrier.
    pub inline fn setUpvalue(c: *NativeClosure, heap: *gc.Heap, i: usize, v: Value) void {
        c.upvalues()[i] = v;
        gc.barrier(heap, &c.header, v);
    }

    comptime {
        std.debug.assert(@sizeOf(NativeClosure) % @alignOf(Value) == 0);
    }
};

/// An upvalue. While open, `v` points at its variable's stack slot and the
/// upvalue sits in its thread's list of open upvalues; the thread repoints
/// `v` whenever its stack moves. Closing copies the value into `closed`
/// and points `v` there.
pub const Upval = struct {
    header: gc.Header,
    v: *Value,
    /// The value once closed.
    closed: Value = .nil,
    /// List links while open.
    open: struct {
        /// The next open upvalue, at a lower stack level.
        next: ?*Upval,
        /// The link that points at this upvalue, for unlinking.
        prev: *?*Upval,
        /// The stack index of the variable.
        level: u32,
    } = undefined,

    pub inline fn fromHeader(h: *gc.Header) *Upval {
        return @fieldParentPtr("header", h);
    }

    pub inline fn isOpen(uv: *const Upval) bool {
        return uv.v != &uv.closed;
    }

    /// A new closed upvalue holding `v`.
    pub fn createClosed(heap: *gc.Heap, v: Value) error{OutOfMemory}!*Upval {
        const uv = try heap.raw().create(Upval);
        uv.* = .{ .header = undefined, .v = undefined, .closed = v };
        uv.v = &uv.closed;
        heap.link(&uv.header, .upval);
        return uv;
    }

    /// Stores through the upvalue, with the write barrier.
    pub inline fn set(uv: *Upval, heap: *gc.Heap, v: Value) void {
        uv.v.* = v;
        gc.barrier(heap, &uv.header, v);
    }

    pub fn destroy(heap: *gc.Heap, uv: *Upval) void {
        if (uv.isOpen()) uv.unlink();
        heap.raw().destroy(uv);
    }

    /// Removes an open upvalue from its thread's list.
    pub fn unlink(uv: *Upval) void {
        uv.open.prev.* = uv.open.next;
        if (uv.open.next) |n| n.open.prev = uv.open.prev;
    }
};
