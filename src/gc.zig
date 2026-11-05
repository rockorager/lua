//! The collector: precise, non-moving, incremental and generational, a
//! port of Lua 5.5.1's lgc.c function by function (plan decision 9,
//! `docs/slop/gc.md`). Every collectable object starts with a `Header` and
//! sits on one of the heap's object lists (`allgc`, `finobj` for objects
//! with a finalizer, `tobefnz` for those waiting to run it, `fixedgc` for
//! objects that live as long as the state); it is freed only here.
//! All memory the Lua universe uses goes through `Heap.allocator()`, which
//! counts bytes for pacing and `collectgarbage("count")`; objects take it
//! through `Heap.raw()`, which skips the safe build's fill.
//!
//! Colors are the reference's: white (two whites, flipped each cycle so
//! objects made during a sweep are not taken for dead), gray (reached, in a
//! gray list), and black. Black never points to white while marking; the
//! write barriers (`barrier`, `barrierBack`) keep that so marking can be
//! interleaved with the program. Gray objects link through their `gclist`
//! field, so marking never allocates.
//!
//! The collector runs only at safe points (`State.checkGc`) and on
//! request, never inside an allocation, so an object being built is never
//! seen half done. A step can run finalizers, which are Lua code.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Value = @import("Value.zig");
const String = @import("String.zig");
const Table = @import("Table.zig");
const Proto = @import("Proto.zig");
const Thread = @import("Thread.zig");
const Userdata = @import("Userdata.zig");
const State = @import("State.zig");
const vm = @import("vm.zig");

/// The header every collectable object starts with.
pub const Header = struct {
    /// The next object in the list the object is on.
    next: ?*Header,
    tag: Value.Tag,
    marked: u8,
};

/// Bits of `Header.marked`, lgc.h's layout: the age in generational mode,
/// two whites, black, and whether the object is marked for finalization.
pub const mark = struct {
    pub const age_bits: u8 = 0b111;
    pub const white0: u8 = 1 << 3;
    pub const white1: u8 = 1 << 4;
    pub const black: u8 = 1 << 5;
    pub const finalized: u8 = 1 << 6;
    pub const white_bits: u8 = white0 | white1;
    pub const colors: u8 = black | white_bits;
    pub const gc_bits: u8 = colors | age_bits;
};

/// Object ages in generational mode (lgc.h's comment explains them).
pub const age = struct {
    pub const new: u8 = 0;
    pub const survival: u8 = 1;
    pub const old0: u8 = 2;
    pub const old1: u8 = 3;
    pub const old: u8 = 4;
    pub const touched1: u8 = 5;
    pub const touched2: u8 = 6;
};

/// The collector's states, in lgc.h's order.
pub const Phase = enum(u8) {
    propagate,
    enter_atomic,
    atomic,
    swp_allgc,
    swp_finobj,
    swp_tobefnz,
    swp_end,
    call_fin,
    pause,
};

pub const Kind = enum(u8) { incremental, gen_minor, gen_major };

/// Bits of `Heap.stopped`: why the collector is not running.
pub const stop = struct {
    pub const user: u8 = 1;
    pub const internal: u8 = 2;
    pub const closing: u8 = 4;
};

/// `collectgarbage("param")`'s parameters, in `lua.h`'s order.
pub const Param = enum(u3) { minormul, majorminor, minormajor, pause, stepmul, stepsize };

/// lgc.h's defaults. The step size is in bytes: 200 of the reference's
/// 48-byte tables, so `collectgarbage("param", "stepsize")` reads the same.
const default_params = [6]u8{
    codeParam(20), codeParam(50), codeParam(70), codeParam(250), codeParam(200), codeParam(200 * 48),
};

/// Most objects one sweep step visits, `GCSWEEPMAX`.
const sweep_max = 20;
/// Work units charged for running one finalizer, `CWUFIN`.
const finalizer_cost = 10;
const max_mem: isize = std.math.maxInt(isize);

/// The collector's state and the allocator that counts every byte.
pub const Heap = struct {
    backing: Allocator,
    /// Where strings and string buffers come from, when not `backing`:
    /// `State.Options.strings`.
    strings: ?Allocator = null,
    /// Bytes currently allocated through `allocator()`.
    bytes: usize = 0,
    /// A step runs once `bytes` reaches this: `bytes - threshold` is
    /// lgc.c's debt. Zero, so the first safe point starts a cycle.
    threshold: usize = 0,

    allgc: ?*Header = null,
    finobj: ?*Header = null,
    tobefnz: ?*Header = null,
    fixedgc: ?*Header = null,
    /// Generational boundaries in `allgc`: survival objects start here,
    /// then old1, then really old ones.
    survival: ?*Header = null,
    old1: ?*Header = null,
    reallyold: ?*Header = null,
    /// The first OLD1 object in the list, if any.
    firstold1: ?*Header = null,
    finobjsur: ?*Header = null,
    finobjold1: ?*Header = null,
    finobjrold: ?*Header = null,
    /// Where the incremental sweep goes on.
    sweepgc: ?*?*Header = null,

    gray: ?*Header = null,
    grayagain: ?*Header = null,
    /// Tables with weak values to clear.
    weak: ?*Header = null,
    /// Ephemeron tables with white keys pointing at white values.
    ephemeron: ?*Header = null,
    /// Tables with weak keys or both to clear.
    allweak: ?*Header = null,
    /// Threads with open upvalues, linked through `Thread.twups`.
    twups: ?*Thread = null,

    phase: Phase = .pause,
    kind: Kind = .incremental,
    currentwhite: u8 = mark.white0,
    /// `stop` bits; the collector runs only when this is zero.
    stopped: u8 = 0,
    emergency: bool = false,
    /// lgc.c's GCmarked: bytes marked in this cycle (incremental), or bytes
    /// that became old since the last major collection (generational).
    marked: isize = 0,
    /// Bytes marked in the last major collection.
    majorminor: isize = 0,
    params: [6]u8 = default_params,
    /// Completed cycles, major and minor.
    cycles: usize = 0,
    /// Run a full collection at every safe point, to shake out missing
    /// roots in tests.
    stress: bool = false,
    /// Run one incremental step at every safe point, so marking interleaves
    /// with the program as finely as it can: shakes out missing barriers.
    stress_step: bool = false,

    /// The counting allocator. Every byte of a Lua universe goes through it
    /// or `stringAllocator`.
    pub fn allocator(heap: *Heap) Allocator {
        return .{ .ptr = heap, .vtable = &Counting("backing").vtable };
    }

    /// The counting allocator for strings and the buffers that become
    /// them.
    pub fn stringAllocator(heap: *Heap) Allocator {
        if (heap.strings == null) return heap.allocator();
        return .{ .ptr = heap, .vtable = &Counting("strings").vtable };
    }

    /// The counting allocator through `Raw`, for objects and the blocks
    /// they own.
    pub fn raw(heap: *Heap) Raw {
        return .{ .a = heap.allocator() };
    }

    /// The strings' counting allocator through `Raw`.
    pub fn rawStrings(heap: *Heap) Raw {
        return .{ .a = heap.stringAllocator() };
    }

    /// Links a new object into `allgc`, white and new.
    pub fn link(heap: *Heap, h: *Header, tag: Value.Tag) void {
        h.* = .{ .next = heap.allgc, .tag = tag, .marked = heap.currentwhite & mark.white_bits };
        heap.allgc = h;
    }

    /// Whether `h` was found unreachable in this cycle and awaits its sweep.
    pub inline fn isDead(heap: *const Heap, h: *const Header) bool {
        return h.marked & (heap.currentwhite ^ mark.white_bits) != 0;
    }

    /// Brings a dead object back, for the string interner (lstring.c's
    /// `changewhite`).
    pub inline fn resurrect(h: *Header) void {
        h.marked ^= mark.white_bits;
    }

    pub inline fn param(heap: *const Heap, p: Param, x: isize) isize {
        return applyParam(heap.params[@backingInt(p)], x);
    }

    /// `luaE_setdebt`: the next step after `debt` more bytes (or at the
    /// next safe point, when it is not positive, and always under stress).
    pub fn setDebt(heap: *Heap, new_debt: isize) void {
        const tb: isize = @intCast(heap.bytes);
        const d = if (heap.stress or heap.stress_step) 0 else @min(new_debt, max_mem - tb);
        heap.threshold = @intCast(@max(tb + d, 0));
    }

    /// lgc.c's GCdebt: bytes left before the next step.
    pub fn debt(heap: *const Heap) isize {
        return @as(isize, @intCast(heap.threshold)) - @as(isize, @intCast(heap.bytes));
    }

    pub inline fn running(heap: *const Heap) bool {
        return heap.stopped == 0;
    }

    /// An allocator over the heap's `field` that counts the bytes.
    fn Counting(comptime field: []const u8) type {
        return struct {
            const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

            inline fn backingOf(heap: *Heap) Allocator {
                const a = @field(heap, field);
                return if (@TypeOf(a) == Allocator) a else a.?;
            }

            fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
                const heap: *Heap = @ptrCast(@alignCast(ctx));
                const p = backingOf(heap).rawAlloc(len, alignment, ret) orelse return null;
                heap.bytes += len;
                return p;
            }

            fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
                const heap: *Heap = @ptrCast(@alignCast(ctx));
                if (!backingOf(heap).rawResize(memory, alignment, new_len, ret)) return false;
                heap.bytes = heap.bytes - memory.len + new_len;
                return true;
            }

            fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
                const heap: *Heap = @ptrCast(@alignCast(ctx));
                const p = backingOf(heap).rawRemap(memory, alignment, new_len, ret) orelse return null;
                heap.bytes = heap.bytes - memory.len + new_len;
                return p;
            }

            fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
                const heap: *Heap = @ptrCast(@alignCast(ctx));
                backingOf(heap).rawFree(memory, alignment, ret);
                heap.bytes -= memory.len;
            }
        };
    }
};

