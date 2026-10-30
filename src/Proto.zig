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

header: gc.Header,
gclist: ?*gc.Header = null,
/// The instructions; see opcodes.zig.
code: []u32 = &.{},
/// The constants: nil, booleans, numbers, and strings.
k: []Value = &.{},
/// Prototypes of the functions defined inside this one, for `CLOSURE`.
p: []*Proto = &.{},
upvalues: []UpvalDesc = &.{},
/// The source line of each instruction (`lineinfo.len` is 0 or
/// `code.len`). PUC-Rio's compressed encoding can replace it later.
lineinfo: []u32 = &.{},
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
    const p = try heap.allocator().create(Proto);
    p.* = .{ .header = undefined };
    heap.link(&p.header, .proto);
    return p;
}

pub fn destroy(heap: *gc.Heap, p: *Proto) void {
    const a = heap.allocator();
    a.free(p.code);
    a.free(p.k);
    a.free(p.p);
    a.free(p.upvalues);
    a.free(p.lineinfo);
    a.free(p.locvars);
    a.destroy(p);
}

/// The bytes the prototype holds, for the collector's pacing.
pub fn byteSize(p: *const Proto) usize {
    return @sizeOf(Proto) + p.code.len * @sizeOf(u32) + p.k.len * @sizeOf(Value) + p.p.len * @sizeOf(*Proto) +
        p.upvalues.len * @sizeOf(UpvalDesc) + p.lineinfo.len * @sizeOf(u32) + p.locvars.len * @sizeOf(LocVar);
}

/// The source line of the instruction at `pc`, or null without line info.
pub fn lineAt(p: *const Proto, pc: usize) ?u32 {
    return if (pc < p.lineinfo.len) p.lineinfo[pc] else null;
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
        const mem = try heap.allocator().alignedAlloc(u8, .of(LuaClosure), allocSize(n));
        const c: *LuaClosure = @ptrCast(mem.ptr);
        c.* = .{ .header = undefined, .nupvalues = n, .proto = proto };
        heap.link(&c.header, .lua_closure);
        return c;
    }

    pub fn destroy(heap: *gc.Heap, c: *LuaClosure) void {
        const p: [*]align(@alignOf(LuaClosure)) u8 = @ptrCast(c);
        heap.allocator().free(p[0..allocSize(c.nupvalues)]);
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

    pub fn allocSize(n: usize) usize {
        return @sizeOf(NativeClosure) + n * @sizeOf(Value);
    }

    /// A new native closure whose `n` upvalues are nil.
    pub fn create(heap: *gc.Heap, f: Value.NativeFn, n: u8) error{OutOfMemory}!*NativeClosure {
        const mem = try heap.allocator().alignedAlloc(u8, .of(NativeClosure), allocSize(n));
        const c: *NativeClosure = @ptrCast(mem.ptr);
        c.* = .{ .header = undefined, .nupvalues = n, .f = f };
        @memset(c.upvalues(), Value.nil);
        heap.link(&c.header, .native_closure);
        return c;
    }

    pub fn destroy(heap: *gc.Heap, c: *NativeClosure) void {
        const p: [*]align(@alignOf(NativeClosure)) u8 = @ptrCast(c);
        heap.allocator().free(p[0..allocSize(c.nupvalues)]);
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
        const uv = try heap.allocator().create(Upval);
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
        heap.allocator().destroy(uv);
    }

    /// Removes an open upvalue from its thread's list.
    pub fn unlink(uv: *Upval) void {
        uv.open.prev.* = uv.open.next;
        if (uv.open.next) |n| n.open.prev = uv.open.prev;
    }
};
