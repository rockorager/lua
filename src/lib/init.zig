//! The standard libraries and `openLibs`, which opens them into a state,
//! as reference Lua's linit.c does. Each library is a file in this
//! directory with an `open` function that sets its globals.

const Value = @import("../Value.zig");
const Thread = @import("../Thread.zig");

pub const base = @import("base.zig");

/// The libraries `openLibs` opens, in order.
const libs = [_]*const fn (*Thread) Value.Error!void{
    base.open,
};

/// Opens every standard library into the globals of `th`'s state. `host`
/// supplies their I/O and must outlive the state.
pub fn openLibs(th: *Thread, host: *base.Host) Value.Error!void {
    try base.setHost(th, host);
    for (libs) |open| try open(th);
}