/// `std.mem.Allocator`'s calls for objects and the blocks they own, minus
/// the `undefined` fill: in safe builds the standard interface writes 0xAA
/// over every block it allocates and frees, which was half of ReleaseSafe's
/// cost and all of its extra peak memory
/// (`docs/slop/results/safe-poison-20261031.md`). Every object is
/// initialized before anything can reach it and freed only once nothing
/// can, so nothing reads the fill; Debug builds still write it.
pub const Raw = struct {
    a: Allocator,

    inline fn fill(bytes: []u8) void {
        if (builtin.mode == .debug) @memset(bytes, undefined);
    }

    pub fn create(r: Raw, comptime T: type) Allocator.Error!*T {
        const p = r.a.rawAlloc(@sizeOf(T), .of(T), @returnAddress()) orelse return error.OutOfMemory;
        fill(p[0..@sizeOf(T)]);
        return @ptrCast(@alignCast(p));
    }

    pub fn destroy(r: Raw, ptr: anytype) void {
        const T = @typeInfo(@TypeOf(ptr)).pointer.child;
        const p: [*]u8 = @ptrCast(@constCast(ptr));
        fill(p[0..@sizeOf(T)]);
        r.a.rawFree(p[0..@sizeOf(T)], .of(T), @returnAddress());
    }

    pub fn alloc(r: Raw, comptime T: type, n: usize) Allocator.Error![]T {
        return r.alignedAlloc(T, null, n);
    }

    pub fn alignedAlloc(
        r: Raw,
        comptime T: type,
        comptime alignment: ?std.mem.Alignment,
        n: usize,
    ) Allocator.Error![]align(if (alignment) |a| a.toByteUnits() else @alignOf(T)) T {
        const a = comptime alignment orelse std.mem.Alignment.of(T);
        const Ptr = [*]align(a.toByteUnits()) T;
        const len = std.math.mul(usize, @sizeOf(T), n) catch return error.OutOfMemory;
        if (len == 0) return @as(Ptr, @ptrFromInt(comptime a.backward(std.math.maxInt(usize))))[0..n];
        const p = r.a.rawAlloc(len, a, @returnAddress()) orelse return error.OutOfMemory;
        fill(p[0..len]);
        return @as(Ptr, @ptrCast(@alignCast(p)))[0..n];
    }

    pub fn free(r: Raw, memory: anytype) void {
        const info = @typeInfo(@TypeOf(memory)).pointer;
        const bytes: []u8 = @ptrCast(@constCast(memory));
        if (bytes.len == 0) return;
        fill(bytes);
        r.a.rawFree(bytes, .fromByteUnits(info.attrs.@"align" orelse @alignOf(info.child)), @returnAddress());
    }

    /// `Allocator.realloc`: in place when the allocator can, else a new
    /// block with the contents copied.
    pub fn realloc(r: Raw, old: anytype, n: usize) Allocator.Error!@TypeOf(old) {
        const info = @typeInfo(@TypeOf(old)).pointer;
        const T = info.child;
        const a = comptime std.mem.Alignment.fromByteUnits(info.attrs.@"align" orelse @alignOf(T));
        if (old.len == 0) return r.alignedAlloc(T, a, n);
        if (n == 0) {
            r.free(old);
            return r.alignedAlloc(T, a, 0);
        }
        const old_bytes: []u8 = @ptrCast(old);
        const len = std.math.mul(usize, @sizeOf(T), n) catch return error.OutOfMemory;
        const p = r.a.rawRemap(old_bytes, a, len, @returnAddress()) orelse blk: {
            const q = r.a.rawAlloc(len, a, @returnAddress()) orelse return error.OutOfMemory;
            @memcpy(q[0..@min(len, old_bytes.len)], old_bytes[0..@min(len, old_bytes.len)]);
            r.free(old);
            break :blk q;
        };
        return @as([*]align(a.toByteUnits()) T, @ptrCast(@alignCast(p)))[0..n];
    }
};

/// `luaO_codeparam`: a percentage as the reference's floating-point byte,
/// four bits of mantissa and four of exponent.
pub fn codeParam(p_in: u32) u8 {
    if (p_in >= (@as(u64, 0x1F) << (0xF - 7 - 1)) * 100) return 0xFF;
    const p: u32 = @intCast((@as(u64, p_in) * 128 + 99) / 100);
    if (p < 0x10) return @intCast(p);
    const log: u5 = @intCast(32 - @clz(p) - 5);
    return @intCast(((p >> log) - 0x10) | (@as(u32, log) + 1) << 4);
}

/// `luaO_applyparam`: `x` times the percentage coded in `p`, saturating.
pub fn applyParam(p: u8, x: isize) isize {
    var m: isize = p & 0xF;
    var e: i32 = p >> 4;
    if (e > 0) {
        e -= 1;
        m += 0x10;
    }
    e -= 7;
    if (e >= 0) {
        const s: u6 = @intCast(e);
        return if (x < (max_mem / 0x1F) >> s) (x * m) << s else max_mem;
    }
    const s: u6 = @intCast(-e);
    if (x < max_mem / 0x1F) return (x * m) >> s;
    if ((x >> s) < max_mem / 0x1F) return (x >> s) * m;
    return max_mem;
}

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

inline fn isWhite(h: *const Header) bool {
    return h.marked & mark.white_bits != 0;
}

inline fn isBlack(h: *const Header) bool {
    return h.marked & mark.black != 0;
}

inline fn isGray(h: *const Header) bool {
    return h.marked & mark.colors == 0;
}

inline fn getAge(h: *const Header) u8 {
    return h.marked & mark.age_bits;
}

inline fn setAge(h: *Header, a: u8) void {
    h.marked = (h.marked & ~mark.age_bits) | a;
}

inline fn isOld(h: *const Header) bool {
    return getAge(h) > age.survival;
}

inline fn set2gray(h: *Header) void {
    h.marked &= ~mark.colors;
}

inline fn set2black(h: *Header) void {
    h.marked = (h.marked & ~mark.white_bits) | mark.black;
}

inline fn nw2black(h: *Header) void {
    std.debug.assert(!isWhite(h));
    h.marked |= mark.black;
}

inline fn makeWhite(heap: *const Heap, h: *Header) void {
    h.marked = (h.marked & ~mark.colors) | (heap.currentwhite & mark.white_bits);
}

inline fn otherWhite(heap: *const Heap) u8 {
    return heap.currentwhite ^ mark.white_bits;
}

inline fn keepInvariant(heap: *const Heap) bool {
    return @backingInt(heap.phase) <= @backingInt(Phase.atomic);
}

inline fn isSweepPhase(heap: *const Heap) bool {
    const p = @backingInt(heap.phase);
    return p >= @backingInt(Phase.swp_allgc) and p <= @backingInt(Phase.swp_end);
}

