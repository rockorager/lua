//! The standard libraries and `openLibs`, which opens them into a state,
//! as reference Lua's linit.c does. Each library is a file in this
//! directory with an `open` function that sets its globals.

const Value = @import("../Value.zig");
const State = @import("../State.zig");
const Thread = @import("../Thread.zig");

pub const base = @import("base.zig");
pub const string = @import("string.zig");
pub const table = @import("table.zig");
pub const math = @import("math.zig");
pub const utf8 = @import("utf8.zig");

/// The libraries `openLibs` opens, in linit.c's order.
const libs = [_]*const fn (*Thread) Value.Error!void{
    base.open,
    onState(string.open),
    onState(table.open),
    onState(math.open),
    onState(utf8.open),
};

/// Adapts a library whose `open` takes the state.
fn onState(comptime open: fn (*State) Value.Error!void) fn (*Thread) Value.Error!void {
    return struct {
        fn f(th: *Thread) Value.Error!void {
            return open(th.state);
        }
    }.f;
}

/// Opens every standard library into the globals of `th`'s state. `host`
/// supplies their I/O and must outlive the state.
pub fn openLibs(th: *Thread, host: *base.Host) Value.Error!void {
    try base.setHost(th, host);
    for (libs) |open| try open(th);
}
