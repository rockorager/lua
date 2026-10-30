//! The coroutine library (§6.2): `coroutine.create`, `resume`, `yield`,
//! `status`, `wrap`, `isyieldable`, `running`, and `close`, over
//! `vm.resumeThread`, `vm.yield`, and `vm.closeThread`. The structure is
//! lcorolib.c's.

const std = @import("std");
const Value = @import("../Value.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const Proto = @import("../Proto.zig");
const vm = @import("../vm.zig");
const debuginfo = @import("../debuginfo.zig");

const Error = Value.Error;

/// The library's functions, by name.
pub const functions = [_]struct { name: []const u8, func: Value.NativeFn }{
    .{ .name = "create", .func = &create },
    .{ .name = "resume", .func = &@"resume" },
    .{ .name = "running", .func = &running },
    .{ .name = "status", .func = &status },
    .{ .name = "wrap", .func = &wrap },
    .{ .name = "yield", .func = &yield },
    .{ .name = "isyieldable", .func = &isyieldable },
    .{ .name = "close", .func = &close },
};

/// Creates the `coroutine` table and sets the global.
pub fn open(state: *State) Error!void {
    const t = try state.newTable(0, functions.len);
    for (functions) |f| try t.setStr(&state.heap, try state.newString(f.name), .native(f.func));
    try state.globals.setStr(&state.heap, try state.newString("coroutine"), .table(t));
}

fn argError(th: *Thread, arg: u32, comptime fmt: []const u8, args: anytype) Error {
    var msgbuf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msgbuf, fmt, args) catch "?";
    return debuginfo.argError(th, arg, "?", msg);
}

fn typeNameAt(th: *Thread, base: u32, n: u32) []const u8 {
    if (base + n >= th.top) return "no value";
    return th.state.typeName(th.stack[base + n]);
}

fn getCo(th: *Thread, base: u32) Error!*Thread {
    if (base < th.top and th.stack[base].tag == .thread) return th.stack[base].asThread();
    return argError(th, 1, "thread expected, got {s}", .{typeNameAt(th, base, 0)});
}

fn getOptCo(th: *Thread, base: u32) Error!*Thread {
    return if (base >= th.top) th else getCo(th, base);
}

/// Resumes `co` with the `narg` values on top of `th`, and moves its
/// results (or the error object) to `th`. Returns the number of results,
/// or null after an error.
fn auxResume(th: *Thread, co: *Thread, narg: u32) Error!?u32 {
    if (!try vm.checkStack(co, narg)) {
        th.top -= narg;
        th.push(.string(try th.state.newString("too many arguments to resume")));
        return null;
    }
    for (th.stack[th.top - narg .. th.top]) |v| co.push(v);
    th.top -= narg;
    const r = try vm.resumeThread(co, th, narg);
    switch (r.status) {
        .ok, .yield => {
            if (!try vm.checkStack(th, r.nres + 1)) {
                co.top -= r.nres;
                th.push(.string(try th.state.newString("too many results to resume")));
                return null;
            }
            for (co.stack[co.top - r.nres .. co.top]) |v| th.push(v);
            co.top -= r.nres;
            return r.nres;
        },
        .err => {
            th.push(co.stack[co.top - 1]);
            co.top -= 1;
            return null;
        },
    }
}

fn create(th: *Thread, base: u32) Error!u32 {
    if (base >= th.top or !th.stack[base].isFunction())
        return argError(th, 1, "function expected, got {s}", .{typeNameAt(th, base, 0)});
    const co = try Thread.create(th.state);
    th.push(.thread(co));
    co.push(th.stack[base]);
    return 1;
}

fn @"resume"(th: *Thread, base: u32) Error!u32 {
    const co = try getCo(th, base);
    const n = try auxResume(th, co, th.top - base - 1) orelse {
        // false, then the error object.
        th.push(th.stack[th.top - 1]);
        th.stack[th.top - 2] = .false;
        return 2;
    };
    // true below the results.
    const first = th.top - n;
    @memmove(th.stack[first + 1 .. th.top + 1], th.stack[first..th.top]);
    th.stack[first] = .true;
    th.top += 1;
    return n + 1;
}

fn auxWrap(th: *Thread, base: u32) Error!u32 {
    const self = th.stack[th.frame().func].asNativeClosure();
    const co = self.upvalues()[0].asThread();
    if (try auxResume(th, co, th.top - base)) |n| return n;
    var err = th.stack[th.top - 1];
    if (co.status == .dead) {
        // An error in the coroutine: close its variables first.
        _ = vm.closeThread(co, th);
        err = co.stack[co.top - 1];
        co.top -= 1;
    }
    if (err.isString() and err.asString() != th.state.memerr) {
        var aw: std.Io.Writer.Allocating = .init(th.heap().allocator());
        defer aw.deinit();
        debuginfo.where(th, 1, &aw.writer) catch return error.OutOfMemory;
        aw.writer.writeAll(err.asString().bytes()) catch return error.OutOfMemory;
        err = .string(try th.state.newString(aw.written()));
    }
    return th.throw(err);
}

fn wrap(th: *Thread, base: u32) Error!u32 {
    _ = try create(th, base);
    const c = try Proto.NativeClosure.create(th.heap(), &auxWrap, 1);
    c.setUpvalue(th.heap(), 0, th.stack[th.top - 1]);
    th.stack[th.top - 1] = .nativeClosure(c);
    return 1;
}

fn yield(th: *Thread, base: u32) Error!u32 {
    return vm.yield(th, th.top - base);
}

const CoStatus = enum { running, dead, suspended, normal };

fn coStatus(th: *Thread, co: *Thread) CoStatus {
    if (th == co) return .running;
    return switch (co.status) {
        .yield => .suspended,
        .dead => .dead,
        .ok => if (co.frames.items.len > 1) .normal else if (co.top == 1) .dead else .suspended,
    };
}

fn status(th: *Thread, base: u32) Error!u32 {
    const co = try getCo(th, base);
    th.push(.string(try th.state.newString(@tagName(coStatus(th, co)))));
    return 1;
}

fn isyieldable(th: *Thread, base: u32) Error!u32 {
    const co = try getOptCo(th, base);
    th.push(.boolean(vm.isYieldable(co)));
    return 1;
}

fn running(th: *Thread, base: u32) Error!u32 {
    _ = base;
    th.push(.thread(th));
    th.push(.boolean(th == th.state.main));
    return 2;
}

fn close(th: *Thread, base: u32) Error!u32 {
    const co = try getOptCo(th, base);
    switch (coStatus(th, co)) {
        .dead, .suspended => {
            if (vm.closeThread(co, th)) {
                th.push(.true);
                return 1;
            }
            th.push(.false);
            th.push(co.stack[co.top - 1]);
            co.top -= 1;
            return 2;
        },
        .normal => return debuginfo.raise(th, "cannot close a normal coroutine", .{}),
        .running => {
            if (co == th.state.main) return debuginfo.raise(th, "cannot close main thread", .{});
            return vm.closeSelf(co);
        },
    }
}