// ---------------------------------------------------------------------------
// Barriers
// ---------------------------------------------------------------------------

/// The write barrier for a store of `v` into the object `parent` (an
/// upvalue, a closure, a userdata's user value or metatable, a table's
/// metatable): marks `v` if `parent` is black (`luaC_barrier`).
pub inline fn barrier(heap: *Heap, parent: *Header, v: Value) void {
    if (v.isCollectable() and isBlack(parent) and isWhite(v.payload.gc)) barrierSlow(heap, parent, v.payload.gc);
}

/// The backward write barrier for a store of `v` into table `t`: turns a
/// black `t` gray again, to be revisited (`luaC_barrierback`).
pub inline fn barrierBack(heap: *Heap, t: *Table, v: Value) void {
    if (v.isCollectable() and isBlack(&t.header) and isWhite(v.payload.gc)) barrierBackSlow(heap, &t.header);
}

/// `luaC_barrier_`.
noinline fn barrierSlow(heap: *Heap, o: *Header, v: *Header) void {
    if (keepInvariant(heap)) {
        reallyMarkObject(heap, v);
        if (isOld(o)) setAge(v, age.old0);
    } else if (heap.kind != .gen_minor) {
        // Sweeping: whiten `o` so it causes no more barriers.
        makeWhite(heap, o);
    }
}

/// `luaC_barrierback_`.
noinline fn barrierBackSlow(heap: *Heap, o: *Header) void {
    if (getAge(o) == age.touched2) {
        set2gray(o);
    } else {
        linkGray(o, &heap.grayagain);
    }
    if (isOld(o)) setAge(o, age.touched1);
}

/// What closing an open upvalue owes the collector (`luaF_closeupval`):
/// closed upvalues are black or white, never gray.
pub fn closeUpval(heap: *Heap, uv: *Proto.Upval) void {
    if (!isWhite(&uv.header)) {
        nw2black(&uv.header);
        barrier(heap, &uv.header, uv.closed);
    }
}

/// Puts a thread that just got its first open upvalue on the list
/// `remarkUpvals` walks (lfunc.c's `newupval`).
pub fn linkTwups(heap: *Heap, th: *Thread) void {
    if (th.twups == th) {
        th.twups = heap.twups;
        heap.twups = th;
    }
}

/// Moves the newest object to the fixed list: never collected, gray
/// forever (`luaC_fix`).
pub fn fix(heap: *Heap, h: *Header) void {
    std.debug.assert(heap.allgc == h);
    set2gray(h);
    setAge(h, age.old);
    heap.allgc = h.next;
    h.next = heap.fixedgc;
    heap.fixedgc = h;
}

// ---------------------------------------------------------------------------
// Marking
// ---------------------------------------------------------------------------

/// The bytes an object holds, for pacing (lgc.c's `objsize`).
fn objSize(h: *Header) usize {
    return switch (h.tag) {
        .table => @as(*Table, @fieldParentPtr("header", h)).byteSize(),
        .lua_closure => Proto.LuaClosure.allocSize(Value.object(h).asLuaClosure().nupvalues),
        .native_closure => Proto.NativeClosure.allocSize(Value.object(h).asNativeClosure().nupvalues),
        .userdata => @as(*Userdata, @fieldParentPtr("header", h)).byteSize(),
        .proto => @as(*Proto, @fieldParentPtr("header", h)).byteSize(),
        .thread => threadSize(@fieldParentPtr("header", h)),
        .short_string, .long_string => @sizeOf(String) + @as(*String, @fieldParentPtr("header", h)).len() + 1,
        .upval => @sizeOf(Proto.Upval),
        else => unreachable,
    };
}

fn threadSize(th: *Thread) usize {
    return @sizeOf(Thread) + th.stack.len * @sizeOf(Value) + th.frames.capacity * @sizeOf(Thread.Frame) +
        th.tbc.capacity * @sizeOf(u32);
}

fn gclist(h: *Header) *?*Header {
    return switch (h.tag) {
        .table => &@as(*Table, @fieldParentPtr("header", h)).gclist,
        .lua_closure => &@as(*Proto.LuaClosure, @fieldParentPtr("header", h)).gclist,
        .native_closure => &@as(*Proto.NativeClosure, @fieldParentPtr("header", h)).gclist,
        .proto => &@as(*Proto, @fieldParentPtr("header", h)).gclist,
        .thread => &@as(*Thread, @fieldParentPtr("header", h)).gclist,
        .userdata => &@as(*Userdata, @fieldParentPtr("header", h)).gclist,
        else => unreachable,
    };
}

/// Links `h` into a gray list and makes it gray.
fn linkGray(h: *Header, list: *?*Header) void {
    std.debug.assert(!isGray(h));
    gclist(h).* = list.*;
    list.* = h;
    set2gray(h);
}

inline fn markValue(heap: *Heap, v: Value) void {
    if (v.isCollectable() and isWhite(v.payload.gc)) reallyMarkObject(heap, v.payload.gc);
}

inline fn markObject(heap: *Heap, h: *Header) void {
    if (isWhite(h)) reallyMarkObject(heap, h);
}

inline fn markTable(heap: *Heap, t: ?*Table) void {
    if (t) |p| markObject(heap, &p.header);
}

inline fn markString(heap: *Heap, s: ?*String) void {
    if (s) |p| markObject(heap, &p.header);
}

/// Strings and closed upvalues are done here; userdata without user
/// values too. Open upvalues stay gray: their thread marks their values.
/// Everything else goes to the gray list (`reallymarkobject`).
fn reallyMarkObject(heap: *Heap, h: *Header) void {
    heap.marked += @intCast(objSize(h));
    switch (h.tag) {
        .short_string, .long_string => set2black(h),
        .upval => {
            const uv = Proto.Upval.fromHeader(h);
            if (uv.isOpen()) set2gray(h) else set2black(h);
            markValue(heap, uv.v.*);
        },
        .userdata => {
            const u: *Userdata = @fieldParentPtr("header", h);
            if (u.nuvalue == 0) {
                markTable(heap, u.metatable);
                set2black(h);
            } else {
                linkGray(h, &heap.gray);
            }
        },
        else => linkGray(h, &heap.gray),
    }
}

fn markMetatables(state: *State) void {
    for (state.metatables) |mt| markTable(&state.heap, mt);
}

fn markBeingFinalized(heap: *Heap) void {
    var it = heap.tobefnz;
    while (it) |h| : (it = h.next) markObject(heap, h);
}

/// For each unmarked thread, marks the values of its marked open upvalues
/// (it may be dead, and then nothing else would), and drops threads that
/// are unmarked or have no open upvalues from the list.
fn remarkUpvals(heap: *Heap) void {
    var p: *?*Thread = &heap.twups;
    while (p.*) |th| {
        if (!isWhite(&th.header) and th.open_upvals != null) {
            p = &th.twups;
        } else {
            p.* = th.twups;
            th.twups = th;
            var it = th.open_upvals;
            while (it) |uv| : (it = uv.open.next) {
                if (!isWhite(&uv.header)) markValue(heap, uv.v.*);
            }
        }
    }
}

fn clearGrayLists(heap: *Heap) void {
    heap.gray = null;
    heap.grayagain = null;
    heap.weak = null;
    heap.allweak = null;
    heap.ephemeron = null;
}

fn restartCollection(state: *State) void {
    const heap = &state.heap;
    clearGrayLists(heap);
    heap.marked = 0;
    markObject(heap, &state.main.header);
    markObject(heap, &state.registry.header);
    markObject(heap, &state.globals.header);
    markMetatables(state);
    markBeingFinalized(heap);
}

// ---------------------------------------------------------------------------
// Traversal
// ---------------------------------------------------------------------------

/// Generational mode: a TOUCHED1 object goes back to `grayagain`; TOUCHED2
/// becomes old.
fn genLink(heap: *Heap, h: *Header) void {
    std.debug.assert(isBlack(h));
    switch (getAge(h)) {
        age.touched1 => linkGray(h, &heap.grayagain),
        age.touched2 => setAge(h, age.old),
        else => {},
    }
}

/// A key whose value is nil stops holding its object but stays for `next`.
inline fn clearKey(n: *Table.Node) void {
    if (n.key_tag.isCollectable()) n.key_tag = .dead_key;
}

inline fn markKey(heap: *Heap, n: *const Table.Node) void {
    if (n.key_tag.isCollectable() and isWhite(n.key.gc)) reallyMarkObject(heap, n.key.gc);
}

/// Whether a weak entry holding `v` must go: never for non-collectable
/// values or strings (which are values, and get marked), else when white.
fn isCleared(heap: *Heap, v: Value) bool {
    if (!v.isCollectable()) return false;
    if (v.isString()) {
        markObject(heap, v.payload.gc);
        return false;
    }
    return isWhite(v.payload.gc);
}

inline fn valIsWhite(v: Value) bool {
    return v.isCollectable() and isWhite(v.payload.gc);
}

fn traverseWeakValue(heap: *Heap, t: *Table) void {
    // Assume an array part may have white values; checking costs as much.
    var hasclears = t.asize > 0;
    for (t.nodes()) |*n| {
        if (n.val_tag == .nil) {
            clearKey(n);
        } else {
            markKey(heap, n);
            if (!hasclears and isCleared(heap, n.value())) hasclears = true;
        }
    }
    if (heap.phase == .propagate) {
        linkGray(&t.header, &heap.grayagain);
    } else if (hasclears) {
        linkGray(&t.header, &heap.weak);
    } else {
        genLink(heap, &t.header);
    }
}

fn traverseArray(heap: *Heap, t: *Table) bool {
    var marked = false;
    for (0..t.asize) |i| {
        const v = t.arrayGet(@intCast(i));
        if (valIsWhite(v)) {
            marked = true;
            reallyMarkObject(heap, v.payload.gc);
        }
    }
    return marked;
}

/// Marks values whose keys are marked; returns whether it marked anything
/// (`traverseephemeron`). `inv` walks the nodes backwards.
fn traverseEphemeron(heap: *Heap, t: *Table, inv: bool) bool {
    var hasclears = false;
    var hasww = false;
    var marked = traverseArray(heap, t);
    const ns = t.nodes();
    for (0..ns.len) |i| {
        const n = &ns[if (inv) ns.len - 1 - i else i];
        if (n.val_tag == .nil) {
            clearKey(n);
        } else if (isCleared(heap, n.keyValue())) {
            hasclears = true;
            if (valIsWhite(n.value())) hasww = true;
        } else if (valIsWhite(n.value())) {
            marked = true;
            reallyMarkObject(heap, n.val.gc);
        }
    }
    if (heap.phase == .propagate) {
        linkGray(&t.header, &heap.grayagain);
    } else if (hasww) {
        linkGray(&t.header, &heap.ephemeron);
    } else if (hasclears) {
        linkGray(&t.header, &heap.allweak);
    } else {
        genLink(heap, &t.header);
    }
    return marked;
}

fn traverseStrongTable(heap: *Heap, t: *Table) void {
    _ = traverseArray(heap, t);
    for (t.nodes()) |*n| {
        if (n.val_tag == .nil) {
            clearKey(n);
        } else {
            markKey(heap, n);
            markValue(heap, n.value());
        }
    }
    genLink(heap, &t.header);
}

/// Bit 0: weak values; bit 1: weak keys (`getmode`).
fn weakMode(state: *State, t: *Table) u2 {
    const mode = state.fastTm(t.metatable, .mode) orelse return 0;
    if (!mode.isString()) return 0;
    var b = mode.asString().bytes();
    // As `strchr` sees the string.
    if (std.mem.findScalar(u8, b, 0)) |z| b = b[0..z];
    return @as(u2, @intFromBool(std.mem.findScalar(u8, b, 'k') != null)) << 1 |
        @intFromBool(std.mem.findScalar(u8, b, 'v') != null);
}

fn traverseTable(state: *State, t: *Table) usize {
    const heap = &state.heap;
    markTable(heap, t.metatable);
    switch (weakMode(state, t)) {
        0 => traverseStrongTable(heap, t),
        1 => traverseWeakValue(heap, t),
        2 => _ = traverseEphemeron(heap, t, false),
        3 => if (heap.phase == .propagate) {
            linkGray(&t.header, &heap.grayagain);
        } else {
            linkGray(&t.header, &heap.allweak);
        },
    }
    return 1 + 2 * t.nodes().len + t.asize;
}

fn traverseUserdata(heap: *Heap, u: *Userdata) usize {
    markTable(heap, u.metatable);
    for (u.userValues()) |v| markValue(heap, v);
    genLink(heap, &u.header);
    return 1 + u.nuvalue;
}

fn traverseProto(heap: *Heap, p: *Proto) usize {
    markString(heap, p.source);
    for (p.k) |v| markValue(heap, v);
    for (p.upvalues) |u| markString(heap, u.name);
    for (p.p) |child| markObject(heap, &child.header);
    for (p.locvars) |l| markString(heap, l.name);
    return 1 + p.k.len + p.upvalues.len + p.p.len + p.locvars.len;
}

fn traverseNativeClosure(heap: *Heap, c: *Proto.NativeClosure) usize {
    for (c.upvalues()) |v| markValue(heap, v);
    return 1 + c.nupvalues;
}

fn traverseLuaClosure(heap: *Heap, c: *Proto.LuaClosure) usize {
    markObject(heap, &c.proto.header);
    for (c.upvals()) |uv| markObject(heap, &uv.header);
    return 1 + c.nupvalues;
}

/// Marks a thread's stack below `top`, as the reference does: the running
/// thread's `top` is exact at every safe point, and every other thread's
/// innermost frame is a native one (a resume or a yield). In the atomic
/// phase the slots above it become nil, so no stale slot keeps a pointer
/// to a freed object. Threads have no barriers: an old thread, or one
/// traversed while propagating, goes back to `grayagain`.
fn traverseThread(heap: *Heap, th: *Thread) usize {
    if (isOld(&th.header) or heap.phase == .propagate) linkGray(&th.header, &heap.grayagain);
    const top = th.top;
    for (th.stack[0..top]) |v| markValue(heap, v);
    var it = th.open_upvals;
    while (it) |uv| : (it = uv.open.next) markObject(heap, &uv.header);
    markValue(heap, th.err);
    if (heap.phase == .atomic) {
        @memset(th.stack[top..], Value.nil);
        if (th.twups == th and th.open_upvals != null) {
            th.twups = heap.twups;
            heap.twups = th;
        }
    }
    return 1 + top;
}

/// Traverses one gray object, turning it black; returns the work done.
fn propagateMark(state: *State) usize {
    const heap = &state.heap;
    const h = heap.gray.?;
    nw2black(h);
    heap.gray = gclist(h).*;
    return switch (h.tag) {
        .table => traverseTable(state, @fieldParentPtr("header", h)),
        .userdata => traverseUserdata(heap, @fieldParentPtr("header", h)),
        .lua_closure => traverseLuaClosure(heap, @fieldParentPtr("header", h)),
        .native_closure => traverseNativeClosure(heap, @fieldParentPtr("header", h)),
        .proto => traverseProto(heap, @fieldParentPtr("header", h)),
        .thread => traverseThread(heap, @fieldParentPtr("header", h)),
        else => unreachable,
    };
}

fn propagateAll(state: *State) void {
    while (state.heap.gray != null) _ = propagateMark(state);
}

/// Traverses the ephemeron tables until nothing new is marked, alternating
/// direction to speed up chains within one table.
fn convergeEphemerons(state: *State) void {
    const heap = &state.heap;
    var dir = false;
    while (true) {
        var next = heap.ephemeron;
        heap.ephemeron = null;
        var changed = false;
        while (next) |w| {
            const t: *Table = @fieldParentPtr("header", w);
            next = t.gclist;
            nw2black(w);
            if (traverseEphemeron(heap, t, dir)) {
                propagateAll(state);
                changed = true;
            }
        }
        dir = !dir;
        if (!changed) break;
    }
}

// ---------------------------------------------------------------------------
// Clearing weak tables
// ---------------------------------------------------------------------------

/// Removes entries with unmarked keys from every table in list `l`.
fn clearByKeys(heap: *Heap, l: ?*Header) void {
    var it = l;
    while (it) |h| {
        const t: *Table = @fieldParentPtr("header", h);
        for (t.nodes()) |*n| {
            if (isCleared(heap, n.keyValue())) n.val_tag = .nil;
            if (n.val_tag == .nil) clearKey(n);
        }
        it = t.gclist;
    }
}

/// Removes entries with unmarked values from the tables in list `l` up to
/// `f`.
fn clearByValues(heap: *Heap, l: ?*Header, f: ?*Header) void {
    var it = l;
    while (it != f) {
        const t: *Table = @fieldParentPtr("header", it.?);
        for (0..t.asize) |i| {
            if (isCleared(heap, t.arrayGet(@intCast(i)))) t.clearArraySlot(@intCast(i));
        }
        for (t.nodes()) |*n| {
            if (isCleared(heap, n.value())) n.val_tag = .nil;
            if (n.val_tag == .nil) clearKey(n);
        }
        it = t.gclist;
    }
}

// ---------------------------------------------------------------------------
// Sweeping
// ---------------------------------------------------------------------------

/// Frees one object found dead and everything it owns.
fn freeObject(state: *State, h: *Header) void {
    if (h.tag == .short_string) state.strings.remove(@fieldParentPtr("header", h));
    destroyObject(&state.heap, h);
}

fn destroyObject(heap: *Heap, h: *Header) void {
    switch (h.tag) {
        .short_string, .long_string => String.destroy(heap, @fieldParentPtr("header", h)),
        .table => Table.destroy(heap, @fieldParentPtr("header", h)),
        .lua_closure => Proto.LuaClosure.destroy(heap, @fieldParentPtr("header", h)),
        .native_closure => Proto.NativeClosure.destroy(heap, @fieldParentPtr("header", h)),
        .proto => Proto.destroy(heap, @fieldParentPtr("header", h)),
        .upval => Proto.Upval.destroy(heap, Proto.Upval.fromHeader(h)),
        .thread => Thread.destroy(heap, @fieldParentPtr("header", h)),
        .userdata => Userdata.destroy(heap, @fieldParentPtr("header", h)),
        else => unreachable,
    }
}

/// Sweeps at most `count` objects of a list: frees the dead (the other
/// white) and turns the rest white and new. Returns where to go on, or
/// null at the end of the list.
fn sweepList(state: *State, p_in: *?*Header, count_in: usize) ?*?*Header {
    const heap = &state.heap;
    const ow = otherWhite(heap);
    const white = heap.currentwhite & mark.white_bits;
    var p = p_in;
    var count = count_in;
    while (p.*) |curr| {
        if (count == 0) break;
        count -= 1;
        if (curr.marked & ow != 0) {
            p.* = curr.next;
            freeObject(state, curr);
        } else {
            curr.marked = (curr.marked & ~mark.gc_bits) | white | age.new;
            p = &curr.next;
        }
    }
    return if (p.* == null) null else p;
}

/// Sweeps until a live object or the end of the list.
fn sweepToLive(state: *State, p_in: *?*Header) ?*?*Header {
    var p: ?*?*Header = p_in;
    while (true) {
        const old = p;
        p = sweepList(state, p.?, 1);
        if (p != old) return p;
    }
}

// ---------------------------------------------------------------------------
// Finalization
// ---------------------------------------------------------------------------

/// Shrinks the string table when it is mostly empty (`checkSizes`).
fn checkSizes(state: *State) void {
    if (!state.heap.emergency) state.strings.shrink(&state.heap);
}

/// Takes the first object to finalize back to `allgc` (`udata2finalize`).
fn udata2finalize(heap: *Heap) *Header {
    const o = heap.tobefnz.?;
    std.debug.assert(o.marked & mark.finalized != 0);
    heap.tobefnz = o.next;
    o.next = heap.allgc;
    heap.allgc = o;
    o.marked &= ~mark.finalized;
    if (isSweepPhase(heap)) {
        makeWhite(heap, o);
    } else if (getAge(o) == age.old1) {
        heap.firstold1 = o;
    }
    return o;
}

/// Whether `th` can run a finalizer now (`luaD_checkminstack`): room for
/// nested native calls, in levels and in native stack, and a basic stack.
fn checkMinStack(th: *Thread) bool {
    if (th.native_calls >= Thread.max_native_calls - 2) return false;
    if (th.state.nearStackLimit(Thread.max_native_stack / 100)) return false;
    const old_top = th.top;
    defer th.top = old_top;
    th.top = finalizerTop(th);
    return vm.checkStack(th, 2 * Thread.min_stack) catch false;
}

/// Where a finalizer's call goes: above every register of a running Lua
/// frame, which `top` does not bound.
fn finalizerTop(th: *Thread) u32 {
    const f = th.frame();
    return if (f.flags.lua) @max(th.top, f.top) else th.top;
}

/// Runs the finalizer of the next object in `tobefnz`, in protected mode,
/// with the collector and hooks stopped; an error becomes the warning
/// "error in __gc" (`GCTM`).
fn callFinalizer(state: *State, th: *Thread) void {
    const heap = &state.heap;
    const v = Value.object(udata2finalize(heap));
    const tm = state.tmOf(v, .gc) orelse return;
    const old_stopped = heap.stopped;
    const old_allowhook = th.allowhook;
    heap.stopped |= stop.internal;
    // No hooks inside a finalizer.
    th.allowhook = false;
    const old_top = th.top;
    th.top = finalizerTop(th);
    const func = th.top;
    th.push(tm);
    th.push(v);
    const caller = th.frames.items.len - 1;
    th.frames.items[caller].flags.fin = true;
    const status = vm.pcall(th, func, 0);
    th.frames.items[caller].flags.fin = false;
    th.allowhook = old_allowhook;
    heap.stopped = old_stopped;
    if (status != .ok) warnError(state, th.stack[func], "__gc");
    th.top = old_top;
}

/// `luaE_warnerror`: "error in WHERE (MSG)" from an error object.
pub fn warnError(state: *State, err: Value, where: []const u8) void {
    const warnf = state.warnf orelse return;
    const msg = if (err.isString()) err.asString().bytes() else "error object is not a string";
    warnf(state, "error in ", true);
    warnf(state, where, true);
    warnf(state, " (", true);
    warnf(state, msg, true);
    warnf(state, ")", false);
}

fn callAllPendingFinalizers(state: *State, th: *Thread) void {
    while (state.heap.tobefnz != null) callFinalizer(state, th);
}

fn findLast(p_in: *?*Header) *?*Header {
    var p = p_in;
    while (p.*) |h| p = &h.next;
    return p;
}

/// Moves the unreachable objects with finalizers (or all of them) from
/// `finobj` to the end of `tobefnz`, keeping their order.
fn separateToBeFinalized(heap: *Heap, all: bool) void {
    var p: *?*Header = &heap.finobj;
    var lastnext = findLast(&heap.tobefnz);
    while (p.* != heap.finobjold1) {
        const curr = p.*.?;
        std.debug.assert(curr.marked & mark.finalized != 0);
        if (!(isWhite(curr) or all)) {
            p = &curr.next;
        } else {
            if (curr == heap.finobjsur) heap.finobjsur = curr.next;
            p.* = curr.next;
            curr.next = lastnext.*;
            lastnext.* = curr;
            lastnext = &curr.next;
        }
    }
}

inline fn checkPointer(p: *?*Header, o: *Header) void {
    if (p.* == o) p.* = o.next;
}

fn correctPointers(heap: *Heap, o: *Header) void {
    checkPointer(&heap.survival, o);
    checkPointer(&heap.old1, o);
    checkPointer(&heap.reallyold, o);
    checkPointer(&heap.firstold1, o);
}

/// If `mt` has `__gc`, moves `o` (a table or userdata that just got `mt`
/// as its metatable) from `allgc` to `finobj`, marking it for
/// finalization (`luaC_checkfinalizer`). A `__gc` field added to the
/// metatable later does not count.
pub fn checkFinalizer(state: *State, o: *Header, mt: ?*Table) void {
    const heap = &state.heap;
    if (o.marked & mark.finalized != 0 or state.fastTm(mt, .gc) == null or heap.stopped & stop.closing != 0) return;
    if (isSweepPhase(heap)) {
        makeWhite(heap, o);
        if (heap.sweepgc == &o.next) heap.sweepgc = sweepToLive(state, heap.sweepgc.?);
    } else {
        correctPointers(heap, o);
    }
    var p: *?*Header = &heap.allgc;
    while (p.* != o) p = &p.*.?.next;
    p.* = o.next;
    o.next = heap.finobj;
    heap.finobj = o;
    o.marked |= mark.finalized;
}

// ---------------------------------------------------------------------------
// Generational mode
// ---------------------------------------------------------------------------

/// The next cycle starts when the heap reaches `pause` percent of what
/// the last one marked.
fn setPause(heap: *Heap) void {
    const threshold = heap.param(.pause, heap.marked);
    const d = threshold - @as(isize, @intCast(heap.bytes));
    heap.setDebt(@max(d, 0));
}

/// Sweeps a list to enter generational mode: frees the dead and makes
/// everything else old. Threads go to `grayagain`; open upvalues stay gray.
fn sweep2old(state: *State, p_in: *?*Header) void {
    const heap = &state.heap;
    var p = p_in;
    while (p.*) |curr| {
        if (isWhite(curr)) {
            p.* = curr.next;
            freeObject(state, curr);
        } else {
            setAge(curr, age.old);
            if (curr.tag == .thread) {
                linkGray(curr, &heap.grayagain);
            } else if (curr.tag == .upval and Proto.Upval.fromHeader(curr).isOpen()) {
                set2gray(curr);
            } else {
                nw2black(curr);
            }
            p = &curr.next;
        }
    }
}

/// The generational sweep from `p` up to `limit`: frees the dead and
/// advances the ages of the rest; new objects go back to white.
fn sweepGen(state: *State, p_in: *?*Header, limit: ?*Header, pfirstold1: *?*Header, paddedold: *isize) *?*Header {
    const next_age = [_]u8{
        age.survival, // from new
        age.old1, // from survival
        age.old1, // from old0
        age.old, // from old1
        age.old, // from old
        age.touched1, // touched1 stays
        age.touched2, // touched2 stays
    };
    const heap = &state.heap;
    var addedold: isize = 0;
    const white = heap.currentwhite & mark.white_bits;
    var p = p_in;
    while (p.* != limit) {
        const curr = p.*.?;
        if (isWhite(curr)) {
            std.debug.assert(!isOld(curr));
            std.debug.assert(heap.isDead(curr));
            p.* = curr.next;
            freeObject(state, curr);
        } else {
            const a = getAge(curr);
            if (a == age.new) {
                curr.marked = (curr.marked & ~mark.gc_bits) | age.survival | white;
            } else {
                setAge(curr, next_age[a]);
                if (getAge(curr) == age.old1) {
                    addedold += @intCast(objSize(curr));
                    if (pfirstold1.* == null) pfirstold1.* = curr;
                }
            }
            p = &curr.next;
        }
    }
    paddedold.* += addedold;
    return p;
}

/// After a generational sweep: drops white objects from a gray list,
/// advances TOUCHED1 to TOUCHED2 (staying), keeps threads, and makes
/// everything else old and black, off the list.
fn correctGrayList(p_in: *?*Header) *?*Header {
    var p = p_in;
    while (p.*) |curr| {
        const next = gclist(curr);
        if (isWhite(curr)) {
            p.* = next.*;
        } else if (getAge(curr) == age.touched1) {
            nw2black(curr);
            setAge(curr, age.touched2);
            p = next;
        } else if (curr.tag == .thread) {
            p = next;
        } else {
            if (getAge(curr) == age.touched2) setAge(curr, age.old);
            nw2black(curr);
            p.* = next.*;
        }
    }
    return p;
}

fn correctGrayLists(heap: *Heap) void {
    var list = correctGrayList(&heap.grayagain);
    list.* = heap.weak;
    heap.weak = null;
    list = correctGrayList(list);
    list.* = heap.allweak;
    heap.allweak = null;
    list = correctGrayList(list);
    list.* = heap.ephemeron;
    heap.ephemeron = null;
    _ = correctGrayList(list);
}

/// Marks the black OLD1 objects in `from` up to `to` at the start of a
/// young collection; they become old.
fn markOld(heap: *Heap, from: ?*Header, to: ?*Header) void {
    var it = from;
    while (it != to) {
        const h = it.?;
        if (getAge(h) == age.old1) {
            setAge(h, age.old);
            if (isBlack(h)) reallyMarkObject(heap, h);
        }
        it = h.next;
    }
}

fn finishGenCycle(state: *State, th: *Thread) void {
    const heap = &state.heap;
    correctGrayLists(heap);
    checkSizes(state);
    heap.phase = .propagate;
    heap.cycles += 1;
    if (heap.tobefnz != null and !heap.emergency and checkMinStack(th)) callAllPendingFinalizers(state, th);
}

/// From minor collections to major ones, as an incremental cycle that
/// starts by sweeping everything.
fn minor2inc(state: *State, kind: Kind) void {
    const heap = &state.heap;
    heap.majorminor = heap.marked;
    heap.kind = kind;
    heap.reallyold = null;
    heap.old1 = null;
    heap.survival = null;
    heap.finobjrold = null;
    heap.finobjold1 = null;
    heap.finobjsur = null;
    enterSweep(state);
    heap.setDebt(heap.param(.stepsize, 100));
}

/// Whether the bytes that became old since the last major collection
/// passed `minormajor` percent of what it left.
fn checkMinorMajor(heap: *Heap) bool {
    const limit = heap.param(.minormajor, heap.majorminor);
    if (limit == 0) return false;
    return heap.marked >= limit;
}

fn youngCollection(state: *State, th: *Thread) void {
    const heap = &state.heap;
    var addedold1: isize = 0;
    const marked = heap.marked;
    std.debug.assert(heap.phase == .propagate);
    if (heap.firstold1) |f| {
        markOld(heap, f, heap.reallyold);
        heap.firstold1 = null;
    }
    markOld(heap, heap.finobj, heap.finobjrold);
    markOld(heap, heap.tobefnz, null);

    atomic(state, th);

    // Sweep the nursery, then the survivals.
    heap.phase = .swp_allgc;
    var psurvival = sweepGen(state, &heap.allgc, heap.survival, &heap.firstold1, &addedold1);
    _ = sweepGen(state, psurvival, heap.old1, &heap.firstold1, &addedold1);
    heap.reallyold = heap.old1;
    heap.old1 = psurvival.*;
    heap.survival = heap.allgc;

    var dummy: ?*Header = null;
    psurvival = sweepGen(state, &heap.finobj, heap.finobjsur, &dummy, &addedold1);
    _ = sweepGen(state, psurvival, heap.finobjold1, &dummy, &addedold1);
    heap.finobjrold = heap.finobjold1;
    heap.finobjold1 = psurvival.*;
    heap.finobjsur = heap.finobj;

    _ = sweepGen(state, &heap.tobefnz, null, &dummy, &addedold1);

    heap.marked = marked + addedold1;
    if (checkMinorMajor(heap)) {
        minor2inc(state, .gen_major);
        heap.marked = 0;
    } else {
        finishGenCycle(state, th);
    }
}

/// From the end of an atomic phase to generational mode: everything alive
/// becomes old.
fn atomic2gen(state: *State, th: *Thread) void {
    const heap = &state.heap;
    clearGrayLists(heap);
    heap.phase = .swp_allgc;
    sweep2old(state, &heap.allgc);
    heap.reallyold = heap.allgc;
    heap.old1 = heap.allgc;
    heap.survival = heap.allgc;
    heap.firstold1 = null;
    sweep2old(state, &heap.finobj);
    heap.finobjrold = heap.finobj;
    heap.finobjold1 = heap.finobj;
    heap.finobjsur = heap.finobj;
    sweep2old(state, &heap.tobefnz);
    heap.kind = .gen_minor;
    heap.majorminor = heap.marked;
    heap.marked = 0;
    finishGenCycle(state, th);
}

/// The next minor collection after `minormul` percent of what the last
/// major collection left.
fn setMinorDebt(heap: *Heap) void {
    heap.setDebt(heap.param(.minormul, heap.majorminor));
}

fn enterGen(state: *State, th: *Thread) void {
    runUntil(state, th, .pause, true);
    runUntil(state, th, .propagate, true);
    atomic(state, th);
    atomic2gen(state, th);
    setMinorDebt(&state.heap);
}

/// Switches to incremental or generational mode (`luaC_changemode`).
pub fn changeMode(th: *Thread, new: Kind) void {
    const state = th.state;
    const heap = &state.heap;
    if (heap.kind == .gen_major) heap.kind = .incremental;
    if (new != heap.kind) {
        if (new == .incremental) {
            minor2inc(state, .incremental);
        } else {
            std.debug.assert(new == .gen_minor);
            enterGen(state, th);
        }
    }
}

fn fullGen(state: *State, th: *Thread) void {
    minor2inc(state, .incremental);
    enterGen(state, th);
}

/// After the atomic phase of a major collection in generational mode:
/// back to minor collections when it freed more than `majorminor` percent
/// of the bytes added since the last one.
fn checkMajorMinor(state: *State, th: *Thread) bool {
    const heap = &state.heap;
    if (heap.kind == .gen_major) {
        const numbytes: isize = @intCast(heap.bytes);
        const addedbytes = numbytes - heap.majorminor;
        const limit = heap.param(.majorminor, addedbytes);
        const tobecollected = numbytes - heap.marked;
        if (tobecollected > limit) {
            atomic2gen(state, th);
            setMinorDebt(heap);
            return true;
        }
    }
    heap.majorminor = heap.marked;
    return false;
}

// ---------------------------------------------------------------------------
// Control
// ---------------------------------------------------------------------------

fn enterSweep(state: *State) void {
    const heap = &state.heap;
    heap.phase = .swp_allgc;
    std.debug.assert(heap.sweepgc == null);
    heap.sweepgc = sweepToLive(state, &heap.allgc);
}

fn atomic(state: *State, th: *Thread) void {
    const heap = &state.heap;
    const grayagain = heap.grayagain;
    heap.grayagain = null;
    std.debug.assert(heap.ephemeron == null);
    std.debug.assert(heap.weak == null);
    heap.phase = .atomic;
    markObject(heap, &th.header);
    markObject(heap, &state.registry.header);
    markMetatables(state);
    propagateAll(state);
    remarkUpvals(heap);
    propagateAll(state);
    heap.gray = grayagain;
    propagateAll(state);
    convergeEphemerons(state);
    // Every strongly reachable object is marked now. Clear weak values
    // before resurrecting objects with finalizers.
    clearByValues(heap, heap.weak, null);
    clearByValues(heap, heap.allweak, null);
    const origweak = heap.weak;
    const origall = heap.allweak;
    separateToBeFinalized(heap, false);
    markBeingFinalized(heap);
    propagateAll(state);
    convergeEphemerons(state);
    // Resurrected objects are marked too: clear dead keys, and values the
    // resurrection put in weak tables.
    clearByKeys(heap, heap.ephemeron);
    clearByKeys(heap, heap.allweak);
    clearByValues(heap, heap.weak, origweak);
    clearByValues(heap, heap.allweak, origall);
    heap.currentwhite = otherWhite(heap);
    std.debug.assert(heap.gray == null);
}

fn sweepStep(state: *State, next_phase: Phase, next_list: ?*?*Header, fast: bool) void {
    const heap = &state.heap;
    if (heap.sweepgc) |p| {
        heap.sweepgc = sweepList(state, p, if (fast) std.math.maxInt(usize) else sweep_max);
    } else {
        heap.phase = next_phase;
        heap.sweepgc = next_list;
    }
}

const step_to_pause: isize = -3;
const atomic_step: isize = -2;
const step_to_minor: isize = -1;

/// One indivisible piece of an incremental cycle; returns its work, or one
/// of the negative markers above (`singlestep`).
fn singleStep(state: *State, th: *Thread, fast: bool) isize {
    const heap = &state.heap;
    switch (heap.phase) {
        .pause => {
            restartCollection(state);
            heap.phase = .propagate;
            return 1;
        },
        .propagate => {
            if (fast or heap.gray == null) {
                heap.phase = .enter_atomic;
                return 1;
            }
            return @intCast(propagateMark(state));
        },
        .enter_atomic => {
            atomic(state, th);
            if (checkMajorMinor(state, th)) return step_to_minor;
            enterSweep(state);
            return atomic_step;
        },
        .swp_allgc => {
            sweepStep(state, .swp_finobj, &heap.finobj, fast);
            return sweep_max;
        },
        .swp_finobj => {
            sweepStep(state, .swp_tobefnz, &heap.tobefnz, fast);
            return sweep_max;
        },
        .swp_tobefnz => {
            sweepStep(state, .swp_end, null, fast);
            return sweep_max;
        },
        .swp_end => {
            checkSizes(state);
            heap.phase = .call_fin;
            return sweep_max;
        },
        .call_fin => {
            if (heap.tobefnz != null and !heap.emergency and checkMinStack(th)) {
                callFinalizer(state, th);
                return finalizer_cost;
            }
            heap.phase = .pause;
            heap.cycles += 1;
            return step_to_pause;
        },
        .atomic => unreachable,
    }
}

/// Steps until the collector reaches `phase` (`luaC_runtilstate`).
fn runUntil(state: *State, th: *Thread, phase: Phase, fast: bool) void {
    std.debug.assert(state.heap.kind == .incremental);
    while (state.heap.phase != phase) _ = singleStep(state, th, fast);
}

/// A basic incremental step: `stepmul` percent of the bytes allocated
/// since the last step, in words, or a whole cycle when that is zero
/// (`incstep`). The reference charges one step's worth (`stepsize`) per
/// step and stops at the atomic phase; it can, because its natives check
/// the collector at each allocation. Ours check once, when they return, so
/// a native that allocated much more than a step pays for all of it here,
/// through the atomic phase if need be. With the usual debt of about one
/// step this is the reference's step exactly; `collectgarbage("step")`
/// always takes the reference's step.
fn incStep(state: *State, th: *Thread, pay_debt: bool) void {
    const heap = &state.heap;
    const stepsize = heap.param(.stepsize, 100);
    const owed = if (pay_debt) @max(stepsize, stepsize - heap.debt()) else stepsize;
    var work2do = heap.param(.stepmul, @divTrunc(owed, @sizeOf(usize)));
    if (heap.stress_step) work2do = 1;
    const fast = work2do == 0;
    const catch_up = owed > 2 * stepsize;
    while (true) {
        const r = singleStep(state, th, fast);
        if (r == step_to_minor) return;
        if (r == step_to_pause or (r == atomic_step and !fast and !catch_up)) break;
        if (r > 0) work2do -= r;
        if (!fast and work2do <= 0) break;
    }
    if (heap.phase == .pause) setPause(heap) else heap.setDebt(stepsize);
}

/// A collector step, when the collector is running (`luaC_step`). `th`
/// runs any finalizers.
pub fn step(th: *Thread) void {
    stepPaying(th, true);
}

/// `collectgarbage("step")`'s step: the reference's, however far the debt
/// went, so `collectgarbage("step", n)` ends a cycle when the reference's
/// does.
pub fn basicStep(th: *Thread) void {
    stepPaying(th, false);
}

fn stepPaying(th: *Thread, pay_debt: bool) void {
    const state = th.state;
    const heap = &state.heap;
    if (!heap.running()) {
        // Stopped by the user: check again only after a while.
        if (heap.stopped & stop.user != 0) heap.setDebt(20000);
        return;
    }
    if (heap.stress) return fullGc(th, false);
    switch (heap.kind) {
        .incremental, .gen_major => incStep(state, th, pay_debt),
        .gen_minor => {
            youngCollection(state, th);
            setMinorDebt(heap);
        },
    }
}

fn fullInc(state: *State, th: *Thread) void {
    const heap = &state.heap;
    // Black objects must be whitened before a new cycle starts.
    if (keepInvariant(heap)) enterSweep(state);
    runUntil(state, th, .pause, true);
    runUntil(state, th, .call_fin, true);
    runUntil(state, th, .pause, true);
    setPause(heap);
}

/// A full collection (`luaC_fullgc`). An emergency one runs no finalizers
/// and shrinks nothing.
pub fn fullGc(th: *Thread, emergency: bool) void {
    const state = th.state;
    const heap = &state.heap;
    std.debug.assert(!heap.emergency);
    heap.emergency = emergency;
    switch (heap.kind) {
        .gen_minor => fullGen(state, th),
        .incremental => fullInc(state, th),
        .gen_major => {
            heap.kind = .incremental;
            fullInc(state, th);
            heap.kind = .gen_major;
        },
    }
    heap.emergency = false;
}

/// What `lua_close` does with the collector before freeing: no more
/// steps or finalizer registrations, then every object with a finalizer
/// gets it called, in reverse order of registration
/// (`luaC_freeallobjects` up to the freeing). Runs once.
pub fn callAllFinalizers(state: *State) void {
    const heap = &state.heap;
    if (heap.stopped & stop.closing != 0) return;
    heap.stopped = stop.closing;
    const th = state.main;
    changeMode(th, .incremental);
    separateToBeFinalized(heap, true);
    std.debug.assert(heap.finobj == null);
    callAllPendingFinalizers(state, th);
}

/// Every object of the heap, list by list; for code that must visit them
/// all, such as flushing every open file at exit.
pub const ObjectIterator = struct {
    lists: [4]?*Header,
    i: usize = 0,

    pub fn next(it: *ObjectIterator) ?*Header {
        while (it.i < it.lists.len) {
            if (it.lists[it.i]) |h| {
                it.lists[it.i] = h.next;
                return h;
            }
            it.i += 1;
        }
        return null;
    }
};

pub fn objects(heap: *const Heap) ObjectIterator {
    return .{ .lists = .{ heap.allgc, heap.finobj, heap.tobefnz, heap.fixedgc } };
}

/// Frees every object without running finalizers; for `State.destroy`
/// after `callAllFinalizers`, and for heaps without a state.
pub fn freeAll(heap: *Heap) void {
    // Barriers that closing upvalues triggers must not mark anything.
    heap.phase = .swp_allgc;
    heap.kind = .incremental;
    // Threads first: closing their open upvalues touches the upvalues.
    var it = objects(heap);
    while (it.next()) |h| {
        if (h.tag == .thread) Thread.closeAllUpvals(@fieldParentPtr("header", h));
    }
    for ([_]*?*Header{ &heap.allgc, &heap.finobj, &heap.tobefnz, &heap.fixedgc }) |list| {
        while (list.*) |h| {
            list.* = h.next;
            destroyObject(heap, h);
        }
    }
}

const testing = std.testing;

fn countObjects(heap: *Heap) usize {
    var n: usize = 0;
    var it = objects(heap);
    while (it.next()) |_| n += 1;
    return n;
}

fn nativeNop(_: *Thread, _: u32) Value.Error!u32 {
    return 0;
}

test "a collection frees exactly the unreachable objects of every kind" {
    const state = try State.create(testing.allocator, .{ .seed = 1 });
    defer state.destroy();
    const heap = &state.heap;
    // Give the globals their node for "live" now, so the baseline has it.
    try state.globals.setStr(heap, try state.newString("live"), .false);
    state.collect();
    const base_objects = countObjects(heap);
    const base_bytes = heap.bytes;

    // Reachable: a table in the globals holding one of each kind.
    const live = try state.newTable(0, 0);
    try state.globals.setStr(heap, try state.newString("live"), .table(live));
    const mt = try state.newTable(0, 0);
    live.metatable = mt;
    const proto = try Proto.create(heap);
    proto.k = try heap.allocator().dupe(Value, &.{.string(try state.newString("a constant"))});
    const lcl = try Proto.LuaClosure.create(heap, proto, 1);
    lcl.setUpval(heap, 0, try Proto.Upval.createClosed(heap, .string(try state.newString("in a closed upvalue"))));
    try live.setInt(heap, 1, .luaClosure(lcl));
    const ncl = try Proto.NativeClosure.create(heap, &nativeNop, 1);
    ncl.setUpvalue(heap, 0, .string(try state.newString(&@as([50]u8, @splat('x')))));
    try live.setInt(heap, 2, .nativeClosure(ncl));
    const ud = try Userdata.create(heap, 24, 1);
    ud.setUserValue(heap, 0, .table(try state.newTable(0, 0)));
    try live.setInt(heap, 3, .userdata(ud));
    // A coroutine whose stack holds a value only an open upvalue shares.
    const co = try Thread.create(state);
    co.push(.string(try state.newString("on a coroutine stack")));
    const open = try co.findUpval(1);
    const cl2 = try Proto.LuaClosure.create(heap, proto, 1);
    cl2.setUpval(heap, 0, open);
    try live.setInt(heap, 4, .luaClosure(cl2));
    try live.setInt(heap, 5, .thread(co));
    const live_objects = countObjects(heap);

    // Unreachable: the same again, referenced from nowhere.
    const junk = try state.newTable(4, 4);
    for (0..100) |i| try junk.setInt(heap, @intCast(i + 1), .table(try state.newTable(0, 0)));
    try junk.setStr(heap, try state.newString(std.mem.asBytes(&@as([20][5]u8, @splat("long ".*)))), .int(1));
    _ = try Proto.LuaClosure.create(heap, proto, 0);
    _ = try Proto.NativeClosure.create(heap, &nativeNop, 2);
    _ = try Userdata.create(heap, 100, 3);
    const dead_co = try Thread.create(state);
    dead_co.push(.int(5));
    const dead_uv = try dead_co.findUpval(1);
    _ = dead_uv;
    try testing.expect(countObjects(heap) > live_objects + 100);

    state.collect();
    try testing.expectEqual(live_objects, countObjects(heap));
    try testing.expectEqualStrings("in a closed upvalue", lcl.upvals()[0].v.asString().bytes());
    try testing.expectEqualStrings(&@as([50]u8, @splat('x')), ncl.upvalues()[0].asString().bytes());
    try testing.expect(ud.userValues()[0].isTable());
    try testing.expectEqualStrings("on a coroutine stack", open.v.asString().bytes());
    try testing.expectEqualStrings("a constant", proto.k[0].asString().bytes());

    // Unreference the coroutine but keep a closure over its open upvalue:
    // freeing the thread closes the upvalue, which keeps the value.
    try live.setInt(heap, 5, .nil);
    state.collect();
    try testing.expect(!open.isOpen());
    try testing.expectEqualStrings("on a coroutine stack", open.v.asString().bytes());

    // Drop everything; only the baseline objects remain.
    try state.globals.setStr(heap, try state.newString("live"), .false);
    state.collect();
    try testing.expectEqual(base_objects, countObjects(heap));
    try testing.expectEqual(base_bytes, heap.bytes);
}

test "a key whose value was cleared stays traversable after its object dies" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const heap = &state.heap;
    const t = try state.newTable(0, 0);
    try state.globals.setStr(heap, try state.newString("t"), .table(t));
    try t.setStr(heap, try state.newString("a"), .int(1));
    const key = try state.newTable(0, 0);
    try t.set(heap, .table(key), .int(2));
    try t.setStr(heap, try state.newString("b"), .int(3));
    // Mid-traversal, clear the entry whose key is the table, then collect:
    // the key's object is freed, but `next` from it still works.
    var it = try t.next(.nil);
    var visited: usize = 0;
    var cleared = false;
    while (it) |e| : (it = try t.next(e.key)) {
        visited += 1;
        if (e.key.isTable()) {
            try t.set(heap, e.key, .nil);
            state.collect();
            cleared = true;
        }
    }
    try testing.expect(cleared);
    try testing.expectEqual(@as(usize, 3), visited);
    var dead_keys: usize = 0;
    for (t.nodes()) |n| {
        if (n.key_tag == .dead_key) dead_keys += 1;
    }
    try testing.expectEqual(@as(usize, 1), dead_keys);
}

test "the interner drops dead strings and keeps fixed ones" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const before = state.strings.count;
    var buf: [16]u8 = undefined;
    for (0..500) |i| _ = try state.newString(try std.mem.print(&buf, "tmp{d}", .{i}));
    try testing.expectEqual(before + 500, state.strings.count);
    state.collect();
    try testing.expectEqual(before, state.strings.count);
    try testing.expectEqual(state.tm_names[0], try state.newString("__index"));
}

test "parameters code and apply as the reference's floating-point bytes" {
    for ([_]u32{ 5, 10, 12, 20, 50, 100, 200, 500 }) |pct| {
        const p = codeParam(pct);
        for ([_]isize{ 1, 2, 10, 100, 257, 1023, 6500, 100000 }) |x| {
            const exact = @divTrunc(x * pct, 100);
            const approx = applyParam(p, x);
            try testing.expect(@abs(approx - exact) <= @divTrunc(exact, 10) + 1);
        }
    }
    try testing.expectEqual(@as(isize, 100), applyParam(codeParam(100), 100));
    try testing.expectEqual(@as(u8, 0xFF), codeParam(std.math.maxInt(u32)));
}
